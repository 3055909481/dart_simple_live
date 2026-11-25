import 'dart:typed_data';

/// Bigo Web HLS 保护还原。
///
/// Bigo 的媒体 playlist 带 `#EXT-X-BIGO-WEB-PROTECTION:...,SEED=xxx` 标签，
/// 每个 TS 分片的前两个 188 字节包的前 16 字节被 xorshift 流打乱，
/// 直接播放会看不到画面。用同一个 seed 再做一次变换即可还原。
abstract final class BigoHlsProtection {
  /// 变换涉及的字节数（两个 TS 包）。
  static const int prefixBytes = 376;

  static final RegExp _tag = RegExp(
    r'^#EXT-X-BIGO-WEB-PROTECTION:(.*)$',
    multiLine: true,
    caseSensitive: false,
  );
  static final RegExp _seed = RegExp(
    r'(?:^|,)\s*SEED=([0-9]+)\s*(?:,|$)',
    caseSensitive: false,
  );

  /// 从 playlist 提取 seed； unprotected 返回 null。
  static int? seed(String playlist) {
    final attrs = _tag.firstMatch(playlist)?.group(1);
    if (attrs == null) return null;
    final value = _seed.firstMatch(attrs.trim())?.group(1);
    final seed = value == null ? null : int.tryParse(value);
    if (seed == null || seed > 0xffffffff) return null;
    return seed;
  }

  /// 还原（或打乱）分片的前两个 TS 包。变换是对称的。
  static Uint8List transform(List<int> segment, int seed) {
    if (seed < 0 || seed > 0xffffffff) {
      throw ArgumentError.value(seed, 'seed', 'out of range');
    }
    if (segment.length < prefixBytes) {
      throw ArgumentError.value(segment.length, 'segment', 'too short');
    }
    final packets = Uint8List.fromList(segment);
    for (var packet = 0; packet < 2; packet++) {
      var state = (seed ^ ((packet + 1) * 2654435769)) & 0xffffffff;
      if (state == 0) state = 1831565813;
      for (var offset = 0; offset < 16; offset++) {
        state = (state ^ ((state << 13) & 0xffffffff)) & 0xffffffff;
        state = (state ^ (state >> 17)) & 0xffffffff;
        state = (state ^ ((state << 5) & 0xffffffff)) & 0xffffffff;
        final mask = state & 0xff;
        packets[packet * 188 + offset] ^= mask == 0 ? 165 : mask;
      }
    }
    return packets;
  }
}
