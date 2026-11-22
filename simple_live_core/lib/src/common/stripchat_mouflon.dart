import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'http_client.dart';

/// Stripchat Mouflon HLS 解密工具。
///
/// Stripchat 的真实 HLS 分片名经过 Mouflon v2 加密：
/// - m3u8 master 里的 `#EXT-X-MOUFLON:PSCH:v2:<pkey>` 给出密钥标识
/// - 真实分片 URL 藏在 `#EXT-X-MOUFLON:URI:<url>` 标签里
/// - 分片 URL 中的加密串需用 `SHA256(pdkey)` 作 XOR 密钥流解密
///
/// 若请求 m3u8 时未带正确 pkey，CDN 会返回 `#EXT-X-MOUFLON-ADVERT`
/// 广告流（只有一段 media.mp4），这就是直接播放只看到 Stripchat 广告的原因。
class StripchatMouflon {
  StripchatMouflon._();

  /// 社区维护的密钥库，启动时异步刷新，获取失败时使用内置密钥兜底。
  static const String _keySource =
      "https://raw.githubusercontent.com/kesamom/stripchat_mouflon/main/stripchat_mouflon_keys.json";

  /// 内置密钥（来自公开仓库，离线兜底）。
  static const Map<String, String> _builtinKeys = {
    "Zokee2OhPh9kugh4": "Quean4cai9boJa5a",
    "Zeechoej4aleeshi": "ubahjae7goPoodi6",
    "Ook7quaiNgiyuhai": "EQueeGh2kaewa3ch",
    "Fq6m2TO2ZeBkRPm9": "xb6di1NF9EFXHUwb",
    "GrRncsoByZmsiT6L": "NigHYyOD9l4rvAEb",
    "1Dzcc6OjP73LKbtI": "Y64UVwX5RrIWnOLp",
    "N2oLovTIXb0o28Uj": "ABE7Sj8jh3oPM2ae",
    "NTK9aqcLmNFMWrpQ": "tOcYOap4Ty1l9Jzb",
    "7uUnbD0jMCB9GH32": "lzCQ6QBTnLpB0zMF",
    "Ohi7eTRBpkAuML0l": "kExe29N2sLFrHGqu",
    "OLzu7QlySkG2fVRn": "CsovScFH9VirSJ4Z",
  };

  static final Map<String, String> _keys = Map.from(_builtinKeys);
  static bool _refreshStarted = false;
  static DateTime? _lastRefresh;

  /// 历史分片缓存：Stripchat 上游 playlist 仅保留约 3 个分片（~6 秒），
  /// 对 mpv 等播放器窗口太短，容易停顿/闪屏。这里缓存已解密的分片，
  /// 重写 playlist 时补足窗口，给播放器更充足的缓冲。
  static final Map<int, String> _segmentCache = {};
  static const int _maxSegmentCache = 60;

  /// 输出 playlist 时保留的分片数量（含历史）。
  static const int _outputWindow = 12;

  /// 清空分片缓存（切换房间/清晰度时调用）。
  static void clearSegmentCache() => _segmentCache.clear();

  /// 当前可用密钥数量。
  static int get keyCount => _keys.length;

  static String? pdkeyFor(String pkey) => _keys[pkey];

