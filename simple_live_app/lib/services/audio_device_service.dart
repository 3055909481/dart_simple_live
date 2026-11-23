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

  /// mpv 默认设备（auto），始终作为第一项。
  static const auto = AudioOutputDevice(id: "auto", name: "默认设备");

  bool get isAuto => id == "auto";

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

  void setGlobal(String deviceId) {
    globalDeviceId.value = deviceId;
    LocalStorageService.instance.setValue(
      LocalStorageService.kAudioDeviceGlobal,
      deviceId,
    );
  }

  void setSite(String siteId, String deviceId) {
    final next = Map<String, String>.from(siteDevices);
    if (deviceId == "auto") {
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
    if (deviceId == "auto") {
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
            if (name.isNotEmpty && seen.add(name)) {
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

  /// 将设备应用到播放器。deviceId 为 auto 时清除该属性。
  Future<void> applyToPlayer(
    dynamic playerPlatform, {
    required String deviceId,
  }) async {
    if (!supported) return;
    try {
      if (deviceId == "auto") {
        await playerPlatform.setProperty("audio-device", "auto");
      } else {
        await playerPlatform.setProperty("audio-device", deviceId);
      }
    } catch (e) {
      Log.d("应用音频设备失败: $e");
    }
  }
}
