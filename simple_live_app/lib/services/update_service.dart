import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// GitHub Releases 更新服务。
///
/// - 启动时/手动检查最新版本
/// - 版本比较后由用户选择"立即更新"或"暂不更新"
/// - Windows：下载 zip → 生成替换脚本 → 关闭自身 → 覆盖 → 重启
/// - 其他平台：打开对应平台的下载页/安装包
class UpdateService extends GetxService {
  static UpdateService get instance => Get.find<UpdateService>();

  static const String _repo = "3055909481/dart_simple_live";
  static const String _apiUrl =
      "https://api.github.com/repos/$_repo/releases/latest";
  static const String _skipVersionKey = "UpdateSkipVersion";
  static const String _lastCheckKey = "UpdateLastCheck";

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    headers: {
      "Accept": "application/vnd.github+json",
      "User-Agent": "SimpleLive-UpdateChecker",
    },
  ));

  final RxBool checking = false.obs;
  final Rxn<AppRelease> release = Rxn<AppRelease>();
  final RxnString error = RxnString();
  final RxDouble downloadProgress = 0.0.obs;
  final RxBool downloading = false.obs;

  String get currentVersion => Utils.packageInfo.version;

  @override
  void onInit() {
    super.onInit();
  }

  /// 检查更新。返回是否有新版本；静默模式不弹错误。
  Future<AppRelease?> check({bool silent = true}) async {
    checking.value = true;
    error.value = null;
    try {
      final resp = await _dio.get(_apiUrl);
      if (resp.statusCode != 200 || resp.data is! Map) {
        throw Exception("HTTP ${resp.statusCode}");
      }
      final data = resp.data as Map;
      final tag = (data["tag_name"] ?? "").toString();
      if (tag.isEmpty || data["draft"] == true || data["prerelease"] == true) {
        release.value = null;
        return null;
      }
      final assets = <ReleaseAsset>[];
      if (data["assets"] is List) {
        for (final a in data["assets"] as List) {
          if (a is! Map) continue;
          assets.add(ReleaseAsset(
            name: (a["name"] ?? "").toString(),
            downloadUrl: (a["browser_download_url"] ?? "").toString(),
            size: a["size"] is int ? a["size"] as int : 0,
          ));
        }
      }
      final info = AppRelease(
        version: _normalizeVersion(tag),
        tag: tag,
        body: (data["body"] ?? "").toString(),
        htmlUrl: (data["html_url"] ?? "").toString(),
        publishedAt: (data["published_at"] ?? "").toString(),
        assets: assets,
      );
      release.value = info;

      // 记录检查时间
      try {
        await LocalStorageService.instance.setValue(
          _lastCheckKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      } catch (_) {}

      if (!_isNewer(info.version, currentVersion)) {
        return null;
      }
      if (_isSkipped(info.version)) {
        return null;
      }
      return info;
    } catch (e) {
      error.value = e.toString();
      if (!silent) {
        Log.e("检查更新失败: $e", StackTrace.current);
      }
      return null;
    } finally {
      checking.value = false;
    }
  }

  /// 用户选择"暂不更新"：记住该版本，启动时不再提示。
  Future<void> skipVersion(String version) async {
    try {
      await LocalStorageService.instance.setValue(_skipVersionKey, version);
      _cachedSkipVersion = version;
    } catch (_) {}
  }

  bool _isSkipped(String version) => _cachedSkipVersion == version;

  static String? _cachedSkipVersion;

  /// 启动时载入跳过版本（在 initServices 之后调用）。
  Future<void> loadSkipVersion() async {
    try {
      _cachedSkipVersion = LocalStorageService.instance.getValue<String>(
        _skipVersionKey,
        "",
      );
    } catch (_) {
      _cachedSkipVersion = null;
    }
  }

  /// 执行更新。非 Windows 平台打开下载页。
  Future<bool> update(AppRelease info) async {
    if (Platform.isWindows) {
      return _updateWindows(info);
    }
    // 其他平台：打开 Release 页面让用户手动下载（iOS 无法自更新）。
    final url = info.htmlUrl.isNotEmpty
        ? info.htmlUrl
        : "https://github.com/$_repo/releases";
    try {
      return await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Windows 自动更新：下载 zip（优先）→ 写替换脚本 → 退出并重启。
  Future<bool> _updateWindows(AppRelease info) async {
    final asset = _pickWindowsAsset(info);
    if (asset == null || asset.downloadUrl.isEmpty) {
      return false;
    }

    downloading.value = true;
    downloadProgress.value = 0;
    try {
      final tempDir = await getTemporaryDirectory();
      final zipPath = p.join(tempDir.path, "simple_live_update.zip");
      final zipFile = File(zipPath);
      if (await zipFile.exists()) {
        await zipFile.delete();
      }

      await _dio.download(
        asset.downloadUrl,
        zipPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            downloadProgress.value = received / total;
          }
        },
      );

      final appDir = p.dirname(Platform.resolvedExecutable);
      final scriptPath = p.join(tempDir.path, "simple_live_update.ps1");
      // PowerShell 脚本：等待本进程退出 → 备份 → 覆盖 → 重启
      final script = _buildWindowsUpdateScript(
        zipPath: zipPath,
        appDir: appDir,
        exeName: p.basename(Platform.resolvedExecutable),
      );
      await File(scriptPath).writeAsString(script, encoding: utf8);

      await Process.start(
        "powershell.exe",
        [
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          scriptPath,
        ],
        mode: ProcessStartMode.detached,
      );

      // 退出当前应用，让脚本完成替换并重启（exit 不会返回）
      exit(0);
    } catch (e) {
      Log.e("Windows 自动更新失败: $e", StackTrace.current);
      return false;
    } finally {
      downloading.value = false;
    }
  }

  /// 选择 Windows 更新包：优先 zip（免安装覆盖），其次 msix。
  ReleaseAsset? _pickWindowsAsset(AppRelease info) {
    for (final a in info.assets) {
      final name = a.name.toLowerCase();
      if (name.contains("windows") && name.endsWith(".zip")) {
        return a;
      }
    }
    for (final a in info.assets) {
      final name = a.name.toLowerCase();
      if (name.contains("windows") && name.endsWith(".msix")) {
        return a;
      }
    }
    return null;
  }

  String _buildWindowsUpdateScript({
    required String zipPath,
    required String appDir,
    required String exeName,
  }) {
    // 注意：PowerShell 变量用单引号包裹 Dart 插入的路径。
    return r'''
$ErrorActionPreference = 'Stop'
$zip = 'ZIPPATH'
$appDir = 'APPDIR'
$exeName = 'EXENAME'
$exeFull = Join-Path $appDir $exeName

# 等待当前应用进程退出（最多 30 秒）
for ($i = 0; $i -lt 60; $i++) {
  $proc = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exeName)) -ErrorAction SilentlyContinue
  if (-not $proc) { break }
  Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 1

# 备份旧版本目录（保留配置），解压覆盖
$backup = "$appDir.backup"
if (Test-Path $backup) { Remove-Item -Recurse -Force $backup }
Copy-Item -Recurse -Force $appDir $backup

$tempExtract = Join-Path $env:TEMP 'simple_live_update_extract'
if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract }
New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
Expand-Archive -Path $zip -DestinationPath $tempExtract -Force

# zip 内可能有一层目录，找到含 exe 的目录
$sourceDir = $tempExtract
$exeInZip = Get-ChildItem -Path $tempExtract -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($exeInZip) { $sourceDir = $exeInZip.Directory.FullName }

Copy-Item -Recurse -Force (Join-Path $sourceDir '*') $appDir

# 重启应用
Start-Process -FilePath $exeFull -WorkingDirectory $appDir
'''
        .replaceAll("ZIPPATH", zipPath.replaceAll("'", "''"))
        .replaceAll("APPDIR", appDir.replaceAll("'", "''"))
        .replaceAll("EXENAME", exeName.replaceAll("'", "''"));
  }

  /// 版本比较：1.10.0 > 1.9.0。
  bool _isNewer(String latest, String current) {
    final a = _versionParts(latest);
    final b = _versionParts(current);
    for (var i = 0; i < 3; i += 1) {
      if (a[i] > b[i]) return true;
      if (a[i] < b[i]) return false;
    }
    return false;
  }

  List<int> _versionParts(String version) {
    final normalized = _normalizeVersion(version);
    final parts = normalized.split(".");
    return [
      int.tryParse(parts.isNotEmpty ? parts[0] : "0") ?? 0,
      int.tryParse(parts.length > 1 ? parts[1] : "0") ?? 0,
      int.tryParse(parts.length > 2 ? parts[2] : "0") ?? 0,
    ];
  }

  String _normalizeVersion(String v) {
    return v.replaceFirst(RegExp(r'^[vV]'), '').split('+').first.trim();
  }
}

/// Release 信息。
class AppRelease {
  final String version;
  final String tag;
  final String body;
  final String htmlUrl;
  final String publishedAt;
  final List<ReleaseAsset> assets;

  AppRelease({
    required this.version,
    required this.tag,
    required this.body,
    required this.htmlUrl,
    required this.publishedAt,
    required this.assets,
  });
}

class ReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;

  ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
}