  /// 启动后台密钥刷新（幂等）。失败时保留内置密钥。
  static void ensureKeysRefreshed() {
    if (_refreshStarted) {
      final last = _lastRefresh;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(hours: 1)) {
        return;
      }
    }
    _refreshStarted = true;
    refreshKeys().catchError((_) {});
  }

  /// 从公开仓库刷新密钥，合并进本地表。
  static Future<int> refreshKeys() async {
    try {
      final result = await HttpClient.instance.getText(
        _keySource,
        header: {"User-Agent": "Mozilla/5.0"},
      );
      final decoded = json.decode(result);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          if (key is String && value is String && value.isNotEmpty) {
            _keys[key] = value;
          }
        });
        _lastRefresh = DateTime.now();
      }
    } catch (_) {
      // 网络失败时保留内置/上次缓存
    }
    return _keys.length;
  }

  /// 解密 Mouflon v2 加密的分片名。
  ///
  /// 流程：反转字符串 → 补齐 Base64 → 解码 → 与 SHA256(pdkey) 逐字节 XOR。
  static String? decryptSegmentName(String encoded, String pdkey) {
    try {
      final reversed = encoded.split('').reversed.join();
      final padding = '=' * ((4 - reversed.length % 4) % 4);
      final bytes = base64.decode(reversed + padding);
      final key = sha256.convert(utf8.encode(pdkey)).bytes;
      final out = <int>[];
      for (var i = 0; i < bytes.length; i += 1) {
        out.add(bytes[i] ^ key[i % key.length]);
      }
      return utf8.decode(out);
    } catch (_) {
      return null;
    }
  }

  /// 重写 m3u8 playlist：把加密分片还原为普通分片，移除广告占位行。
  ///
  /// 返回 (重写后的文本, 解密出的分片数量)。
  static ({String text, int decrypted}) rewritePlaylist(
    String playlist, {
    Map<String, String>? keyOverride,
  }) {
    final keys = keyOverride ?? _keys;
    final lines = playlist.split(RegExp(r'\r?\n'));

    // 1) 找 pkey → pdkey
    String pkey = "";
    for (final line in lines) {
      final match = RegExp(r'#EXT-X-MOUFLON:PSCH:v2:([A-Za-z0-9]+)')
          .firstMatch(line);
      if (match != null) {
        pkey = match.group(1) ?? "";
        break;
      }
    }
    final pdkey = pkey.isEmpty ? null : keys[pkey];

    // 2) 解析 head 标签 + 解密分片
    final head = <String>["#EXTM3U"];
    String? mapLine;
    var targetDuration = 2;
    var decrypted = 0;

    for (final line in lines) {
      if (line.startsWith("#EXT-X-TARGETDURATION:")) {
        targetDuration =
            int.tryParse(line.split(":").last) ?? targetDuration;
      } else if (line.startsWith("#EXT-X-MAP:")) {
        mapLine = line;
      }
      const uriTag = "#EXT-X-MOUFLON:URI:";
      if (line.startsWith(uriTag) && pdkey != null) {
        final uri = line.substring(uriTag.length).trim();
        final decoded = _decryptUri(uri, pdkey);
        final seq = _extractSequence(uri);
        if (decoded != null && seq != null) {
          _segmentCache[seq] = decoded;
          decrypted += 1;
        }
      }
    }

    if (mapLine != null) {
      head.add("#EXT-X-VERSION:6");
      head.add("#EXT-X-TARGETDURATION:$targetDuration");
      head.add("#EXT-X-INDEPENDENT-SEGMENTS");
      head.add(mapLine);
    }

    // 3) 裁剪缓存
    if (_segmentCache.length > _maxSegmentCache) {
      final allKeys = _segmentCache.keys.toList()..sort();
      for (final key in allKeys.take(_segmentCache.length - _maxSegmentCache)) {
        _segmentCache.remove(key);
      }
    }

    // 4) 从缓存取最近窗口，重新生成分片列表
    final sortedKeys = _segmentCache.keys.toList()..sort();
    if (sortedKeys.isEmpty) {
      return (text: head.join('\n'), decrypted: decrypted);
    }
    final windowKeys = sortedKeys.length > _outputWindow
        ? sortedKeys.sublist(sortedKeys.length - _outputWindow)
        : sortedKeys;
    final firstSeq = windowKeys.first;

    final result = <String>[...head];
    result.add("#EXT-X-MEDIA-SEQUENCE:$firstSeq");
    for (final seq in windowKeys) {
      result.add("#EXTINF:$targetDuration.000");
      result.add(_segmentCache[seq]!);
    }

    return (text: result.join('\n'), decrypted: decrypted);
  }

  /// 从分片 URL 提取序号。
  static int? _extractSequence(String uri) {
    final match = RegExp(r'_(\d+)_[A-Za-z0-9+/=]+_\d+\.mp4').firstMatch(uri);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1) ?? "");
  }

  /// 从 MOUFLON:URI 中定位加密串并解密替换。
  ///
  /// 形如 `.../<id>_<seq>_<encrypted>_<ts>.mp4`。
  static String? _decryptUri(String uri, String pdkey) {
    // 加密串位于倒数第二段，形如 xxx_<enc>_<ts>.mp4
    // 用正则匹配 path 中最后一个下划线分组
    final match = RegExp(r'^(.*_)(\d+)_([A-Za-z0-9+/=]+)_(\d+)(\.mp4.*)$')
        .firstMatch(uri);
    if (match == null) {
      return null;
    }
    final encrypted = match.group(3) ?? "";
    final decoded = decryptSegmentName(encrypted, pdkey);
    if (decoded == null || decoded.isEmpty) {
      return null;
    }
    return "${match.group(1)}${match.group(2)}_${decoded}_${match.group(4)}${match.group(5)}";
  }

  /// 从 master playlist 中解析出 pkey 与第一个变体 URL。
  static ({String pkey, String variantUrl})? parseMaster(String master) {
    final pkeyMatch = RegExp(r'#EXT-X-MOUFLON:PSCH:v2:([A-Za-z0-9]+)')
        .firstMatch(master);
    final variantMatch =
        RegExp(r'https?://[^\s]+\.m3u8[^\s]*').firstMatch(master);
    if (variantMatch == null) {
      return null;
    }
    var variant = variantMatch.group(0) ?? "";
    variant = variant.replaceAll("&amp;", "&");
    final pkey = pkeyMatch?.group(1) ?? "";
    return (pkey: pkey, variantUrl: variant);
  }

  /// 给变体 URL 追加 pkey 参数。
  static String appendPkey(String url, String pkey) {
    if (pkey.isEmpty) {
      return url;
    }
    final sep = url.contains("?") ? "&" : "?";
    return "$url${sep}psch=v2&pkey=$pkey";
  }
}
