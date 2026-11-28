import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';

/// SOOP（原 AfreecaTV）平台实现。
///
/// 两套接口（参考 DouyinLiveRecorder）：
/// - 新版全球 API（sooplive.com 国际版主播）：
///   GET api.sooplive.com/v2/stream/info/<id> → data.isStream/title
///   GET api.sooplive.com/v2/channel/info/<id> → nickname/channelId
///   播放：global-media.sooplive.com/live/<id>/master.m3u8（无需 AID/BNO）
/// - 旧版 API（韩服）：POST /afreeca/player_live_api.php?bjid=<id>
///   BNO → AID → broad_stream_assign.html → m3u8 + ?aid
///
/// 优先新版，失败/无数据回退旧版。
class SoopliveSite extends LiveSite {
  // 官网播放器实际使用的是 live.sooplive.com（不是 .co.kr），
  // .co.kr 在部分地区会被判为海外导致 RESULT=0 误判未开播。
  static const String _liveBase = 'https://live.sooplive.com';
  static const String _apiPath = '/afreeca/player_live_api.php';
  static const String _stationBase = 'https://chapi.sooplive.co.kr';
  static const String _globalApi = 'https://api.sooplive.com/v2';
  static const String _globalMedia = 'https://global-media.sooplive.com';

  static const String _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _mobileUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
      'AppleWebKit/605.1.15 Version/18.5 Mobile/15E148 Safari/604.1';

  /// 新版 API 要求 client-id（随机 UUID）。
  String _clientId() {
    final r = Random();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }

  Map<String, String> get _globalHeaders => {
        'user-agent': _mobileUserAgent,
        'client-id': _clientId(),
        if (cookie.trim().isNotEmpty) 'cookie': cookie.trim(),
      };

  /// 可用 CDN（参考 yt-dlp，按顺序尝试）
  static const List<String> _cdns = [
    'gcp_cdn',
    'gs_cdn_mobile_web',
    'gs_cdn_pc_web',
    'lg_cdn_pc_web',
    'azure_cdn',
    'aws_cf',
  ];

  /// 用户设置的登录 Cookie（订阅/19+ 直播需要）。
  String cookie = "";

  Map<String, String> get _headers => {
        'user-agent': _userAgent,
        'referer': 'https://play.sooplive.com/',
        'origin': 'https://play.sooplive.com',
        if (cookie.trim().isNotEmpty) 'cookie': cookie.trim(),
      };

  @override
  String id = "sooplive";

  @override
  String name = "SOOP";

  @override
  LiveDanmaku getDanmaku() => LiveDanmaku();

  /// 调用直播信息接口，返回 CHANNEL map。
  Future<Map<String, dynamic>?> _channel(String roomId,
      {Map<String, String>? extraForm}) async {
    try {
      final form = <String, String>{
        'bid': roomId,
        'type': 'live',
        'pwd': '',
        'player_type': 'html5',
        'stream_type': 'common',
        'quality': 'HD',
        'mode': 'landing',
        'from_api': '0',
        'is_revive': 'false',
      };
      if (extraForm != null) form.addAll(extraForm);
      final data = form.entries
          .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final result = await HttpClient.instance.postJson(
        '$_liveBase$_apiPath?bjid=${Uri.encodeComponent(roomId)}',
        data: data,
        header: _headers,
        formUrlEncoded: true,
      );
      if (result is! Map) return null;
      final ch = result['CHANNEL'];
      return ch is Map ? Map<String, dynamic>.from(ch) : null;
    } catch (_) {
      return null;
    }
  }

  /// 新版全球 API：返回 (isStream, title, nickname)。失败返回 null。
  Future<Map<String, dynamic>?> _globalInfo(String roomId) async {
    try {
      final stream = await HttpClient.instance.getJson(
        '$_globalApi/stream/info/$roomId',
        header: _globalHeaders,
      );
      if (stream is! Map) return null;
      final data = stream['data'];
      if (data is! Map) return null;
      final isStream = data['isStream'] == true ||
          data['isStream']?.toString() == '1';

      String nickname = '';
      try {
        final ch = await HttpClient.instance.getJson(
          '$_globalApi/channel/info/$roomId',
          header: _globalHeaders,
        );
        final info = ch is Map
            ? (ch['data']?['streamerChannelInfo'])
            : null;
        if (info is Map) nickname = info['nickname']?.toString() ?? '';
      } catch (_) {}

      return {
        'isStream': isStream,
        'title': data['title']?.toString() ?? '',
        'nickname': nickname,
      };
    } catch (_) {
      return null;
    }
  }

