import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_player_controller.dart';
import 'package:simple_live_app/services/mpv_options_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 鼠标悬停直播画面预览（仅桌面端）。
///
/// 全局单例：同一时刻只有一路预览播放器，切换目标时先停止旧的。
/// 由关注页的 MouseRegion + 定时器在悬停达到阈值后调用 show()。
class HoverPreviewService extends GetxService {
  static HoverPreviewService get instance => Get.find<HoverPreviewService>();

  static const double previewWidth = 320;
  static const double previewHeight = 200;
  static const double _edgePadding = 12;

  Player? _player;
  VideoController? _videoController;
  OverlayEntry? _overlayEntry;
  int _loadGeneration = 0;
  String? _currentKey;
  bool _disposed = false;

  final isShowing = false.obs;

  static bool get isDesktop => !Platform.isAndroid && !Platform.isIOS;

  bool get enabled =>
      isDesktop && AppSettingsController.instance.hoverPreviewEnable.value;

  /// 悬停达到阈值后调用：在 [anchor] 附近显示预览浮层。
  Future<void> show(FollowUser item, BuildContext anchorContext) async {
    if (!enabled) return;
    final site = Sites.allSites[item.siteId];
    if (site == null) return;

    final key = "${item.siteId}_${item.roomId}";
    if (_currentKey == key && _overlayEntry != null) {
      return; // 同一目标已在预览
    }

    final generation = ++_loadGeneration;
    _currentKey = key;
    // 先移除旧浮层与旧播放器
    _removeOverlay();
    await _disposePlayer();
    if (generation != _loadGeneration || _disposed) return;

    final overlay = Overlay.of(anchorContext, rootOverlay: true);
    final renderBox = anchorContext.findRenderObject() as RenderBox?;
    final offset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final size = renderBox?.size ?? Size.zero;

    try {
      // 获取播放地址
      final roomDetail =
          await site.liveSite.getRoomDetail(roomId: item.roomId);
      if (generation != _loadGeneration || _disposed) return;
      if (!(roomDetail.status || roomDetail.isRecord)) {
        return; // 未开播不预览
      }
      final qualities =
          await site.liveSite.getPlayQualites(detail: roomDetail);
      if (generation != _loadGeneration || _disposed) return;
      if (qualities.isEmpty) return;
      final playUrl = await site.liveSite.getPlayUrls(
        detail: roomDetail,
        quality: qualities.last, // 预览用最低清晰度，省资源
      );
      if (generation != _loadGeneration || _disposed) return;
      if (playUrl.urls.isEmpty) return;

      var url = playUrl.urls.first;
      if (AppSettingsController.instance.playerForceHttps.value) {
        url = url.replaceAll("http://", "https://");
      }

      final player = Player(
        configuration: PlayerConfiguration(
          title: "预览-${item.userName}",
          logLevel: MPVLogLevel.error,
        ),
      );
      _player = player;
      await MpvOptionsService.applyToPlayer(player);
      if (generation != _loadGeneration || _disposed) {
        await player.dispose();
        return;
      }
      _videoController = VideoController(
        player,
        configuration: MpvOptionsService.videoControllerConfiguration(),
      );
      await player.open(Media(url, httpHeaders: playUrl.headers));
      if (generation != _loadGeneration || _disposed) return;
      // 静音预览
      await player.setVolume(
        PlayerVolumePolicy.internalVolume(
          mobile: false,
          muted: true,
          persisted: 0,
          boostEnabled: false,
        ),
      );
      if (generation != _loadGeneration || _disposed) return;

      _showOverlay(overlay, offset, size, item.userName, roomDetail.title);
    } catch (e) {
      Log.d("悬停预览加载失败: ${item.siteId}/${item.roomId} $e");
      if (generation == _loadGeneration) {
        hide();
      }
    }
  }

  void _showOverlay(
    OverlayState overlay,
    Offset anchorOffset,
    Size anchorSize,
    String userName,
    String roomTitle,
  ) {
    final vc = _videoController;
    if (vc == null) return;
    final screen = MediaQuery.of(overlay.context).size;
    final left = (anchorOffset.dx + anchorSize.width + _edgePadding)
        .clamp(_edgePadding, screen.width - previewWidth - _edgePadding)
        .toDouble();
    final top = anchorOffset.dy
        .clamp(_edgePadding, screen.height - previewHeight - _edgePadding)
        .toDouble();

    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        width: previewWidth,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          color: Colors.black,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: previewWidth,
                height: previewHeight,
                child: Video(controller: vc, controls: NoVideoControls),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                color: Colors.black87,
                child: Text(
                  roomTitle.trim().isEmpty ? userName : roomTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
    isShowing.value = true;
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    isShowing.value = false;
  }

  Future<void> _disposePlayer() async {
    final player = _player;
    _player = null;
    _videoController = null;
    if (player != null) {
      try {
        await player.stop();
        await player.dispose();
      } catch (e) {
        Log.d("释放预览播放器失败: $e");
      }
    }
  }

  /// 鼠标离开：移除浮层并释放播放器。
  Future<void> hide() async {
    _loadGeneration += 1;
    _currentKey = null;
    _removeOverlay();
    await _disposePlayer();
  }

  @override
  void onClose() {
    _disposed = true;
    _removeOverlay();
    unawaited(_disposePlayer());
    super.onClose();
  }
}
