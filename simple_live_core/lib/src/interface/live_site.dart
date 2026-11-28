import 'package:simple_live_core/src/model/live_anchor_item.dart';

import '../interface/live_danmaku.dart';
import '../model/live_category_result.dart';
import '../model/live_contribution_rank.dart';
import '../model/live_message.dart';
import '../model/live_play_url.dart';
import '../model/live_room_detail.dart';
import '../model/live_search_result.dart';
import '../model/live_time_info.dart';

import '../model/live_category.dart';
import '../model/live_play_quality.dart';
import '../model/live_room_item.dart';

class LiveSite {
  /// 站点唯一ID
  String id = "";

  /// 站点名称
  String name = "";

  /// 站点名称
  LiveDanmaku getDanmaku() => LiveDanmaku();

  /// 读取网站的分类
  Future<List<LiveCategory>> getCategores() {
    return Future.value(<LiveCategory>[]);
  }

  /// 搜索直播间
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    return Future.value(
      LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 搜索直播间
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) {
    return Future.value(
      LiveSearchAnchorResult(hasMore: false, items: <LiveAnchorItem>[]),
    );
  }

  /// 读取类目下房间
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 读取推荐的房间
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 读取房间详情
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    return Future.value(
      LiveRoomDetail(
        cover: '',
        online: 0,
        roomId: '',
        status: false,
        title: '',
        url: '',
        userAvatar: '',
        userName: '',
      ),
    );
  }

  /// 读取房间清晰度
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) {
    return Future.value(<LivePlayQuality>[]);
  }

  /// 读取播放链接
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    return Future.value(LivePlayUrl(urls: []));
  }

  /// 查询直播状态
  Future<bool> getLiveStatus({required String roomId}) {
    return Future.value(false);
  }

  /// 读取房间的上次直播时间信息（用于关注列表智能降频）。
  ///
  /// 默认返回 null 表示平台不支持；支持的平台（如斗鱼 show_time/end_time、
  /// 虎牙 iStartTime/iEndTime）可覆盖此方法。时间戳为 Unix 秒。
  Future<LiveTimeInfo?> getLiveTimeInfo({required String roomId}) {
    return Future.value(null);
  }

  /// 读取指定房间的SC
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
    LiveRoomDetail? detail,
  }) {
    return Future.value([]);
  }

  /// 读取指定房间的贡献榜
  Future<List<LiveContributionRankItem>> getContributionRank({
    required String roomId,
    LiveRoomDetail? detail,
  }) {
    return Future.value([]);
  }
}
