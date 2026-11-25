import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Bigo Live 网页令牌请求所需的加密工具。
///
/// Bigo 的 `webjs/status` 接口要求 `data` 参数为 OpenSSL 信封格式：
/// `Salted__` + 8 字节盐 + AES-256-CBC(明文)，密钥/IV 由口令经
/// EVP_BytesToKey(MD5, 单轮) 派生。这是 OpenSSL 的标准格式，
/// 这里用标准 AES 算法独立实现，不依赖任何第三方加密库。
abstract final class BigoCrypto {
  static const String _passphrase = 'undefinedval0x01';

  /// 构造 `webjs/status?data=` 的加密串。
  ///
 /// [timestamp] 为 `webjs/t` 返回的服务器时间字符串；[salt] 为 8 字节盐，
  /// [nonce] 为 32 位小写 hex 随机数。明文为网站公开的固定 JSON 结构。
  static String buildTokenData(
    String timestamp, {
    List<int>? salt,
    String? nonce,
  }) {
    final actualSalt = salt ?? _randomBytes(8);
    if (actualSalt.length != 8) {
      throw ArgumentError.value(actualSalt.length, 'salt', 'needs 8 bytes');
    }
    final dr = nonce ?? _randomHex(16);
    final payload = utf8.encode(jsonEncode({
      'dr': dr,
      'business': 'bigolive-video',
      'scene': '',
      'at_time': timestamp,
      'ver': '2.0',
    }));

    final derived = _evpBytesToKey(utf8.encode(_passphrase), actualSalt, 48);
    final encrypted = _aesCbcEncrypt(
      payload,
      Uint8List.sublistView(derived, 0, 32),
      Uint8List.sublistView(derived, 32, 48),
    );
    return base64Encode([
      ...ascii.encode('Salted__'),
      ...actualSalt,
      ...encrypted,
    ]);
  }

