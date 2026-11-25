import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';

/// Bigo Live 弹幕参数。
class BigoDanmakuArgs {
  final String siteId;
  final String ownerId;
  final String roomId;
  final String? token;

  const BigoDanmakuArgs({
    required this.siteId,
    required this.ownerId,
    required this.roomId,
    this.token,
  });
}

/// Bigo Live 弹幕（WebSocket 文本帧协议）。
///
/// 协议流程：连接后服务端先发质询(256) → 客户端应答(79108) → 登录(512279)
/// → 登录成功(512535) → 进房(1304) → 进房成功(1560) → 请求人数(10776)。
/// 聊天帧为 2584，心跳为 791（10 秒）。
class BigoDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 10 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  static const String _endpoint = 'wss://wss.bigolive.tv/live/official/web';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
  static const Map<String, dynamic> _headers = {
    'origin': 'https://www.bigo.tv',
    'user-agent': _ua,
  };

  static const int _challengeUri = 256;
  static const int _answerUri = 79108;
  static const int _loginUri = 512279;
  static const int _loginReplyUri = 512535;
  static const int _enterUri = 1304;
  static const int _enterReplyUri = 1560;
  static const int _usersUri = 10776;
  static const int _usersReplyUri = 11032;
  static const int _textUri = 2584;
  static const int _audienceUri = 10264;
  static const int _pingUri = 791;

  WebScoketUtils? _ws;
  late BigoDanmakuArgs _args;
  String? _visitorId;
  String? _visitorToken;
  String? _visitorName;
  String? _deviceId;
  bool _answered = false;
  bool _loggedIn = false;
  bool _entered = false;
  Timer? _loginTimer;
  final Random _random = Random.secure();

  @override
  Future start(dynamic args) async {
    if (args is! BigoDanmakuArgs) {
      onClose?.call('Bigo 弹幕参数缺失');
      return;
    }
    _args = args;
    _answered = false;
    _loggedIn = false;
    _entered = false;

    // 游客账号：WebSocket 登录所需。
    try {
      await _ensureVisitor();
    } catch (e) {
      onClose?.call('Bigo 游客账号获取失败：$e');
      return;
    }

    _ws = WebScoketUtils(
      url: _endpoint,
      heartBeatTime: heartbeatTime,
      headers: _headers,
      onMessage: _handleFrame,
      onReady: () {
        onReady?.call();
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call('与 Bigo 弹幕服务器断开，正在重连');
      },
      onClose: (e) {
        onClose?.call('Bigo 弹幕连接失败：$e');
      },
    );
    _ws?.connect();
  }

  /// 获取匿名游客账号（WebSocket 登录需要 uid + token）。
  Future<void> _ensureVisitor() async {
    final alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final hash =
        List<int>.generate(32, (_) => _random.nextInt(16)).map((v) => v.toRadixString(16)).join();
    final tag =
        List<int>.generate(6, (_) => _random.nextInt(alphabet.length)).map((v) => alphabet[v]).join();
    _deviceId = 'web_${hash}_${tag}_${DateTime.now().millisecondsSinceEpoch}';

    final result = await HttpClient.instance.postJson(
      'https://ta.bigo.tv/official_website/studio/getWebSocketLink',
      header: {
        ..._headers,
        'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
      },
      data: 'deviceId=${Uri.encodeQueryComponent(_deviceId!)}',
      formUrlEncoded: true,
    );
    if (result is! Map || result['code']?.toString() != '0') {
      throw StateError('getWebSocketLink 返回异常');
    }
    final data = result['data'];
    if (data is! Map) throw StateError('getWebSocketLink 无数据');
    _visitorId = data['userId']?.toString();
    final rawToken = data['uidToken']?.toString() ?? '';
    _visitorToken = rawToken.replaceAll('###VER2', '');
    _visitorName = data['userName']?.toString();
    if (_visitorId == null || _visitorId!.isEmpty || _visitorToken!.isEmpty) {
      throw StateError('getWebSocketLink 游客信息无效');
    }
  }

  void _handleFrame(dynamic data) {
    final text = data is String
        ? data
        : (data is List<int> ? utf8.decode(data, allowMalformed: true) : null);
    if (text == null) return;
    final brace = text.indexOf('{');
    if (brace < 0) return;
    final uri = int.tryParse(text.substring(0, brace).replaceAll(RegExp(r'[\s\x00]'), ''));
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(text.substring(brace));
      if (decoded is Map) body = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    if (uri == null || body == null) return;

    switch (uri) {
      case _challengeUri:
        final challenge = body['challenge']?.toString();
        if (challenge != null && challenge.isNotEmpty) {
          _send(_answerFrame(challenge));
          _answered = true;
          _loginTimer?.cancel();
          _loginTimer = Timer(const Duration(seconds: 1), _doLogin);
        }
        break;
      case _loginReplyUri:
        if (body['res']?.toString() == '200') {
          _loggedIn = true;
          _send(_enterFrame());
        }
        break;
      case _enterReplyUri:
        if (body['resCode']?.toString() == '200') {
          final sid = body['sid']?.toString() ?? '';
          if (sid.isEmpty || sid == '0') {
            onClose?.call('该 Bigo 直播间当前没有直播');
            return;
          }
          _entered = true;
          onReady?.call();
          _send(_usersFrame());
        }
        break;
      case _textUri:
        _handleChat(body);
        break;
      case _audienceUri:
      case _usersReplyUri:
        _handleAudience(body);
        break;
    }
  }

  void _doLogin() {
    if (!_answered || _loggedIn) return;
    _send(_loginFrame());
  }

  String _answerFrame(String challenge) {
    final time = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final tail = challenge.length > 8
        ? challenge.substring(challenge.length - 8)
        : challenge;
    final sign = md5
        .convert(utf8.encode('60#4#5#$time#1#1#1#1#$tail'))
        .toString();
    return '$_answerUri${jsonEncode({
      'appId': '60',
      'osType': '4',
      'clientVersion': '5',
      'timeStamp': time,
      'nonce': '1',
      'reservedForSecurity': '1',
      'appSign': '1',
      'redundancy': '1',
      'sign': sign,
    })}';
  }

  String _loginFrame() {
    return '$_loginUri${jsonEncode({
      'uid': _visitorId,
      'cookie': _visitorToken,
      'secret': '0',
      'userName': _visitorName ?? '0',
      'deviceId': _deviceId,
      'userFlag': '0',
      'status': '0',
      'password': '0',
      'sdkVersion': '0',
      'displayType': '0',
      'pbVersion': '0',
      'lang': 'cn',
      'loginLevel': '0',
      'clientVersionCode': '0',
      'clientType': '7',
      'clientOsVer': '0',
      'netConf': {
        'clientIp': '0',
        'proxySwitch': '0',
        'proxyTimestamp': '0',
        'mcc': '0',
        'mnc': '0',
        'countryCode': 'CN',
      },
    })}';
  }

  String _enterFrame() {
    return '$_enterUri${jsonEncode({
      'secretKey': '0',
      'seqId': '${DateTime.now().millisecondsSinceEpoch}',
      'roomId': _args.roomId,
      'reserver': '1',
      'clientVersion': '0',
      'clientType': '7',
      'version': '15',
      'deviceid': _deviceId,
      'other': <Object>[],
    })}';
  }

  String _usersFrame() {
    return '$_usersUri${jsonEncode({
      'uid': _args.ownerId,
      'seqId': '${DateTime.now().millisecondsSinceEpoch}',
      'roomid': _args.roomId,
      'contribution': '0',
      'enterTimestamp': '0',
      'number': '0',
      'ident': '0',
      'userGrade': '0',
      'version': '0',
      'lastUserBeanGrade': '0',
      'lastUserId': '0',
      'others': <Object>[],
    })}';
  }

  void _handleChat(Map<String, dynamic> frame) {
    if (frame['room_id']?.toString() != _args.roomId) return;
    final payload = frame['payload'];
    if (payload is! Map) return;
    final tag = int.tryParse(payload['tag']?.toString() ?? '');
    if (tag != 1 && tag != 2) return;
    final content = payload['content']?.toString();
    if (content == null || content.isEmpty) return;
    try {
      final decoded = jsonDecode(
        utf8.decode(base64.decode(base64.normalize(content.trim()))),
      );
      if (decoded is! Map) return;
      final text = decoded['m']?.toString().trim() ?? '';
      if (text.isEmpty) return;
      final name = decoded['n']?.toString().trim() ?? '';
      onMessage?.call(
        LiveMessage(
          type: LiveMessageType.chat,
          userName: name,
          message: text,
          color: LiveMessageColor.white,
        ),
      );
    } catch (_) {}
  }

  void _handleAudience(Map<String, dynamic> frame) {
    final value = frame['totalUserCount'] ?? frame['total'];
    final count = int.tryParse(value?.toString() ?? '');
    if (count == null || count < 0) return;
    onMessage?.call(
      LiveMessage(
        type: LiveMessageType.online,
        userName: '',
        message: '',
        data: count,
        color: LiveMessageColor.white,
      ),
    );
  }

  void _send(String frame) {
    _ws?.sendMessage(frame);
  }

  @override
  void heartbeat() {
    if (!_loggedIn) return;
    _send('$_pingUri${jsonEncode({
      'status': '0',
      'seqid': '${DateTime.now().millisecondsSinceEpoch}',
      'flag': '0',
      'roomId': '0',
      'ownerStatus': '0',
      'micUid': '0',
    })}');
  }

  @override
  Future stop() async {
    _loginTimer?.cancel();
    _loginTimer = null;
    onMessage = null;
    onClose = null;
    onReady = null;
    _ws?.close();
    _ws = null;
  }
}
