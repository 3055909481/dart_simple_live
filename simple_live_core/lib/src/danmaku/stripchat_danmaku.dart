import 'dart:async';
import 'dart:convert';

import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';

/// Stripchat 弹幕参数（由 StripchatSite.getRoomDetail 注入）。
class StripchatDanmakuArgs {
  /// 主播的数字 ID（不是用户名）。
  final String modelId;

  /// Centrifugo WebSocket 地址（来自 initial-dynamic.websocket.url）。
  final String websocketUrl;

  /// Centrifugo JWT（来自 initial-dynamic.websocket.token）。
  final String token;

  final String roomUrl;
  final String? cookie;

  const StripchatDanmakuArgs({
    required this.modelId,
    required this.websocketUrl,
    required this.token,
    required this.roomUrl,
    this.cookie,
  });
}

/// Stripchat 弹幕（Centrifugo WebSocket 协议）。
///
/// 连接后发 connect 帧，ack 后订阅 newChatMessage@<modelId>，
/// 收到的 push 即聊天消息。心跳为空 JSON 对象 `{}`。
class StripchatDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 10 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  static const String _origin = 'https://stripchat.com';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  WebScoketUtils? _ws;
  StripchatDanmakuArgs? _args;
  int _nextId = 1;
  bool _connected = false;
  final Set<String> _seenMessages = {};
  final List<String> _seenOrder = [];

  @override
  Future start(dynamic args) async {
    if (args is! StripchatDanmakuArgs ||
        args.modelId.isEmpty ||
        args.websocketUrl.isEmpty ||
        args.token.isEmpty) {
      onClose?.call('Stripchat 弹幕参数缺失');
      return;
    }
    _args = args;
    _nextId = 1;
    _seenMessages.clear();
    _seenOrder.clear();
    _connected = false;

    _ws = WebScoketUtils(
      url: args.websocketUrl,
      heartBeatTime: heartbeatTime,
      headers: {'origin': _origin, 'user-agent': _ua},
      onMessage: _handleMessage,
      onReady: () {
        // 连接建立后发 connect 帧（id=1）
        _sendConnect(args.token);
      },
      onHeartBeat: () => _sendLine('{}'),
      onReconnect: () {
        onClose?.call('与 Stripchat 弹幕服务器断开，正在重连');
        _connected = false;
      },
      onClose: (e) {
        onClose?.call('Stripchat 弹幕连接失败：$e');
      },
    );
    _ws?.connect();
  }

  void _handleMessage(dynamic data) {
    final text = data is String
        ? data
        : (data is List<int> ? utf8.decode(data, allowMalformed: true) : null);
    if (text == null) return;
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      _handleLine(line);
    }
  }

  void _handleLine(String line) {
    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    // 空对象为心跳响应
    if (msg.isEmpty) {
      _sendLine('{}');
      return;
    }

    // connect/subscribe 的 ack
    if (msg.containsKey('result') || msg.containsKey('connect')) {
      final id = msg['id'];
      if (id is int && id == 1) {
        // connect ack → 订阅房间频道（id=2）
        final subId = _nextId++;
        _sendLine(jsonEncode({
          'subscribe': {'channel': 'newChatMessage@${_args!.modelId}'},
          'id': subId,
        }));
      } else if (!_connected) {
        _connected = true;
        onReady?.call();
      }
      return;
    }

    final push = msg['push'];
    if (push is! Map) return;
    final channel = push['channel']?.toString() ?? '';
    if (!channel.startsWith('newChatMessage@')) return;
    final pub = push['pub'];
    if (pub is! Map) return;
    final data = pub['data'];
    if (data is! Map) return;
    final message = data['message'];
    if (message is! Map) return;

    // 去重
    final key = message['id']?.toString() ?? message['cacheId']?.toString() ?? '';
    if (key.isNotEmpty && !_remember(key)) return;

    final parsed = parseChatMessage(Map<String, dynamic>.from(message));
    if (parsed != null) onMessage?.call(parsed);
  }

  void _sendConnect(String token) {
    final id = _nextId++;
    _sendLine(jsonEncode({
      'connect': {'token': token, 'name': 'js'},
      'id': id,
    }));
  }

  void _sendLine(String line) {
    _ws?.sendMessage('$line\n');
  }

  bool _remember(String key) {
    if (_seenMessages.contains(key)) return false;
    _seenMessages.add(key);
    _seenOrder.add(key);
    while (_seenOrder.length > 256) {
      _seenMessages.remove(_seenOrder.removeAt(0));
    }
    return true;
  }

  /// 解析聊天消息。抽成静态方法便于离线测试。
  static LiveMessage? parseChatMessage(Map<String, dynamic> message) {
    final type = message['type']?.toString() ?? 'text';
    final details = message['details'] is Map
        ? Map<String, dynamic>.from(message['details'] as Map)
        : <String, dynamic>{};
    final userData = message['userData'] is Map
        ? Map<String, dynamic>.from(message['userData'] as Map)
        : <String, dynamic>{};
    final body = details['body']?.toString().trim() ?? '';
    if (body.isEmpty) return null;
    final username = userData['username']?.toString().trim() ?? '';

    final messageType = switch (type) {
      'text' => LiveMessageType.chat,
      'tip' || 'lovense' => LiveMessageType.gift,
      _ => LiveMessageType.chat,
    };
    return LiveMessage(
      type: messageType,
      userName: username,
      message: body,
      color: LiveMessageColor.white,
    );
  }

  @override
  void heartbeat() {
    _sendLine('{}');
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    onReady = null;
    _ws?.close();
    _ws = null;
    _connected = false;
  }
}
