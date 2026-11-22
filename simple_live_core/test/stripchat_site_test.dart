import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('StripchatSite.buildHlsUrl', () {
    final site = StripchatSite();

    test('带 preset 生成对应清晰度直链', () {
      expect(
        site.buildHlsUrl("83018537", "480p"),
        "https://edge-hls.doppiocdn.media/hls/83018537/master/83018537_480p.m3u8",
      );
    });

    test('无 preset 生成默认直链', () {
      expect(
        site.buildHlsUrl("131766698", null),
        "https://edge-hls.doppiocdn.media/hls/131766698/master/131766698.m3u8",
      );
      expect(
        site.buildHlsUrl("131766698", ""),
        "https://edge-hls.doppiocdn.media/hls/131766698/master/131766698.m3u8",
      );
    });

    test('空 streamName 返回空串', () {
      expect(site.buildHlsUrl("", "240p"), "");
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
        containsAll(["girls", "couples"]),
      );
    });
  });

  group('StripchatQualityData 序列化', () {
    test('携带 preset 与 streamName', () {
      final data = StripchatQualityData(
        streamName: "83018537",
        preset: "240p",
        fallbackUrl: "https://example.com/fallback.m3u8",
      );
      expect(data.toString(), contains('"streamName":"83018537"'));
      expect(data.toString(), contains('"preset":"240p"'));
    });
  });
}
