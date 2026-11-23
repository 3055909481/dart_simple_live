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
  // 用 raw 文件 + atom feed，避开 GitHub API 匿名 60次/小时 限流（国内共享IP易403）
  static const String _versionJsonUrl =
      "https://raw.githubusercontent.com/$_repo/master/version.json";
  static const String _atomUrl = "https://github.com/$_repo/releases.atom";
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
  /// 更新过程中的错误，供对话框内直接展示（snackbar 会被 dialog 遮挡）。
  final RxnString updateError = RxnString();

  String get currentVersion => Utils.packageInfo.version;

  @override
  void onInit() {
    super.onInit();
  }

  /// 检查更新。返回是否有新版本；静默模式不弹错误。
  ///
  /// 优先读仓库内 version.json（raw，无 API 限流），失败时回退 releases.atom。
  Future<AppRelease?> check({bool silent = true}) async {
    checking.value = true;
    error.value = null;
    try {
      AppRelease? info;
      // 主源：version.json
      try {
        final resp = await _dio.get(
          _versionJsonUrl,
          options: Options(
            headers: {"Accept": "text/plain", "User-Agent": "Mozilla/5.0"},
          ),
        );
        if (resp.statusCode == 200 && resp.data is Map) {
          info = _parseVersionJson(resp.data as Map);
        }
      } catch (_) {}
      // 兜底：atom feed
      info ??= await _checkViaAtom();

      if (info == null) {
        error.value = "无法获取版本信息";
        return null;
      }
      release.value = info;

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

  AppRelease? _parseVersionJson(Map data) {
    final version = (data["version"] ?? "").toString();
    if (version.isEmpty) return null;
    final tag = (data["tag"] ?? "v$version").toString();
    final assets = <ReleaseAsset>[];
    final rawAssets = data["assets"];
    if (rawAssets is Map) {
      final base = "https://github.com/$_repo/releases/download/$tag/";
      rawAssets.forEach((key, value) {
        if (value is Map) {
          value.forEach((k, name) {
            if (name is String && name.isNotEmpty) {
              assets.add(ReleaseAsset(
                name: name,
                // 不要在这里 encodeComponent：Dio 下载时会再编码一次，
                // 文件名里的 '+' 会变成 %2B → %252B 导致 404。直接拼原名。
                downloadUrl: "$base$name",
                size: 0,
              ));
            }
          });
        } else if (value is String && value.isNotEmpty) {
          assets.add(ReleaseAsset(
            name: value,
            downloadUrl: "$base$value",
            size: 0,
          ));
        }
      });
    }
    return AppRelease(
      version: _normalizeVersion(version),
      tag: tag,
      body: (data["notes"] ?? "").toString(),
      htmlUrl: (data["releasePage"] ??
              "https://github.com/$_repo/releases/tag/$tag")
          .toString(),
      publishedAt: (data["released"] ?? "").toString(),
      assets: assets,
    );
  }

  /// 通过 releases.atom 获取最新版本（无 API 限流）。
  Future<AppRelease?> _checkViaAtom() async {
    final resp = await _dio.get(
      _atomUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: {"User-Agent": "Mozilla/5.0"},
      ),
    );
    if (resp.statusCode != 200) return null;
    final xml = resp.data.toString();
    // 取第一个 entry 的 link href（tag 页）
    final linkMatch = RegExp(
      r'<entry>[\s\S]*?<link[^>]*href="([^"]+)"',
    ).firstMatch(xml);
    final titleMatch =
        RegExp(r'<entry>[\s\S]*?<title>([^<]+)</title>').firstMatch(xml);
    final contentMatch =
        RegExp(r'<entry>[\s\S]*?<content[^>]*>([\s\S]*?)</content>')
            .firstMatch(xml);
    if (linkMatch == null) return null;

    final htmlUrl = linkMatch.group(1) ?? "";
    final tag = htmlUrl.split('/').last;
    if (tag.isEmpty) return null;
    // body: 解码 HTML 实体 + 去标签，转纯文本
    var body = contentMatch?.group(1) ?? "";
    body = _decodeHtml(body);
    // 构造默认 asset 名（atom 兜底时拿不到 version.json 的精确资产名）。
    // 不预先编码，避免 Dio 二次编码导致 404。
    final base = "https://github.com/$_repo/releases/download/$tag/";
    final assets = <ReleaseAsset>[];
    final ver = _normalizeVersion(tag);
    for (final name in <String>[
      "simple_live_app-$ver-windows.zip",
      "simple_live_app-$ver-windows.msix",
    ]) {
      assets.add(ReleaseAsset(
        name: name,
        downloadUrl: "$base$name",
        size: 0,
      ));
    }
    return AppRelease(
      version: ver,
      tag: tag,
      body: body,
      htmlUrl: htmlUrl,
      publishedAt: "",
      assets: assets,
    );
  }

  /// 简易 HTML 实体解码（atom content 是转义的 HTML）。
  String _decodeHtml(String text) {
    return text
        .replaceAll("&lt;", "<")
        .replaceAll("&gt;", ">")
        .replaceAll("&quot;", '"')
        .replaceAll("&#39;", "'")
        .replaceAll("&amp;", "&")
        .replaceAll(RegExp(r'<[^>]+>'), " ")
        .replaceAll(RegExp(r'[ \t]+'), " ")
        .trim();
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
    updateError.value = null;
    try {
      final tempDir = await getTemporaryDirectory();
      final zipPath = p.join(tempDir.path, "simple_live_update.zip");
      final zipFile = File(zipPath);
      if (await zipFile.exists()) {
        await zipFile.delete();
      }

      var downloadUrl = asset.downloadUrl;
      try {
        await _downloadToFile(downloadUrl, zipPath);
      } on DioException catch (e) {
        // 404 时用 GitHub API 查询该 tag 的真实资产名再试一次。
        // 覆盖两种场景：①发版时序窗口（version.json 已更新但资产刚就绪）；
        // ②atom 兜底拼出的文件名缺 build number（如 +10009）。
        if (e.response?.statusCode == 404) {
          final realUrl = await _resolveRealAssetUrl(info.tag, asset.name);
          if (realUrl != null && realUrl != downloadUrl) {
            downloadUrl = realUrl;
            await _downloadToFile(downloadUrl, zipPath);
          } else {
            rethrow;
          }
        } else {
          rethrow;
        }
      }

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
      updateError.value = _friendlyUpdateError(e);
      return false;
    } finally {
      downloading.value = false;
    }
  }

  /// 把下载异常转成简短的中文提示，避免给用户一长串英文技术细节。
  String _friendlyUpdateError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status == 404) {
        return "新版本安装包尚未就绪，请稍后再试，或到 Release 页手动下载。";
      }
      if (status != null && status >= 500) {
        return "更新服务器暂时不可用（$status），请稍后重试。";
      }
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return "下载超时，请检查网络后重试。";
        case DioExceptionType.connectionError:
          return "无法连接更新服务器，请检查网络后重试。";
        case DioExceptionType.cancel:
          return "更新已取消。";
        default:
          return "下载更新包失败，请稍后重试。";
      }
    }
    return "更新失败，请稍后重试。";
  }

  Future<void> _downloadToFile(String url, String savePath) async {
    await _dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) {
          downloadProgress.value = received / total;
        }
      },
    );
  }

  /// 404 时通过 GitHub API 查询 tag 下的真实资产名，拼出正确下载链接。
  /// 只在更新这种低频场景调用，且是失败兜底，不会触发 API 限流问题。
  Future<String?> _resolveRealAssetUrl(String tag, String requestedName) async {
    try {
      final resp = await _dio.get(
        "https://api.github.com/repos/$_repo/releases/tags/$tag",
        options: Options(
          headers: {"Accept": "application/vnd.github+json"},
        ),
      );
      final raw = resp.data;
      if (raw is! Map) return null;
      final assets = raw["assets"];
      if (assets is! List) return null;
      final wanted = requestedName.toLowerCase();
      for (final a in assets) {
        if (a is! Map) continue;
        final name = a["name"]?.toString() ?? "";
        final lower = name.toLowerCase();
        // 优先精确匹配，其次匹配同类型（zip/msix）+ windows
        if (lower == wanted) {
          return a["browser_download_url"]?.toString();
        }
      }
      final isZip = wanted.endsWith(".zip");
      for (final a in assets) {
        if (a is! Map) continue;
        final name = a["name"]?.toString() ?? "";
        final lower = name.toLowerCase();
        if (lower.contains("windows") &&
            (isZip ? lower.endsWith(".zip") : lower.endsWith(".msix"))) {
          return a["browser_download_url"]?.toString();
        }
      }
    } catch (_) {}
    return null;
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

