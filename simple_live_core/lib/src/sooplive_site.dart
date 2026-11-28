import 'dart:convert';

import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';

/// SOOP（原 AfreecaTV）平台实现。
///
/// 接口由用户抓包确认（官网播放器实际调用）：
///   GET https://api-live.sooplive.com/api/v1/live/player-view
///     - type=live & streamerId=<id> → data.isBroadcasting / broadNo / bjNick / title ...
///     - type=aid  & streamerId=<id> & broadNo=<bno> → data.aid
///   GET {resourceManagerDomain}/broad_stream_assign.html
///     ?return_type=<cdn>&broad_key=<bno>-common-master-hls → view_url(m3u8)
///   播放时 m3u8 附加 ?aid=<AID> + Referer: play.sooplive.com
class SoopliveSite extends LiveSite {
  static const String _api = 'https://api-live.sooplive.com/api/v1/live/player-view';

  static const String _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// CDN 备选顺序（接口返回的 cdn 优先，之后依次尝试）
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
        'accept': '*/*',
        if (cookie.trim().isNotEmpty) 'cookie': cookie.trim(),
      };

  @override
  String id = "sooplive";

  @override
  String name = "SOOP";

  @override
  LiveDanmaku getDanmaku() => LiveDanmaku();

  /// 构造 player-view 请求参数。
  Map<String, dynamic> _params(
    String streamerId,
    String type, {
    String broadNo = '',
    String quality = 'HD',
  }) {
    return {
      'streamerId': streamerId,
      'broadNo': broadNo,
      'type': type,
      'pwd': '',
      'playerType': 'html5',
      'streamType': 'common',
      'quality': quality,
      'mode': 'landing',
      'fromApi': '0',
      'isRevive': 'false',
    };
  }

  /// 查 live 数据（type=live），返回 data map。失败返回 null。
  Future<Map<String, dynamic>?> _liveInfo(String roomId) async {
    try {
      final result = await HttpClient.instance.getJson(
        _api,
        queryParameters: _params(roomId, 'live'),
        header: _headers,
      );
      if (result is! Map) return null;
      if ((result['code']?.toString() ?? '') != '0') return null;
      final data = result['data'];
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }

  /// 取 AID（type=aid）。
  Future<String> _getAid(String roomId, String broadNo) async {
    try {
      final result = await HttpClient.instance.getJson(
        _api,
        queryParameters: _params(roomId, 'aid', broadNo: broadNo, quality: 'master'),
        header: _headers,
      );
      if (result is! Map) return '';
      final data = result['data'];
      if (data is! Map) return '';
      return data['aid']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 在线人数（chapi station，顶层 broad），失败返回 0。
  Future<int> _viewerCount(String roomId) async {
    try {
      final result = await HttpClient.instance.getJson(
        'https://chapi.sooplive.co.kr/api/$roomId/station',
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

  bool _isLive(Map<String, dynamic>? info) {
    if (info == null) return false;
    final v = info['isBroadcasting'];
    return v == true || v?.toString() == '1';
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    return _isLive(await _liveInfo(roomId));
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final info = await _liveInfo(roomId);
    final live = _isLive(info);
    final bjId = info?['bjId']?.toString().isNotEmpty == true
        ? info!['bjId'].toString()
        : roomId;
    final online = live ? await _viewerCount(roomId) : 0;
    return LiveRoomDetail(
      roomId: bjId,
      title: info?['title']?.toString().isNotEmpty == true
          ? info!['title'].toString()
          : bjId,
      cover: 'https://liveimg.sooplive.co.kr/m/$roomId',
      userName: info?['bjNick']?.toString().isNotEmpty == true
          ? info!['bjNick'].toString()
          : bjId,
      userAvatar:
          'https://stimg.sooplive.com/LOGO/${roomId.substring(0, roomId.length.clamp(0, 2))}/$roomId/$roomId.jpg',
      online: online,
      status: live,
      url: 'https://play.sooplive.com/$roomId',
      data: info,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    if (!detail.status) return const [];
    return [
      LivePlayQuality(quality: '直播自动', data: 'auto', sort: 1),
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

    // live info：拿 broadNo / cdn / resourceManagerDomain
    Map<String, dynamic>? info = detail.data is Map
        ? Map<String, dynamic>.from(detail.data as Map)
        : null;
    if (info == null || info['broadNo'] == null) {
      info = await _liveInfo(detail.roomId);
    }
    final broadNo = info?['broadNo']?.toString() ?? '';
    if (broadNo.isEmpty) {
      throw StateError('SOOP 无法获取直播编号');
    }

    final aid = await _getAid(detail.roomId, broadNo);
    if (aid.isEmpty) {
      throw StateError('SOOP 无法获取播放令牌');
    }

    var rmd = info?['resourceManagerDomain']?.toString() ?? '';
    if (rmd.isEmpty) rmd = 'https://livestream-manager.sooplive.com';
    if (!rmd.startsWith('http')) rmd = 'https:$rmd';

    final cdns = <String>[];
    final apiCdn = info?['cdn']?.toString();
    if (apiCdn != null && apiCdn.isNotEmpty) cdns.add(apiCdn);
    for (final c in _cdns) {
      if (!cdns.contains(c)) cdns.add(c);
    }

    // 注意：broad_stream_assign.html 返回的 Content-Type 是 text/html，
    // 不能用 getJson（ResponseType.json 解析会失败），必须用 getText 手动解析。
    for (final cdn in cdns) {
      try {
        final text = await HttpClient.instance.getText(
          '$rmd/broad_stream_assign.html',
          queryParameters: {
            'return_type': cdn,
            'broad_key': '$broadNo-common-master-hls',
          },
          header: _headers,
        );
        final decoded = jsonDecode(text);
        final viewUrl = decoded is Map ? decoded['view_url']?.toString() : null;
        if (viewUrl == null || viewUrl.isEmpty) continue;
        final sep = viewUrl.contains('?') ? '&' : '?';
        return LivePlayUrl(
          urls: ['$viewUrl${sep}aid=$aid'],
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
