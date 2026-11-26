import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('StripchatDanmaku 消息解析', () {
    test('解析普通聊天消息', () {
      final msg = StripchatDanmaku.parseChatMessage({
        'type': 'text',
        'details': {'body': 'hello world'},
        'userData': {'username': 'alice'},
        'createdAt': '2026-11-26T10:00:00Z',
      });
      expect(msg, isNotNull);
      expect(msg!.type, LiveMessageType.chat);
      expect(msg.message, 'hello world');
      expect(msg.userName, 'alice');
    });

    test('礼物消息映射为 gift', () {
      final msg = StripchatDanmaku.parseChatMessage({
        'type': 'tip',
        'details': {'body': 'sent a tip'},
        'userData': {'username': 'bob'},
      });
      expect(msg, isNotNull);
      expect(msg!.type, LiveMessageType.gift);
    });

    test('空消息体返回 null', () {
      final msg = StripchatDanmaku.parseChatMessage({
        'type': 'text',
        'details': {'body': '  '},
        'userData': {'username': 'alice'},
      });
      expect(msg, isNull);
    });

    test('缺失嵌套字段不抛异常', () {
      final msg = StripchatDanmaku.parseChatMessage({
        'type': 'text',
      });
      expect(msg, isNull);
    });
  });
}
