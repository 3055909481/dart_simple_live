/// 批量查询到的单个房间状态。
class LiveBatchStatus {
  /// 是否直播中
  final bool isLive;

  /// 标题（可选，用于顺带补齐元数据）
  final String? title;

  /// 封面（可选）
  final String? cover;

  /// 人气/在线数（可选）
  final int? online;

  const LiveBatchStatus({
    required this.isLive,
    this.title,
    this.cover,
    this.online,
  });
}
