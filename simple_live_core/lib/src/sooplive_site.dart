import 'dart:convert';

import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';

/// SOOP（原 AfreecaTV）平台实现。
///
/// 直播状态/详情：POST /afreeca/player_live_api.php?bjid=<id>
/// 播放链路（三步，均免登录）：
///   1. 上述接口取 BNO/RMD/CDN
///   2. 同接口 POST bno=<BNO>&type=aid 取 AID
///   3. GET {RMD}/broad_stream_assign.html?return_type=<cdn>&broad_key=<BNO>-common-master-hls
///      取 view_url(m3u8)，播放时附加 ?aid=<AID> + Referer
class SoopliveSite extends LiveSite {
  static const String _liveBase = 'https://live.sooplive.co.kr';
  static const String _apiPath = '/afreeca/player_live_api.php';
  static const String _stationBase = 'https://chapi.sooplive.co.kr';

  static const String _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

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
    final ch = await _channel(roomId);
    if (ch == null) return false;
    return (int.tryParse('${ch['RESULT'] ?? 0}') ?? 0) == 1;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
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
      userAvatar: 'https://profile.img.sooplive.co.kr/LOGO/${roomId.substring(0, roomId.length.clamp(0, 2))}/$roomId/$roomId.jpg',
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
