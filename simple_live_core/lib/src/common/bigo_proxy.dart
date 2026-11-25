import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bigo_hls_protection.dart';

/// Bigo 本地 HLS 还原代理。
///
/// Bigo 的 TS 分片被 xorshift 打乱前 2 个包，播放器直接播放会黑屏转圈。
/// 这里启动仅监听 127.0.0.1 的 HTTP 服务：
///
///   GET /m3u8?url=<hls_src>      拉上游 playlist，提取 SEED，
///                                 把每个分片改写成代理地址后返回
///   GET /segment?url=<分片>&seed=<seed>
///                                 拉原始分片，还原前 376 字节后返回
class BigoProxy {
  BigoProxy._();

  static final BigoProxy instance = BigoProxy._();

  HttpServer? _server;
  int? _port;
  Future<int>? _starting;

  static const String _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

  bool get isRunning => _server != null;
  int? get port => _port;

  Future<int> ensureStarted() {
    final existing = _port;
    if (existing != null && _server != null) return Future.value(existing);
    final pending = _starting;
    if (pending != null) return pending;
    _starting = _start();
    return _starting!;
  }

  Future<int> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _port = server.port;
      server.listen(_handleRequest);
      return server.port;
    } finally {
      _starting = null;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      switch (request.uri.path) {
        case '/m3u8':
          await _servePlaylist(request, response);
          break;
        case '/segment':
          await _serveSegment(request, response);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
          response.write('Not Found');
          await response.close();
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        response.write('Proxy error');
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _servePlaylist(HttpRequest request, HttpResponse response) async {
    final target = request.uri.queryParameters['url'] ?? '';
    final source = Uri.tryParse(target);
    if (source == null ||
        (source.scheme != 'http' && source.scheme != 'https')) {
      response.statusCode = HttpStatus.badRequest;
      response.write('Invalid target');
      await response.close();
      return;
    }

    final fetched = await _fetchBytes(target, referer: 'https://www.bigo.tv/');
    if (fetched == null || fetched.statusCode != 200) {
      response.statusCode = HttpStatus.badGateway;
      response.write('Upstream error');
      await response.close();
      return;
    }

    final playlist = utf8.decode(fetched.body, allowMalformed: true);
    final seed = BigoHlsProtection.seed(playlist);
    final rewritten = _rewritePlaylist(playlist, source, seed);

    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.contentTypeHeader,
        'application/vnd.apple.mpegurl');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    response.write(rewritten);
    await response.close();
  }

  /// 把 playlist 中的分片行改写成代理地址。
  String _rewritePlaylist(String playlist, Uri source, int? seed) {
    final buffer = StringBuffer();
    for (final line in playlist.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        buffer.writeln(line);
        continue;
      }
      // 分片行（相对或绝对 URL）
      final segmentUri = source.resolve(trimmed);
      final proxy = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: _port,
        path: '/segment',
        queryParameters: {
          'url': segmentUri.toString(),
          if (seed != null) 'seed': seed.toString(),
        },
      );
      buffer.writeln(proxy.toString());
    }
    return buffer.toString();
  }

  Future<void> _serveSegment(HttpRequest request, HttpResponse response) async {
    final target = request.uri.queryParameters['url'] ?? '';
    final seed = int.tryParse(request.uri.queryParameters['seed'] ?? '');
    final source = Uri.tryParse(target);
    if (source == null ||
        (source.scheme != 'http' && source.scheme != 'https')) {
      response.statusCode = HttpStatus.badRequest;
      response.write('Invalid target');
      await response.close();
      return;
    }

    final fetched = await _fetchBytes(target, referer: 'https://www.bigo.tv/');
    if (fetched == null || fetched.statusCode != 200) {
      response.statusCode = HttpStatus.badGateway;
      response.write('Upstream error');
      await response.close();
      return;
    }

    var bytes = fetched.body;
    if (seed != null && bytes.length >= BigoHlsProtection.prefixBytes) {
      try {
        bytes = BigoHlsProtection.transform(bytes, seed);
      } catch (_) {}
    }

    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    response.add(bytes);
    await response.close();
  }

  Future<_Fetched?> _fetchBytes(String url, {String? referer}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _browserUa);
      if (referer != null) req.headers.set(HttpHeaders.refererHeader, referer);
      final resp = await req.close();
      final body = await resp.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk as List<int>);
        return acc;
      });
      return _Fetched(resp.statusCode, Uint8List.fromList(body));
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 生成代理 URL 交给播放器。
  Future<String> proxyUrlFor(String target) async {
    final p = await ensureStarted();
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: p,
      path: '/m3u8',
      queryParameters: {'url': target},
    ).toString();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
  }
}

class _Fetched {
  final int statusCode;
  final Uint8List body;

  _Fetched(this.statusCode, this.body);
}
