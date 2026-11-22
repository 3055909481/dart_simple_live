import 'dart:convert';
import 'dart:io';

import 'stripchat_mouflon.dart';

/// Stripchat 本地 HLS 解密代理。
///
/// 播放器无法直接处理 Mouflon 加密分片（直接请求只会得到广告流），
/// 因此在 App 内启动一个仅监听 127.0.0.1 的 HTTP 服务：
///
///   GET /m3u8?url=<原始 doppiocdn m3u8 地址>
///
/// 代理请求上游 playlist，把加密分片解密重写后返回给播放器。
/// 分片请求本身也经由代理重写后的直链（doppiocdn 分片无需鉴权）。
class StripchatProxy {
  StripchatProxy._();

  static final StripchatProxy instance = StripchatProxy._();

  HttpServer? _server;
  int? _port;
  Future<int>? _starting;

  static const String _browserUa =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";

  bool get isRunning => _server != null;
  int? get port => _port;

  /// 确保代理已启动，返回端口。幂等，并发调用共享同一次启动。
  Future<int> ensureStarted() {
    final existing = _port;
    if (existing != null && _server != null) {
      return Future.value(existing);
    }
    final pending = _starting;
    if (pending != null) {
      return pending;
    }
    _starting = _start();
    return _starting!;
  }

  Future<int> _start() async {
    try {
      StripchatMouflon.ensureKeysRefreshed();
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      _server = server;
      _port = server.port;
      server.listen(_handleRequest);
      return server.port;
    } finally {
      _starting = null;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = responseOf(request);
    try {
      if (request.uri.path != "/m3u8") {
        response.statusCode = HttpStatus.notFound;
        response.write("Not Found");
        await response.close();
        return;
      }
      final target = request.uri.queryParameters["url"] ?? "";
      if (!_isValidTarget(target)) {
        response.statusCode = HttpStatus.badRequest;
        response.write("Invalid target");
        await response.close();
        return;
      }

      final upstream = await _fetchText(target);
      if (upstream == null || upstream.statusCode != 200) {
        response.statusCode = HttpStatus.badGateway;
        response.write("Upstream error");
        await response.close();
        return;
      }

      final lowLatency = request.uri.queryParameters["ll"] == "1";
      final rewritten = StripchatMouflon.rewritePlaylist(
        upstream.body,
        lowLatency: lowLatency,
      );
      response.statusCode = HttpStatus.ok;
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        "application/vnd.apple.mpegurl",
      );
      response.headers.set(HttpHeaders.cacheControlHeader, "no-cache");
      response.write(rewritten.text);
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        response.write("Proxy error");
        await response.close();
      } catch (_) {}
    }
  }

  HttpResponse responseOf(HttpRequest request) => request.response;

  /// 用 dart:io 直接请求上游文本，保留状态码。
  Future<_UpstreamText?> _fetchText(String url) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _browserUa);
      request.headers.set(HttpHeaders.refererHeader, "https://stripchat.com/");
      final resp = await request.close();
      final body = await resp.transform(utf8.decoder).join();
      return _UpstreamText(resp.statusCode, body);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  bool _isValidTarget(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    if (uri.scheme != "http" && uri.scheme != "https") {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host.endsWith(".doppiocdn.com") ||
        host.endsWith(".doppiocdn.org") ||
        host.endsWith(".doppiocdn.net") ||
        host.endsWith(".doppiocdn.live");
  }

  /// 生成代理 URL，交给播放器请求。
  Future<String> proxyUrlFor(String target, {bool lowLatency = false}) async {
    final port = await ensureStarted();
    final query = <String, String>{"url": target};
    if (lowLatency) {
      query["ll"] = "1";
    }
    final uri = Uri(
      scheme: "http",
      host: "127.0.0.1",
      port: port,
      path: "/m3u8",
      queryParameters: query,
    );
    return uri.toString();
  }

  /// 停止代理（如 App 退出时）。
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
  }
}

/// 代理请求结果。
class _UpstreamText {
  final int statusCode;
  final String body;

  _UpstreamText(this.statusCode, this.body);
}
