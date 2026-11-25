import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('BigoCrypto 令牌加密', () {
    test('固定盐/nonce 的加密结果符合 OpenSSL 标准格式', () {
      // 与 Node crypto (aes-256-cbc + EVP_BytesToKey) 输出一致。
      final data = BigoCrypto.buildTokenData(
        '792894618',
        salt: List<int>.generate(8, (i) => i),
        nonce: '0123456789abcdef0123456789abcdef',
      );
      expect(data.startsWith('U2FsdGVkX1'), isTrue); // "Salted__" base64 前缀
      expect(
        data,
        'U2FsdGVkX18AAQIDBAUGBw9CExflNpp/+hw4FEvQ48pkY9f2hYxzYBNOjHbCB45L1kMM+njoY+ywzq8/'
        'nIukZdvMK///nfADHW0eTrVT7LFdOBDiydMHD1bQXb8LIIH6Do5ozXvp+s4E2hv0FCzD0ki6oRber64+'
        'oxi2gXO1wdYtrivtJnDsv2H5yIoOXgvj',
      );
    });

    test('随机调用每次结果不同', () {
      final a = BigoCrypto.buildTokenData('792894618');
      final b = BigoCrypto.buildTokenData('792894618');
      expect(a, isNot(b));
    });
  });

  group('LiveUrlParser Bigo', () {
    test('解析 bigo.tv 数字房间号', () {
      final parsed = LiveUrlParser.parse('https://www.bigo.tv/716418802');
      expect(parsed, isNotNull);
      expect(parsed!.siteId, LiveUrlParser.siteBigoTv);
      expect(parsed.roomId, '716418802');
    });

    test('解析 bigo.tv/cn/ 路径', () {
      final parsed = LiveUrlParser.parse('https://www.bigo.tv/cn/716418802');
      expect(parsed, isNotNull);
      expect(parsed!.roomId, '716418802');
    });

    test('解析 bigo.tv?h= 参数', () {
      final parsed = LiveUrlParser.parse('https://www.bigo.tv/?h=716418802');
      expect(parsed, isNotNull);
      expect(parsed!.roomId, '716418802');
    });

    test('解析 Bigo 短链为需要跟随重定向', () {
      final parsed = LiveUrlParser.parse('https://slink.bigovideo.tv/abc123');
      expect(parsed, isNotNull);
      expect(parsed!.siteId, LiveUrlParser.siteBigoTv);
      expect(parsed.isShortLink, isTrue);
    });
  });

  group('BigoSite 元数据', () {
    test('站点 id/name 与 App 常量一致', () {
      final site = BigoSite();
      expect(site.id, 'bigotv');
      expect(site.name, 'Bigo Live');
    });

    test('分类包含一个公开推荐分区', () async {
      final categories = await BigoSite().getCategores();
      expect(categories.length, 1);
      expect(categories.first.children.length, 1);
      expect(categories.first.children.first.id, '72');
    });

    test('BigoPlayData 字段', () {
      const play = BigoPlayData(
        roomId: '716418802',
        hls: 'https://x.com/a.m3u8',
        alive: true,
        needLogin: false,
        locked: false,
      );
      expect(play.alive, isTrue);
      expect(play.hls, contains('.m3u8'));
    });
  });
}