  /// 取在线人数（station 接口，顶层 broad）。
  Future<int> _viewerCount(String roomId) async {
    try {
      final result = await HttpClient.instance.getJson(
        '$_stationBase/api/$roomId/station',
        header: {
          'user-agent': _userAgent,
          if (cookie.trim().isNotEmpty) 'cookie': cookie.trim(),
        },
      );
      if (result is! Map) return 0;
      final broad = result['broad'];
      if (broad is! Map) return 0;
      return int.tryParse('${broad['current_sum_viewer'] ?? 0}') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    // 新版全球 API 优先（国际版主播靠它）
    final global = await _globalInfo(roomId);
    if (global != null) return global['isStream'] as bool;
    // 回退旧版
    final ch = await _channel(roomId);
    if (ch == null) return false;
    return (int.tryParse('${ch['RESULT'] ?? 0}') ?? 0) == 1;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    // 新版全球 API 优先
    final global = await _globalInfo(roomId);
    if (global != null) {
      final live = global['isStream'] as bool;
      return LiveRoomDetail(
        roomId: roomId,
        title: global['title']?.toString().isNotEmpty == true
            ? global['title'].toString()
            : roomId,
        cover: '$_globalMedia/live/$roomId/thumbnail.jpg',
        userName: global['nickname']?.toString().isNotEmpty == true
            ? global['nickname'].toString()
            : roomId,
        userAvatar:
            'https://stimg.sooplive.com/LOGO/${roomId.substring(0, roomId.length.clamp(0, 2))}/$roomId/$roomId.jpg',
        online: 0,
        status: live,
        url: 'https://play.sooplive.com/$roomId',
        data: {'global': true, 'isStream': live},
      );
    }
    // 回退旧版
    final ch = await _channel(roomId);
    final result = int.tryParse('${ch?['RESULT'] ?? 0}') ?? 0;
    final online = result == 1 ? await _viewerCount(roomId) : 0;
    final bjId = ch?['BJID']?.toString().isNotEmpty == true
        ? ch!['BJID'].toString()
        : roomId;
    return LiveRoomDetail(
      roomId: bjId,
      title: ch?['TITLE']?.toString() ?? bjId,
      cover: 'https://liveimg.sooplive.co.kr/m/$roomId',
      userName: ch?['BJNICK']?.toString() ?? bjId,
      userAvatar:
          'https://stimg.sooplive.com/LOGO/${roomId.substring(0, roomId.length.clamp(0, 2))}/$roomId/$roomId.jpg',
      online: online,
      status: result == 1,
      url: 'https://play.sooplive.com/$roomId',
      data: ch,
    );
  }

  Future<_SoopPlayData?> _playData(LiveRoomDetail detail) async {
    // 优先复用 getRoomDetail 拿到的 CHANNEL（含 BNO/RMD/CDN）
    Map<String, dynamic>? ch = detail.data is Map
        ? Map<String, dynamic>.from(detail.data as Map)
        : null;
    if (ch == null || ch['BNO'] == null) {
      ch = await _channel(detail.roomId);
    }
    final bno = ch?['BNO']?.toString() ?? '';
    if (bno.isEmpty) return null;

    // 取 AID
    final token = await _channel(
      detail.roomId,
      extraForm: {
        'bno': bno,
        'type': 'aid',
        'quality': 'master',
      },
    );
    final aid = token?['AID']?.toString() ?? '';
    if (aid.isEmpty) return null;

    final rmd = ch?['RMD']?.toString().isNotEmpty == true
        ? ch!['RMD'].toString()
        : 'https://livestream-manager.sooplive.com';
    final cdns = <String>[];
    final apiCdns = ch?['CDN'];
    if (apiCdns is List) {
      for (final c in apiCdns) {
        final s = c.toString();
        if (s.isNotEmpty) cdns.add(s);
      }
    }
    for (final c in _cdns) {
      if (!cdns.contains(c)) cdns.add(c);
    }
    return _SoopPlayData(bno: bno, aid: aid, rmd: rmd, cdns: cdns);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    if (!detail.status) return const [];
    // 新版全球主播：直接拼 m3u8，无需 AID/BNO
    if (detail.data is Map && detail.data['global'] == true) {
      return [
        LivePlayQuality(
          quality: '直播自动',
          data: {'global': true, 'm3u8': '$_globalMedia/live/${detail.roomId}/master.m3u8'},
          sort: 1,
        ),
      ];
    }
    final play = await _playData(detail);
    if (play == null) return const [];
    return [
      LivePlayQuality(quality: '直播自动', data: play, sort: 1),
    ];
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    if (!detail.status) {
      throw StateError('SOOP 主播未开播');
    }
    // 新版全球主播：直接返回拼接的 m3u8
    if (quality.data is Map && quality.data['global'] == true) {
      final m3u8 = quality.data['m3u8']?.toString() ?? '';
      if (m3u8.isEmpty) throw StateError('SOOP 播放地址为空');
      return LivePlayUrl(
        urls: [m3u8],
        headers: {'user-agent': _userAgent},
      );
    }
    final play = quality.data is _SoopPlayData
        ? quality.data as _SoopPlayData
        : await _playData(detail);
    if (play == null) {
      throw StateError('SOOP 无法获取播放信息');
    }

    // 按 CDN 顺序尝试，取第一个可用的 m3u8
    for (final cdn in play.cdns) {
      try {
        final result = await HttpClient.instance.getJson(
          '${play.rmd}/broad_stream_assign.html',
          queryParameters: {
            'return_type': cdn,
            'broad_key': '${play.bno}-common-master-hls',
          },
          header: _headers,
        );
        final viewUrl = result is Map ? result['view_url']?.toString() : null;
        if (viewUrl == null || viewUrl.isEmpty) continue;
        final sep = viewUrl.contains('?') ? '&' : '?';
        return LivePlayUrl(
          urls: ['$viewUrl${sep}aid=${play.aid}'],
          headers: {
            'referer': 'https://play.sooplive.com/',
            'user-agent': _userAgent,
          },
        );
      } catch (_) {
        continue;
      }
    }
    throw StateError('SOOP 所有 CDN 均无法获取播放地址');
  }
}

/// SOOP 播放数据：BNO + AID + RMD + CDN 列表。
class _SoopPlayData {
  final String bno;
  final String aid;
  final String rmd;
  final List<String> cdns;

  _SoopPlayData({
    required this.bno,
    required this.aid,
    required this.rmd,
    required this.cdns,
  });
}
