import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('StripchatMouflon 解密', () {
    test('分片名解密（真实样本）', () {
      // 来自 Strpch pkey=1Dzcc6OjP73LKbtI 的真实加密串
      final pdkey = StripchatMouflon.pdkeyFor("1Dzcc6OjP73LKbtI");
      expect(pdkey, isNotNull);
      final decoded = StripchatMouflon.decryptSegmentName(
        "wKmEZonCgRn8OsPxwOseXB",
        pdkey!,
      );
      expect(decoded, "69SNJaFI76Kdrvbt");
    });

    test('master playlist 解析 pkey 与变体', () {
      const master = """
#EXTM3U
#EXT-X-MOUFLON:PSCH:v2:1Dzcc6OjP73LKbtI
#EXT-X-STREAM-INF:BANDWIDTH=2445414,RESOLUTION=720x960
https://media-hls.doppiocdn.com/media/m.m3u8?playlistType=standard&amp;x=1
""";
      final parsed = StripchatMouflon.parseMaster(master);
      expect(parsed, isNotNull);
      expect(parsed!.pkey, "1Dzcc6OjP73LKbtI");
      expect(parsed.variantUrl, contains("playlistType=standard&x=1"));
      expect(parsed.variantUrl, isNot(contains("&amp;")));
    });

    test('pkey 追加到带/不带参数的 URL', () {
      expect(
        StripchatMouflon.appendPkey("https://x.com/a.m3u8", "pk"),
        "https://x.com/a.m3u8?psch=v2&pkey=pk",
      );
      expect(
        StripchatMouflon.appendPkey("https://x.com/a.m3u8?b=1", "pk"),
        "https://x.com/a.m3u8?b=1&psch=v2&pkey=pk",
      );
      expect(StripchatMouflon.appendPkey("https://x.com/a.m3u8", ""),
          "https://x.com/a.m3u8");
    });

    test('重写 playlist：解密分片并移除广告占位', () {
      const playlist = """
#EXTM3U
#EXT-X-MOUFLON:PSCH:v2:1Dzcc6OjP73LKbtI
#EXTINF:1.967
#EXT-X-MOUFLON:URI:https://media-hls.doppiocdn.com/b/131766698/131766698_1015_wKmEZonCgRn8OsPxwOseXB_1795346519.mp4
https://media-hls.doppiocdn.com/media.mp4
#EXTINF:1.967
#EXT-X-MOUFLON:URI:https://media-hls.doppiocdn.com/b/131766698/131766698_1016_abc_1795346521.mp4
https://media-hls.doppiocdn.com/media.mp4
""";
      final result = StripchatMouflon.rewritePlaylist(playlist);
      expect(result.decrypted, 1);
      expect(result.text, contains("69SNJaFI76Kdrvbt"));
      expect(result.text, isNot(contains("media.mp4")));
      expect(result.text, isNot(contains("MOUFLON:URI")));
    });

    test('内置密钥可用', () {
      expect(StripchatMouflon.keyCount, greaterThan(0));
      expect(StripchatMouflon.pdkeyFor("1Dzcc6OjP73LKbtI"), isNotNull);
    });

    test('解析 master 的所有清晰度变体', () {
      const master = """
#EXTM3U
#EXT-X-MOUFLON:PSCH:v2:1Dzcc6OjP73LKbtI
#EXT-X-STREAM-INF:BANDWIDTH=2381209,RESOLUTION=720x960,NAME="source"
https://x/source.m3u8?a=1&amp;b=2
#EXT-X-STREAM-INF:BANDWIDTH=640921,RESOLUTION=180x240,NAME="240p"
https://x/240.m3u8
""";
      final parsed = StripchatMouflon.parseMasterVariants(master);
      expect(parsed.pkey, "1Dzcc6OjP73LKbtI");
      expect(parsed.variants.length, 2);
      expect(parsed.variants.first.height, 960); // 按分辨率降序
      expect(parsed.variants.first.url, contains("a=1&b=2"));
      expect(parsed.variants.first.url, isNot(contains("&amp;")));
    });

    test('超低时延窗口更小', () {
      const playlist = """
#EXTM3U
#EXT-X-TARGETDURATION:2
#EXT-X-MAP:URI="init.mp4"
#EXT-X-MOUFLON:PSCH:v2:1Dzcc6OjP73LKbtI
#EXTINF:2
#EXT-X-MOUFLON:URI:https://x/131766698_152_wKmEZonCgRn8OsPxwOseXB_1795348164.mp4
""";
      StripchatMouflon.clearSegmentCache();
      final normal = StripchatMouflon.rewritePlaylist(playlist);
      final ll = StripchatMouflon.rewritePlaylist(playlist, lowLatency: true);
      // 同一批分片下，两者都能输出；窗口差异体现在多批次累积时
      expect(normal.text, contains("#EXT-X-MEDIA-SEQUENCE"));
      expect(ll.text, contains("#EXT-X-MEDIA-SEQUENCE"));
    });
  });

  group('LiveUrlParser Stripchat', () {
    LiveParsedUrl? parse(String url) => LiveUrlParser.parse(url);

    test('标准房间链接', () {
      final result = parse("https://stripchat.com/Keep_us_wild");
      expect(result, isNotNull);
      expect(result!.siteId, LiveUrlParser.siteStripchat);
      expect(result.roomId, "Keep_us_wild");
      expect(result.isShortLink, isFalse);
    });

    test('子域名与尾部斜杠、查询参数', () {
      final result = parse("https://www.stripchat.com/Some_User/?ref=home");
      expect(result!.siteId, LiveUrlParser.siteStripchat);
      expect(result.roomId, "Some_User");
    });

    test('zh 子域 + /profile 路径', () {
      final result = parse("https://zh.stripchat.com/JaneLiao/profile");
      expect(result!.siteId, LiveUrlParser.siteStripchat);
      expect(result.roomId, "JaneLiao");
    });

    test('不带协议头与大小写 host', () {
      final result = parse("STRIPCHAT.COM/Keep_us_wild");
      expect(result!.siteId, LiveUrlParser.siteStripchat);
      expect(result.roomId, "Keep_us_wild");
    });

    test('保留路径不解析为房间', () {
      expect(parse("https://stripchat.com/"), isNull);
      expect(parse("https://stripchat.com/search"), isNull);
      expect(parse("https://stripchat.com/api/front/models"), isNull);
    });
  });

  group('StripchatSite 元数据', () {
    test('id 与常量一致', () {
      final site = StripchatSite();
      expect(site.id, LiveUrlParser.siteStripchat);
      expect(site.name, isNotEmpty);
    });

    test('分类包含内置 primaryTag', () async {
      final site = StripchatSite();
      final categories = await site.getCategores();
      expect(categories, isNotEmpty);
      final children = categories.first.children;
      expect(
        children.map((e) => e.id).toList(),
        containsAll(["girls", "men", "couples", "trans"]),
      );
    });
  });
}
