import 'dart:async';
import 'dart:convert';

import 'package:simple_live_core/src/common/bigo_crypto.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/bigo_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';

/// Bigo Live 平台实现。
///
/// 关键点：Bigo 播放地址（hls_src）需要匿名网页令牌。令牌流程为：
/// 1) GET sec.bigo.sg/v1/webjs/t 取服务器时间
/// 2) 用固定口令加密时间等字段，GET webjs/status 取 token
/// 3) POST getInternalStudioInfo?siteId=&verify=&token= 拿直播间信息
/// 令牌“首次使用”才会返回 hls_src，所以进入直播间/取播放地址时都重新取令牌。
class BigoSite extends LiveSite {
  static const String _webOrigin = 'https://www.bigo.tv';
  static const String _tokenHost = 'sec.bigo.sg';
  static const String _apiHost = 'ta.bigo.tv';
  static const String _listPath = '/official_website/OInterfaceWeb/vedioList/72';
  static const String _studioPath = '/official_website/studio/getInternalStudioInfo';
  static const int _pageSize = 20;

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

  static const Map<String, String> _headers = {
    'origin': _webOrigin,
    'referer': '$_webOrigin/',
    'user-agent': _userAgent,
    'accept': 'application/json, text/javascript, */*; q=0.01',
    'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'x-requested-with': 'XMLHttpRequest',
  };

  /// 列表缓存（Bigo 首页列表是一份约 20 条的快照，本地分页）。
  List<LiveRoomItem>? _cachedRooms;
  DateTime? _cachedAt;
  static const Duration _cacheTtl = Duration(seconds: 30);

  BigoSite() {
    id = 'bigotv';
    name = 'Bigo Live';
  }

  @override
  LiveDanmaku getDanmaku() => BigoDanmaku();

  @override
  Future<List<LiveCategory>> getCategores() async {
    return [
      LiveCategory(
        id: 'bigo',
        name: 'Bigo Live',
        children: [
          LiveSubCategory(id: '72', name: '公开推荐', parentId: 'bigo'),
        ],
      ),
    ];
  }

