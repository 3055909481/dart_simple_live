import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 音频输出设备。
class AudioOutputDevice {
  final String id;
  final String name;

  const AudioOutputDevice({required this.id, required this.name});

  /// 跟随系统默认设备（mpv 的 auto），始终作为第一项。
  static const auto = AudioOutputDevice(id: "auto", name: "跟随 Windows 默认设备");

  /// 跟随上级配置（仅平台/直播间层级使用，不传给 mpv）。
  static const inherit = AudioOutputDevice(id: "__inherit__", name: "跟随上级配置");

  bool get isAuto => id == "auto";
  bool get isInherit => id == "__inherit__";

  @override
  bool operator ==(Object other) =>
      other is AudioOutputDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 音频输出设备三级配置服务。
///
/// 优先级：直播间配置 > 平台配置 > 全局配置。
/// 仅桌面端（Windows/macOS/Linux）支持，移动端不显示入口。
class AudioDeviceService extends GetxService {
  static AudioDeviceService get instance => Get.find<AudioDeviceService>();

  /// 是否支持输出设备选择（仅桌面端）。
  static bool get supported => !Platform.isAndroid && !Platform.isIOS;

  final RxString globalDeviceId = "auto".obs;
  final RxMap<String, String> siteDevices = <String, String>{}.obs;
  final RxMap<String, String> roomDevices = <String, String>{}.obs;

  /// 已探测到的设备列表（避免重复创建临时播放器）。
  List<AudioOutputDevice>? _cachedDevices;

  @override
  void onInit() {
    super.onInit();
    _load();
  }

  void _load() {
    final ls = LocalStorageService.instance;
    globalDeviceId.value = ls.getValue(
      LocalStorageService.kAudioDeviceGlobal,
      "auto",
    );
    final siteRaw = ls.getValue<dynamic>(
      LocalStorageService.kAudioDeviceSites,
      null,
    );
    if (siteRaw is Map) {
      siteDevices.value = {
        for (final entry in siteRaw.entries)
          entry.key.toString(): entry.value.toString(),
      };
    }
    final roomRaw = ls.getValue<dynamic>(
      LocalStorageService.kAudioDeviceRooms,
      null,
    );
    if (roomRaw is Map) {
      roomDevices.value = {
        for (final entry in roomRaw.entries)
          entry.key.toString(): entry.value.toString(),
      };
    }
  }

  /// 清理已失效的设备配置：设备列表变化后，旧的 id 可能已不存在。
  /// 全局值失效回退到 auto；平台/直播间失效则移除（回到跟随上级）。
  void pruneInvalidDevices(List<AudioOutputDevice> available) {
    final validIds = available.map((d) => d.id).toSet();
    if (!validIds.contains(globalDeviceId.value)) {
      setGlobal(AudioOutputDevice.auto.id);
    }
    final invalidSites = siteDevices.entries
        .where((e) => !validIds.contains(e.value))
        .map((e) => e.key)
        .toList();
    for (final key in invalidSites) {
      setSite(key, AudioOutputDevice.inherit.id);
    }
    final invalidRooms = roomDevices.entries
        .where((e) => !validIds.contains(e.value))
        .map((e) => e.key)
        .toList();
    for (final key in invalidRooms) {
      setRoom(key, AudioOutputDevice.inherit.id);
    }
  }

  void setGlobal(String deviceId) {
    globalDeviceId.value = deviceId;
    LocalStorageService.instance.setValue(
      LocalStorageService.kAudioDeviceGlobal,
      deviceId,
    );
  }

  void setSite(String siteId, String deviceId) {
    final next = Map<String, String>.from(siteDevices);
    if (deviceId == AudioOutputDevice.inherit.id) {
      next.remove(siteId);
    } else {
      next[siteId] = deviceId;
    }
    siteDevices.value = next;
    LocalStorageService.instance.setValue(
      LocalStorageService.kAudioDeviceSites,
      next,
    );
  }

