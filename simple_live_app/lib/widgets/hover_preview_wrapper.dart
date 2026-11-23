import 'dart:async';

import 'package:flutter/material.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/platform_utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/hover_preview_service.dart';

/// 鼠标悬停预览包装器：
/// 桌面端且开启开关时，鼠标停留达到配置的秒数后显示直播画面浮层，
/// 鼠标移开立即取消定时器并隐藏预览（避免晃一下就弹窗）。
class HoverPreviewWrapper extends StatefulWidget {
  final FollowUser item;
  final Widget child;

  const HoverPreviewWrapper({
    required this.item,
    required this.child,
    super.key,
  });

  @override
  State<HoverPreviewWrapper> createState() => _HoverPreviewWrapperState();
}

class _HoverPreviewWrapperState extends State<HoverPreviewWrapper> {
  Timer? _hoverTimer;

  bool get _enabled =>
      PlatformUtils.supportsInlineMultiRoom &&
      AppSettingsController.instance.hoverPreviewEnable.value;

  void _onHoverEnter(PointerEvent event) {
    if (!_enabled || widget.item.liveStatus.value != 2) {
      return;
    }
    _cancelTimer();
    final delaySeconds = AppSettingsController.instance
        .effectiveHoverPreviewDelaySeconds;
    _hoverTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!mounted || !_enabled) return;
      unawaited(
        HoverPreviewService.instance.show(widget.item, context),
      );
    });
  }

  void _onHoverExit(PointerEvent event) {
    _cancelTimer();
    if (HoverPreviewService.instance.isShowing.value) {
      unawaited(HoverPreviewService.instance.hide());
    }
  }

  void _cancelTimer() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
  }

  @override
  void dispose() {
    _cancelTimer();
    // 页面销毁时若本项正在预览，确保浮层与播放器被释放，避免残留/泄漏。
    if (HoverPreviewService.instance.isShowing.value) {
      unawaited(HoverPreviewService.instance.hide());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;
    return MouseRegion(
      onEnter: _onHoverEnter,
      onExit: _onHoverExit,
      child: widget.child,
    );
  }
}