  /// 拉取公开列表（带短缓存）。
  Future<List<LiveRoomItem>> _fetchRooms({bool force = false}) async {
    final cached = _cachedRooms;
    final at = _cachedAt;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < _cacheTtl) {
      return cached;
    }
    final result = await HttpClient.instance.getJson(
      'https://$_apiHost$_listPath',
      queryParameters: {
        'tabType': '00',
        'fetchNum': '10',
        'lang': 'en',
        'countryCode': 'US',
      },
      header: _headers,
    );
    final rooms = <LiveRoomItem>[];
    if (result is Map) {
      final data = result['data'];
      if (data is List) {
        final seen = <String>{};
        for (final row in data) {
          if (row is! Map) continue;
          final item = _parseRoomItem(row);
          if (item != null && seen.add(item.roomId)) rooms.add(item);
        }
      }
    }
    _cachedRooms = rooms;
    _cachedAt = DateTime.now();
    return rooms;
  }

  /// 解析列表行。返回 null 表示跳过该行。
  static LiveRoomItem? _parseRoomItem(Map row) {
    final siteId = row['bigo_id']?.toString() ?? '';
    if (siteId.isEmpty) return null;
    final nickname = row['nick_name']?.toString() ?? '';
    final topic = row['room_topic']?.toString() ?? '';
    final cover = row['cover_m']?.toString() ?? '';
    final viewers = row['user_count'];
    return LiveRoomItem(
      roomId: siteId,
      title: topic.isNotEmpty ? topic : nickname,
      userName: nickname,
      cover: cover,
      online: viewers is int ? viewers : int.tryParse(viewers?.toString() ?? '') ?? 0,
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    final rooms = await _fetchRooms();
    return _page(rooms, page);
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    final rooms = await _fetchRooms();
    return _page(rooms, page);
  }

  LiveCategoryResult _page(List<LiveRoomItem> rooms, int page) {
    if (page < 1) {
      return LiveCategoryResult(hasMore: false, items: const []);
    }
    final start = (page - 1) * _pageSize;
    if (start >= rooms.length) {
      return LiveCategoryResult(hasMore: false, items: const []);
    }
    final end = (start + _pageSize).clamp(start, rooms.length);
    return LiveCategoryResult(
      hasMore: end < rooms.length,
      items: rooms.sublist(start, end),
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) async {
    final query = keyword.trim();
    if (query.isEmpty) {
      return LiveSearchRoomResult(hasMore: false, items: const []);
    }
    // 房间链接/纯 ID：直接查直播间
    final directId = _siteIdFromText(query);
    if (directId != null) {
      try {
        final detail = await getRoomDetail(roomId: directId);
        return LiveSearchRoomResult(
          hasMore: false,
          items: [
            LiveRoomItem(
              roomId: detail.roomId,
              title: detail.title,
              userName: detail.userName,
              cover: detail.cover,
              online: detail.online,
            ),
          ],
        );
      } catch (_) {}
    }
    // 否则在列表里按昵称/标题过滤
    final rooms = await _fetchRooms();
    final needle = query.toLowerCase();
    final filtered = rooms
        .where(
          (r) =>
              r.userName.toLowerCase().contains(needle) ||
              r.title.toLowerCase().contains(needle),
        )
        .toList();
    if (page > 1 || filtered.isEmpty) {
      return LiveSearchRoomResult(hasMore: false, items: const []);
    }
    return LiveSearchRoomResult(hasMore: false, items: filtered);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    final rooms = await _fetchRooms();
    final needle = keyword.trim().toLowerCase();
    final filtered = rooms
        .where((r) => r.userName.toLowerCase().contains(needle))
        .toList();
    return LiveSearchAnchorResult(
      hasMore: false,
      items: filtered.map(_anchorFrom).toList(),
    );
  }

  LiveAnchorItem _anchorFrom(LiveRoomItem r) {
    return LiveAnchorItem(
      roomId: r.roomId,
      avatar: r.cover,
      userName: r.userName,
      liveStatus: true,
    );
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    try {
      final token = await _fetchToken();
      final data = await _askStudio(roomId, token);
      if (data == null) return false;
      return data['alive']?.toString() == '1' &&
          data['needLogin'] != true &&
          data['passRoom'] != true &&
          data['isPaidShow']?.toString() != '1';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final token = await _fetchToken();
    final data = await _askStudio(roomId, token);
    if (data == null) {
      throw StateError('Bigo 未找到直播间：$roomId');
    }
    final alive = data['alive']?.toString() == '1';
    final needLogin = data['needLogin'] == true;
    final locked = data['passRoom'] == true ||
        data['isPaidShow']?.toString() == '1';
    final siteId = data['clientBigoId']?.toString().isNotEmpty == true
        ? data['clientBigoId'].toString()
        : roomId;
    final nickname = data['nick_name']?.toString() ?? '';
    final title = data['roomTopic']?.toString() ?? nickname;
    final avatar = data['avatar']?.toString() ?? '';
    final snapshot = data['snapshot']?.toString() ?? '';
    final hls = data['hls_src']?.toString() ?? '';

    return LiveRoomDetail(
      roomId: siteId,
      title: title,
      cover: snapshot.isNotEmpty ? snapshot : avatar,
      userName: nickname,
      userAvatar: avatar,
      online: 0,
      status: alive,
      url: '$_webOrigin/$siteId',
      notice: needLogin
          ? '该直播间要求登录，暂时无法播放'
          : locked
              ? '该直播间设置了密码或付费观看，暂时无法播放'
              : null,
      data: BigoPlayData(
        roomId: siteId,
        hls: hls,
        alive: alive,
        needLogin: needLogin,
        locked: locked,
      ),
      // 弹幕参数：仅直播中且无登录/密码限制时才连接。
      danmakuData: alive && !needLogin && !locked
          ? BigoDanmakuArgs(
              siteId: siteId,
              ownerId: data['uid']?.toString() ?? '0',
              roomId: data['roomId']?.toString() ?? '',
              token: token,
            )
          : null,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    // 优先用 getRoomDetail 已解析的播放数据；为空时才重新取令牌。
    BigoPlayData play;
    if (detail.data is BigoPlayData && (detail.data as BigoPlayData).hls.isNotEmpty) {
      play = detail.data as BigoPlayData;
    } else {
      play = await _refreshPlayData(detail.roomId);
    }
    if (!play.alive || play.hls.isEmpty || play.needLogin || play.locked) {
      return const [];
    }
    return [
      LivePlayQuality(
        quality: '直播自动',
        data: play,
        sort: 1,
      ),
    ];
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final play = quality.data is BigoPlayData
        ? quality.data as BigoPlayData
        : await _refreshPlayData(detail.roomId);
    if (play.hls.isEmpty) {
      throw StateError('Bigo 未返回播放地址');
    }
    return LivePlayUrl(urls: [play.hls], headers: _headers);
  }

  Future<BigoPlayData> _refreshPlayData(String roomId) async {
    final token = await _fetchToken();
    final data = await _askStudio(roomId, token);
    if (data == null) throw StateError('Bigo 未找到直播间：$roomId');
    return BigoPlayData(
      roomId: data['clientBigoId']?.toString() ?? roomId,
      hls: data['hls_src']?.toString() ?? '',
      alive: data['alive']?.toString() == '1',
      needLogin: data['needLogin'] == true,
      locked: data['passRoom'] == true ||
          data['isPaidShow']?.toString() == '1',
    );
  }

  /// 获取匿名网页令牌。
  Future<String> _fetchToken() async {
    final timeCallback = _callbackName();
    final timeText = await HttpClient.instance.getText(
      'https://$_tokenHost/v1/webjs/t',
      queryParameters: {'callback': timeCallback},
      header: _headers,
    );
    final timestamp = _jsonpValue(timeText, timeCallback)?['time']?.toString();
    if (timestamp == null || timestamp.isEmpty) {
      throw StateError('Bigo 获取服务器时间失败');
    }

    final statusCallback = _callbackName();
    final statusText = await HttpClient.instance.getText(
      'https://$_tokenHost/v1/webjs/status',
      queryParameters: {
        'callback': statusCallback,
        'data': BigoCrypto.buildTokenData(timestamp),
      },
      header: _headers,
    );
    final token = _jsonpValue(statusText, statusCallback)?['token']?.toString();
    if (token == null || token.isEmpty) {
      throw StateError('Bigo 获取网页令牌失败');
    }
    return token;
  }

  /// 带令牌查询直播间信息。
  Future<Map<String, dynamic>?> _askStudio(
    String roomId,
    String token,
  ) async {
    final result = await HttpClient.instance.postJson(
      'https://$_apiHost$_studioPath',
      queryParameters: {
        'siteId': roomId,
        'verify': '',
        'token': token,
      },
      header: _headers,
      formUrlEncoded: true,
    );
    if (result is! Map) return null;
    final code = result['code'];
    if (code != null && code.toString() != '0') return null;
    final data = result['data'];
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  static String _callbackName() {
    final now = DateTime.now();
    return 'jsonpcallback_${now.millisecondsSinceEpoch}_${now.microsecondsSinceEpoch % 1000000}';
  }

  /// 解析 JSONP 响应：`callback({...});` → Map。
  static Map<String, dynamic>? _jsonpValue(String text, String callback) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('$callback(')) return null;
    var body = trimmed.substring(callback.length + 1);
    if (body.endsWith(';')) body = body.substring(0, body.length - 1);
    if (body.endsWith(')')) body = body.substring(0, body.length - 1);
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 从链接或文本中提取 Bigo 房间号。
  static String? _siteIdFromText(String text) {
    final value = text.trim();
    final uri = Uri.tryParse(value);
    if (uri != null && uri.host.isNotEmpty) {
      final host = uri.host.toLowerCase();
      if (host == 'bigo.tv' ||
          host.endsWith('.bigo.tv') ||
          host == 'bigovideo.tv' ||
          host.endsWith('.bigovideo.tv')) {
        final h = uri.queryParameters['h'];
        if (h != null && h.isNotEmpty) return h;
        final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (segs.isNotEmpty) return segs.last;
      }
    }
    return null;
  }
}

/// Bigo 播放所需的私有数据。
class BigoPlayData {
  final String roomId;
  final String hls;
  final bool alive;
  final bool needLogin;
  final bool locked;

  const BigoPlayData({
    required this.roomId,
    required this.hls,
    required this.alive,
    required this.needLogin,
    required this.locked,
  });
}