  void setRoom(String roomKey, String deviceId) {
    final next = Map<String, String>.from(roomDevices);
    if (deviceId == AudioOutputDevice.inherit.id) {
      next.remove(roomKey);
    } else {
      next[roomKey] = deviceId;
    }
    roomDevices.value = next;
    LocalStorageService.instance.setValue(
      LocalStorageService.kAudioDeviceRooms,
      next,
    );
  }

  /// 解析最终生效的设备 ID：房间 > 平台 > 全局。
  String resolveDeviceId({
    required String siteId,
    required String roomId,
  }) {
    final roomKey = "${siteId}_$roomId";
    final roomDevice = roomDevices[roomKey];
    if (roomDevice != null && roomDevice.isNotEmpty) return roomDevice;
    final siteDevice = siteDevices[siteId];
    if (siteDevice != null && siteDevice.isNotEmpty) return siteDevice;
    return globalDeviceId.value;
  }

  /// 探测可用音频输出设备。
  ///
  /// 用一个临时 Player 实例读取 mpv 的 `audio-device-list` 属性，
  /// 探测完立即 dispose，避免占用音频设备。
  Future<List<AudioOutputDevice>> detectDevices() async {
    if (!supported) return const [];
    final cached = _cachedDevices;
    if (cached != null) return cached;

    Player? probePlayer;
    try {
      probePlayer = Player(
        configuration: PlayerConfiguration(
          title: "Audio Device Probe",
          logLevel: MPVLogLevel.error,
        ),
      );
      final platform = probePlayer.platform;
      if (platform is! NativePlayer) {
        return const [AudioOutputDevice.auto];
      }
      final raw = await platform
          .getProperty("audio-device-list")
          .timeout(const Duration(seconds: 5));
      final devices = <AudioOutputDevice>[AudioOutputDevice.auto];
      final parsed = _parseDeviceList(raw?.toString() ?? "");
      devices.addAll(parsed);
      _cachedDevices = devices;
      return devices;
    } catch (e) {
      Log.d("探测音频设备失败: $e");
      return const [AudioOutputDevice.auto];
    } finally {
      probePlayer?.dispose();
    }
  }

  /// 解析 mpv audio-device-list（mpv node array 的 JSON 表示）。
  List<AudioOutputDevice> _parseDeviceList(String raw) {
    if (raw.trim().isEmpty) return const [];
    final result = <AudioOutputDevice>[];
    final seen = <String>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final name = item["name"]?.toString() ?? "";
            final desc = item["description"]?.toString() ?? name;
            // mpv 自带的 auto 条目由我们自己的"跟随默认设备"代表，跳过重复
            if (name.isNotEmpty && name != "auto" && seen.add(name)) {
              result.add(AudioOutputDevice(id: name, name: desc));
            }
          }
        }
      }
    } catch (e) {
      Log.d("解析音频设备列表失败: $e");
    }
    return result;
  }

  /// 将设备应用到播放器。
  ///
  /// 关键：mpv 里仅设置 `audio-device` 属性不会重建音频输出（AO），
  /// 新设备要等 AO 重新初始化才生效。必须再执行 `ao-reload` 命令。
  /// 否则"跟随系统默认"会一直停留在启动时选定的旧设备上。
  Future<void> applyToPlayer(
    dynamic playerPlatform, {
    required String deviceId,
    bool reload = true,
  }) async {
    if (!supported) return;
    try {
      await playerPlatform.setProperty("audio-device", deviceId);
      Log.d("音频设备已设置: audio-device=$deviceId reload=$reload");
      if (reload) {
        // 强制 mpv 销毁并重建 AO，使新的 audio-device 真正生效。
        // 无播放内容时该命令可能报错，忽略即可。
        try {
          await playerPlatform.command(["ao-reload"]);
          Log.d("音频设备 ao-reload 已执行");
        } catch (e) {
          Log.d("音频设备 ao-reload 失败: $e");
        }
      }
    } catch (e) {
      Log.d("应用音频设备失败: $e");
    }
  }
}
