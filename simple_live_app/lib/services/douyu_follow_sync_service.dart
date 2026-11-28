import 'dart:async';
import 'dart:math';

import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 把本地关注的斗鱼房间，同步关注到斗鱼账号。
///
/// 高风险写操作，设计原则：
/// - 仅用户手动触发
/// - 分钟级限速（45-90 秒随机波动），模拟人工操作
/// - 单次最多 10 个
/// - 已同步的跳过（douyuSyncedAt）
/// - 遇失败立即停止，不做重试
/// - 失败后保留进度，下次继续
class DouyuFollowSyncService extends GetxService {
  static DouyuFollowSyncService get instance =>
      Get.find<DouyuFollowSyncService>();

  static const int maxPerBatch = 10;
  static const int minIntervalSeconds = 45;
  static const int maxIntervalSeconds = 90;

  final _random = Random();
  DateTime? _lastSyncAt;

  /// 生成一个带随机波动的间隔（45-90 秒）。
  Duration get randomInterval => Duration(
        seconds: minIntervalSeconds +
            (_random.nextDouble() * (maxIntervalSeconds - minIntervalSeconds))
                .round(),
      );

  /// 距上次同步的间隔是否需要等待（防止连续点击触发风控）。
  Duration? get cooldownRemaining {
    if (_lastSyncAt == null) return null;
    final elapsed = DateTime.now().difference(_lastSyncAt!);
    final need = Duration(seconds: minIntervalSeconds);
    return elapsed >= need ? null : need - elapsed;
  }

  final RxBool syncing = false.obs;
  final RxInt syncedCount = 0.obs;
  final RxString lastError = "".obs;

  bool get isLoggedIn => DouyuAccountService.instance.hasCookie.value;

  /// 待同步数量（斗鱼关注、未同步过的）。
  int get pendingCount {
    return FollowService.instance.followList
        .where((f) => f.siteId == Constant.kDouyu && f.douyuSyncedAt == null)
        .length;
  }

  /// 执行一批同步。返回 (成功数, 消息)。
  Future<(int, String)> syncBatch() async {
    if (syncing.value) return (0, "正在同步中");
    if (!isLoggedIn) return (0, "请先登录斗鱼账号");
    final cooldown = cooldownRemaining;
    if (cooldown != null) {
      return (0, "操作太频繁，请 ${cooldown.inSeconds} 秒后再试");
    }
    final site = Sites.allSites[Constant.kDouyu]?.liveSite;
    if (site is! DouyuSite) return (0, "斗鱼站点不可用");

    syncing.value = true;
    lastError.value = "";
    var success = 0;
    var failMsg = "";
    try {
      final targets = FollowService.instance.followList
          .where((f) => f.siteId == Constant.kDouyu && f.douyuSyncedAt == null)
          .take(maxPerBatch)
          .toList();
      if (targets.isEmpty) return (0, "没有需要同步的房间");

      for (int i = 0; i < targets.length; i++) {
        if (!syncing.value) break;
        final item = targets[i];
        final result = await site.followRoom(item.roomId);
        _lastSyncAt = DateTime.now();
        if (result.success) {
          item.douyuSyncedAt = DateTime.now();
          await DBService.instance.addFollow(item);
          success++;
          syncedCount.value++;
          Log.d("斗鱼同步关注成功: ${item.userName}(${item.roomId}) ${result.message}");
        } else {
          failMsg = result.message;
          Log.d("斗鱼同步关注失败: ${item.userName}(${item.roomId}) $failMsg");
          // 失败立即停止，不做重试
          break;
        }
        // 最后一个不用再等
        if (i < targets.length - 1) {
          final interval = randomInterval;
          Log.d("斗鱼同步关注等待 ${interval.inSeconds} 秒后继续");
          await Future.delayed(interval);
        }
      }
    } finally {
      syncing.value = false;
    }
    if (failMsg.isNotEmpty) {
      lastError.value = failMsg;
      return (success, "已同步 $success 个后停止：$failMsg");
    }
    return (success, "本次同步 $success 个，剩余 $pendingCount 个");
  }

  /// 停止同步（用户主动取消）。
  void stop() {
    syncing.value = false;
  }

  /// 重置同步状态（用于重新同步）。
  Future<void> resetSyncedFlags() async {
    for (final f in FollowService.instance.followList) {
      if (f.siteId == Constant.kDouyu) {
        f.douyuSyncedAt = null;
        await DBService.instance.addFollow(f);
      }
    }
    syncedCount.value = 0;
  }
}
