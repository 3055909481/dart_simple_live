import 'package:get/get.dart';
import 'package:hive/hive.dart';

part 'follow_user.g.dart';

@HiveType(typeId: 1)
class FollowUser {
  FollowUser(
      {required this.id,
      required this.roomId,
      required this.siteId,
      required this.userName,
      required this.face,
      required this.addTime,
      this.tag = "全部",
      this.isSpecialFollow = false,
      this.roomTitle = "",
      this.roomCover = "",
      this.previewUpdatedAt,
      this.lastLiveAt,
      this.lastEndAt,
      this.consecutiveOffline = 0,
      this.lastCheckedAt,
      this.invalidStrike = 0});

  ///id=siteId_roomId
  @HiveField(0)
  String id;

  @HiveField(1)
  String roomId;

  @HiveField(2)
  String siteId;

  @HiveField(3)
  String userName;

  @HiveField(4)
  String face;

  @HiveField(5)
  DateTime addTime;

  @HiveField(6)
  String tag;

  @HiveField(7)
  bool isSpecialFollow;

  @HiveField(8)
  String roomTitle;

  @HiveField(9)
  String roomCover;

  @HiveField(10)
  DateTime? previewUpdatedAt;

  /// 上次开播时间（来自服务端，如斗鱼 show_time）。
  @HiveField(11)
  DateTime? lastLiveAt;

  /// 上次下播时间（来自服务端，如斗鱼 end_time）。
  @HiveField(12)
  DateTime? lastEndAt;

  /// 连续未开播次数（本地累计，用于不支持服务端时间的平台）。
  @HiveField(13)
  int consecutiveOffline;

  /// 最后一次成功检查的时间。
  @HiveField(14)
  DateTime? lastCheckedAt;

  /// 连续"房间无效/账号注销"次数。
  @HiveField(15)
  int invalidStrike;

  /// 直播状态
  /// 0=未知(加载中) 1=未开播 2=直播中
  Rx<int> liveStatus = 0.obs;

  /// 开播时间戳
  String? liveStartTime;

  static DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    // 兼容服务端 Unix 秒/毫秒时间戳
    final numeric = num.tryParse(text);
    if (numeric != null && numeric > 0) {
      final ms = numeric > 100000000000 ? numeric.toInt() : numeric.toInt() * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return DateTime.tryParse(text);
  }

  factory FollowUser.fromJson(Map<String, dynamic> json) {
    final roomId = json['roomId']?.toString().trim() ?? "";
    final siteId = json['siteId']?.toString().trim() ?? "";
    final id = (json['id']?.toString().trim().isNotEmpty ?? false)
        ? json['id'].toString().trim()
        : "${siteId}_$roomId";
    final tagValue = json["tag"]?.toString().trim();
    return FollowUser(
      id: id,
      roomId: roomId,
      siteId: siteId,
      userName: json['userName']?.toString() ?? "",
      face: json['face']?.toString() ?? "",
      addTime: DateTime.tryParse(json['addTime']?.toString() ?? "") ??
          DateTime.now(),
      tag: tagValue?.isNotEmpty == true ? tagValue! : "全部",
      isSpecialFollow:
          json["isSpecialFollow"] == true || json["isSpecialFollow"] == 1,
      roomTitle: json["roomTitle"]?.toString() ?? "",
      roomCover: json["roomCover"]?.toString() ?? "",
      previewUpdatedAt:
          DateTime.tryParse(json["previewUpdatedAt"]?.toString() ?? ""),
      lastLiveAt: _parseTime(json["lastLiveAt"]),
      lastEndAt: _parseTime(json["lastEndAt"]),
      consecutiveOffline:
          int.tryParse(json["consecutiveOffline"]?.toString() ?? "") ?? 0,
      lastCheckedAt: _parseTime(json["lastCheckedAt"]),
      invalidStrike: int.tryParse(json["invalidStrike"]?.toString() ?? "") ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'siteId': siteId,
        'userName': userName,
        'face': face,
        'addTime': addTime.toString(),
        'tag': tag,
        'isSpecialFollow': isSpecialFollow,
        'roomTitle': roomTitle,
        'roomCover': roomCover,
        'previewUpdatedAt': previewUpdatedAt?.toIso8601String() ?? "",
        'lastLiveAt': lastLiveAt?.toIso8601String() ?? "",
        'lastEndAt': lastEndAt?.toIso8601String() ?? "",
        'consecutiveOffline': consecutiveOffline,
        'lastCheckedAt': lastCheckedAt?.toIso8601String() ?? "",
        'invalidStrike': invalidStrike,
      };
}