  /// OpenSSL EVP_BytesToKey: D_i = MD5(D_{i-1} + password + salt)，拼接后截取。
  static Uint8List _evpBytesToKey(
    List<int> password,
    List<int> salt,
    int length,
  ) {
    final out = BytesBuilder(copy: false);
    var previous = <int>[];
    while (out.length < length) {
      previous = md5.convert([...previous, ...password, ...salt]).bytes;
      out.add(previous);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }

  static List<int> _randomBytes(int n) {
    final rnd = Random.secure();
    return List<int>.generate(n, (_) => rnd.nextInt(256));
  }

  static String _randomHex(int bytes) {
    final rnd = Random.secure();
    return List<int>.generate(
      bytes * 2,
      (_) => rnd.nextInt(16),
    ).join();
  }

  // ---- 标准 AES-CBC 加密（FIPS 197）----

  static final List<int> _sbox = _buildSbox();
  static final List<int> _rcon = [
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
  ];

  static List<int> _buildSbox() {
    // 通过 GF(2^8) 乘法逆元 + 仿射变换生成 S 盒（标准算法）。
    final box = List<int>.filled(256, 0);
    int mul(int a, int b) {
      var r = 0;
      for (var i = 0; i < 8; i++) {
        if (b & 1 != 0) r ^= a;
        final hi = a & 0x80;
        a = (a << 1) & 0xff;
        if (hi != 0) a ^= 0x1b;
        b >>= 1;
      }
      return r;
    }

    for (var i = 0; i < 256; i++) {
      var inv = 0;
      if (i != 0) {
        for (var j = 1; j < 256; j++) {
          if (mul(i, j) == 1) {
            inv = j;
            break;
          }
        }
      }
      var v = inv;
      for (var shift = 1; shift <= 4; shift++) {
        v ^= ((inv << shift) | (inv >> (8 - shift))) & 0xff;
      }
      box[i] = v ^ 0x63;
    }
    return box;
  }

  static Uint8List _aesCbcEncrypt(List<int> plain, List<int> key, List<int> iv) {
    final pad = 16 - plain.length % 16;
    final data = Uint8List(plain.length + pad)
      ..setRange(0, plain.length, plain)
      ..fillRange(plain.length, plain.length + pad, pad);
    final roundKeys = _expandKey(key);
    final chain = Uint8List.fromList(iv);
    for (var off = 0; off < data.length; off += 16) {
      final block = Uint8List.sublistView(data, off, off + 16);
      for (var i = 0; i < 16; i++) {
        block[i] ^= chain[i];
      }
      _encryptBlock(block, roundKeys);
      chain.setRange(0, 16, block);
    }
    return data;
  }

  /// 扩展密钥：AES-256 为 14 轮，共 15 个 16 字节轮密钥。
  static List<Uint8List> _expandKey(List<int> key) {
    final nk = key.length ~/ 4; // 8 for AES-256
    final rounds = nk + 6; // 14
    final bytes = Uint8List(16 * (rounds + 1))
      ..setRange(0, key.length, key);
    var rconIndex = 0;
    for (var i = nk; i < 4 * (rounds + 1); i++) {
      var t0 = bytes[4 * i - 4];
      var t1 = bytes[4 * i - 3];
      var t2 = bytes[4 * i - 2];
      var t3 = bytes[4 * i - 1];
      if (i % nk == 0) {
        final tmp = t0;
        t0 = _sbox[t1] ^ _rcon[rconIndex++];
        t1 = _sbox[t2];
        t2 = _sbox[t3];
        t3 = _sbox[tmp];
      } else if (nk > 6 && i % nk == 4) {
        t0 = _sbox[t0];
        t1 = _sbox[t1];
        t2 = _sbox[t2];
        t3 = _sbox[t3];
      }
      final prev = 4 * (i - nk);
      bytes[4 * i] = bytes[prev] ^ t0;
      bytes[4 * i + 1] = bytes[prev + 1] ^ t1;
      bytes[4 * i + 2] = bytes[prev + 2] ^ t2;
      bytes[4 * i + 3] = bytes[prev + 3] ^ t3;
    }
    return [
      for (var r = 0; r <= rounds; r++)
        Uint8List.sublistView(bytes, r * 16, r * 16 + 16),
    ];
  }

  static void _encryptBlock(Uint8List s, List<Uint8List> roundKeys) {
    final last = roundKeys.length - 1;
    for (var i = 0; i < 16; i++) {
      s[i] ^= roundKeys[0][i];
    }
    final tmp = Uint8List(16);
    for (var round = 1; round <= last; round++) {
      // SubBytes + ShiftRows（列主序：第 r 行左移 r 列）
      for (var c = 0; c < 4; c++) {
        for (var r = 0; r < 4; r++) {
          tmp[4 * c + r] = _sbox[s[4 * ((c + r) % 4) + r]];
        }
      }
      if (round != last) {
        // MixColumns
        for (var c = 0; c < 4; c++) {
          final a0 = tmp[4 * c];
          final a1 = tmp[4 * c + 1];
          final a2 = tmp[4 * c + 2];
          final a3 = tmp[4 * c + 3];
          final all = a0 ^ a1 ^ a2 ^ a3;
          tmp[4 * c] = a0 ^ all ^ _xtime(a0 ^ a1);
          tmp[4 * c + 1] = a1 ^ all ^ _xtime(a1 ^ a2);
          tmp[4 * c + 2] = a2 ^ all ^ _xtime(a2 ^ a3);
          tmp[4 * c + 3] = a3 ^ all ^ _xtime(a3 ^ a0);
        }
      }
      for (var i = 0; i < 16; i++) {
        s[i] = tmp[i] ^ roundKeys[round][i];
      }
    }
  }

  static int _xtime(int v) => ((v << 1) ^ ((v & 0x80) != 0 ? 0x1b : 0)) & 0xff;
}
