/// 房间上次直播时间信息（用于关注列表智能降频）。
class LiveTimeInfo {
  /// 上次开播时间（Unix 秒）。
  final int? lastLiveAt;

  /// 上次下播时间（Unix 秒）。
  final int? lastEndAt;

  const LiveTimeInfo({this.lastLiveAt, this.lastEndAt});

  bool get isValid => (lastLiveAt ?? 0) > 0 || (lastEndAt ?? 0) > 0;
}
