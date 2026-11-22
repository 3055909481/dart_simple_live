import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/platform_identity.dart';
import 'package:simple_live_core/src/common/stripchat_mouflon.dart';
import 'package:simple_live_core/src/common/stripchat_proxy.dart';

/// Stripchat 站点实现。
///
/// 数据接口为站点公开的 `api/front` 前端接口：
/// - 列表/分类：`GET /api/front/models?primaryTag=<tag>&limit=&offset=`
/// - 详情：模型主页 `https://stripchat.com/<username>` 内嵌的
///   `window.__PRELOADED_STATE__`（该站未开放单模型 JSON 接口）
/// - 播放：CDN master playlist 经本地 Mouflon 解密代理重写后播放（见 stripchat_proxy.dart）
///
/// 该站接口对请求头较敏感，统一带浏览器 UA + Referer + Accept。
class StripchatSite implements LiveSite {
  static const String _baseUrl = "https://stripchat.com";

  static final Map<String, String> _headers = {
    "User-Agent": PlatformIdentity.stripchatUserAgent,
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "$_baseUrl/",
    "Origin": _baseUrl,
  };

  /// primaryTag 是具有实际意义的分类维度。
  /// 站点 tag 接口未开放，这里按公开前端已知的取值内置。
  static final List<LiveSubCategory> _primaryTags = [
    LiveSubCategory(id: "girls", name: "女主播", parentId: "recommend"),
    LiveSubCategory(id: "couples", name: "情侣", parentId: "recommend"),
  ];

  /// 搜索缓存：按关键词缓存一定时间内拉到的全量模型，避免逐页重复请求。
  final Map<String, _SearchCache> _searchCache = {};

  @override
  String id = "stripchat";

  @override
  String name = "Stripchat";

  @override
  LiveDanmaku getDanmaku() => LiveDanmaku();

  Future<dynamic> _getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    Map<String, String>? extraHeaders,
  }) {
    final headers = Map<String, String>.from(_headers);
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }
    return HttpClient.instance.getJson(
      "$_baseUrl$path",
      queryParameters: queryParameters,
      header: headers,
    );
  }

  Future<String> _getText(String path) {
    return HttpClient.instance.getText(
      "$_baseUrl$path",
      header: _headers,
    );
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    // 该站没有公开分类树接口，以 primaryTag 作为一级分类。
    return [
      LiveCategory(
        id: "recommend",
        name: "推荐",
        children: List<LiveSubCategory>.from(_primaryTags),
      ),
    ];
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    return _fetchModels(primaryTag: "girls", page: page);
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    // 子分类 id 即 primaryTag。
    return _fetchModels(primaryTag: category.id, page: page);
  }

  /// 统一的分页模型列表解析。
  Future<LiveCategoryResult> _fetchModels({
    required String primaryTag,
    int page = 1,
  }) async {
    const pageSize = 30;
    final offset = (page - 1) * pageSize;
    final result = await _getJson(
      "/api/front/models",
      queryParameters: {
        "limit": pageSize,
        "offset": offset,
        "primaryTag": primaryTag,
      },
    );

    if (result is! Map || result["models"] is! List) {
      throw CoreError("Stripchat 列表数据结构变更，请稍后重试");
    }

    final models = result["models"] as List;
    final items = <LiveRoomItem>[];
    for (final item in models) {
      final room = _parseRoomItem(item);
      if (room != null) {
        items.add(room);
      }
    }

    final total = (result["filteredCount"] ?? result["totalCount"] ?? 0);
    final totalInt = total is int ? total : int.tryParse("$total") ?? 0;
    return LiveCategoryResult(
      hasMore: offset + models.length < totalInt,
      items: items,
    );
  }

  LiveRoomItem? _parseRoomItem(dynamic item) {
    if (item is! Map) {
      return null;
    }
    final username = item["username"]?.toString() ?? "";
    if (username.isEmpty) {
      return null;
    }
    final topic = _firstNonEmptyString([
      item["topic"],
      item["groupShowTopic"],
    ]);
    final viewers = item["viewersCount"] ?? 0;
    return LiveRoomItem(
      roomId: username,
      title: topic.isEmpty ? username : topic,
      cover: _firstNonEmptyString([
        item["previewUrlThumbSmall"],
        item["previewUrl"],
        item["avatarUrl"],
      ]),
      userName: username,
      online: int.tryParse("$viewers") ?? 0,
    );
  }

  String _firstNonEmptyString(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString() ?? "";
      if (text.isNotEmpty) {
        return text;
      }
    }
    return "";
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    // 优先解析模型主页内嵌的 SSR 状态：一次请求即可拿到用户名、头像、
    // 直播状态、streamName 与清晰度，且不受列表接口的 limit 上限影响。
    final html = await _getText("/$roomId");
    final state = _extractPreloadedState(html);
    if (state != null) {
      final viewCam = state["viewCam"];
      if (viewCam is Map && viewCam["isModelNotFounded"] != true) {
        return _detailFromPageState(state, roomId);
      }
    }

    // 页面结构变更时，退回到列表接口按 username 查找。
    final cached = await _findModelInList(roomId);
    if (cached != null) {
      return _detailFromModel(cached);
    }
    throw CoreError("Stripchat 房间数据解析失败，请稍后重试");
  }

  /// 在若干页列表数据中查找指定 username，并缓存结果供详情/状态复用。
  Future<Map<String, dynamic>?> _findModelInList(String username) async {
    // 站点列表接口 limit 上限为 80，超过会返回 400 invalid 'limit' value。
    const pageSize = 60;
    const maxPages = 5;
    final lowerName = username.toLowerCase();

    for (final tag in _primaryTags) {
      for (var page = 0; page < maxPages; page += 1) {
        final result = await _getJson(
          "/api/front/models",
          queryParameters: {
            "limit": pageSize,
            "offset": page * pageSize,
            "primaryTag": tag.id,
          },
        );
        if (result is! Map || result["models"] is! List) {
          break;
        }
        for (final item in result["models"]) {
          if (item is! Map) {
            continue;
          }
          final name = item["username"]?.toString().toLowerCase() ?? "";
          if (name == lowerName) {
            return Map<String, dynamic>.from(item);
          }
        }
        final total = result["filteredCount"] ?? 0;
        final totalInt = total is int ? total : int.tryParse("$total") ?? 0;
        if ((page + 1) * pageSize >= totalInt) {
          break;
        }
      }
    }
    return null;
  }

  LiveRoomDetail _detailFromModel(Map<String, dynamic> model) {
    final username = model["username"]?.toString() ?? "";
    final streamName = _resolveStreamName(model);
    final isLive = model["isLive"] == true || model["isOnline"] == true;
    final presets = _parsePresets(model["presets"]);
    final topic = _firstNonEmptyString([
      model["topic"],
      model["groupShowTopic"],
    ]);
    final viewers = model["viewersCount"] ?? 0;

    return LiveRoomDetail(
      roomId: username,
      title: topic.isEmpty ? username : topic,
      cover: _firstNonEmptyString([
        model["previewUrlThumbSmall"],
        model["previewUrl"],
        model["avatarUrl"],
      ]),
      userName: username,
      userAvatar: model["avatarUrl"]?.toString() ?? "",
      online: int.tryParse("$viewers") ?? 0,
      introduction: topic.isEmpty ? null : topic,
      status: isLive,
      url: "$_baseUrl/$username",
      data: StripchatRoomData(
        streamName: streamName,
        presets: presets,
        hlsPlaylist: model["hlsPlaylist"]?.toString(),
      ),
    );
  }

  LiveRoomDetail _detailFromPageState(Map<String, dynamic> state, String roomId) {
    final viewCam = state["viewCam"];
    final viewCamBase = state["viewCamBase"];
    final model = viewCam is Map ? viewCam["model"] : null;
    final modelMap = model is Map ? model : <dynamic, dynamic>{};

    final username = modelMap["username"]?.toString() ?? roomId;
    final streamName = _resolveStreamNameFromState(viewCam, viewCamBase);
    final topic = viewCam is Map ? viewCam["topic"]?.toString() : null;
    final avatar = modelMap["avatarUrl"]?.toString() ?? "";
    final isLive = modelMap["isLive"] == true;

    List<String> presets = const [];
    if (viewCamBase is Map) {
      final settings = viewCamBase["broadcastSettings"];
      if (settings is Map) {
        presets = _parsePresets(settings["presets"]);
      }
    }

    return LiveRoomDetail(
      roomId: username,
      title: _firstNonEmptyString([topic, username]),
      cover: avatar,
      userName: username,
      userAvatar: avatar,
      online: 0,
      introduction: topic,
      status: isLive,
      url: "$_baseUrl/$username",
      data: StripchatRoomData(
        streamName: streamName,
        presets: presets,
      ),
    );
  }

  /// 提取页面内嵌的 window.__PRELOADED_STATE__ JSON。
  Map<String, dynamic>? _extractPreloadedState(String html) {
    const marker = "window.__PRELOADED_STATE__";
    final start = html.indexOf(marker);
    if (start < 0) {
      return null;
    }
    final braceStart = html.indexOf("{", start);
    if (braceStart < 0) {
      return null;
    }

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = braceStart; i < html.length; i += 1) {
      final char = html[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == "\\") {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == "{") {
        depth += 1;
      } else if (char == "}") {
        depth -= 1;
        if (depth == 0) {
          final jsonText = html.substring(braceStart, i + 1);
          try {
            final decoded = json.decode(jsonText);
            return decoded is Map<String, dynamic> ? decoded : null;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  String _resolveStreamName(Map<String, dynamic> model) {
    final streamName = model["streamName"]?.toString() ?? "";
    if (streamName.isNotEmpty) {
      return streamName;
    }
    final id = model["id"]?.toString() ?? "";
    if (id.isNotEmpty) {
      return id;
    }
    final hls = model["hlsPlaylist"]?.toString() ?? "";
    return _streamNameFromHls(hls);
  }

  String _resolveStreamNameFromState(dynamic viewCam, dynamic viewCamBase) {
    if (viewCam is Map) {
      final name = viewCam["streamName"]?.toString() ?? "";
      if (name.isNotEmpty) {
        return name;
      }
    }
    if (viewCamBase is Map) {
      final model = viewCamBase["model"];
      if (model is Map) {
        final name = model["streamName"]?.toString() ?? "";
        if (name.isNotEmpty) {
          return name;
        }
      }
    }
    return "";
  }

  /// 从 hlsPlaylist 中反推 streamName：
  /// .../hls/<streamName>/master/<streamName>_<preset>.m3u8
  String _streamNameFromHls(String hls) {
    if (hls.isEmpty) {
      return "";
    }
    final uri = Uri.tryParse(hls);
    if (uri == null) {
      return "";
    }
    final segments = uri.pathSegments;
    final hlsIndex = segments.indexOf("hls");
    if (hlsIndex >= 0 && hlsIndex + 1 < segments.length) {
      return segments[hlsIndex + 1];
    }
    return "";
  }

  /// presets 形如 ["480p", "240p", "160p_blurred"]。
  List<String> _parsePresets(dynamic value) {
    if (value is! List) {
      return const [];
    }
    return value
        .map((e) => e?.toString() ?? "")
        .where((e) => e.isNotEmpty)
        .toList();
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    final data = detail.data;
    if (data is! StripchatRoomData || data.streamName.isEmpty) {
      return const [];
    }

    // 请求 CDN master playlist，解析出带 pkey 的所有清晰度变体。
    // 直接拼接的 edge-hls 地址对匿名请求只会返回广告流。
    StripchatMouflon.ensureKeysRefreshed();
    // 切换房间/清晰度时清空历史分片缓存，避免混入上一个流的分片。
    StripchatMouflon.clearSegmentCache();
    final resolved = await _resolveMaster(data.streamName);
    if (resolved == null || resolved.variants.isEmpty) {
      return const [];
    }

    final qualities = <LivePlayQuality>[];
    // 超低时延：用最高画质的变体，但代理用小窗口（低缓冲）。
    final bestVariant = resolved.variants.first;
    qualities.add(
      LivePlayQuality(
        quality: "超低时延",
        data: StripchatQualityData(
          streamUrl: StripchatMouflon.appendPkey(
            bestVariant.url,
            resolved.pkey,
          ),
          lowLatency: true,
        ),
        sort: 1000,
      ),
    );
    // 普通清晰度：稳定大缓冲
    for (final variant in resolved.variants) {
      final label = variant.height > 0
          ? "${variant.name} ${variant.height}P"
          : variant.name;
      qualities.add(
        LivePlayQuality(
          quality: label,
          data: StripchatQualityData(
            streamUrl: StripchatMouflon.appendPkey(
              variant.url,
              resolved.pkey,
            ),
          ),
          sort: variant.height,
        ),
      );
    }
    return qualities;
  }

  /// 请求多个 CDN TLD 的 _auto.m3u8，解析出 pkey 与所有变体。
  Future<({String pkey, List<MasterVariant> variants})?> _resolveMaster(
    String modelId,
  ) async {
    const tlds = [
      "doppiocdn.com",
      "doppiocdn.org",
      "doppiocdn.net",
      "doppiocdn.live",
    ];
    for (final tld in tlds) {
      try {
        final masterUrl =
            "https://edge-hls.$tld/hls/$modelId/master/${modelId}_auto.m3u8";
        final text = await HttpClient.instance.getText(
          masterUrl,
          header: {
            "User-Agent": PlatformIdentity.stripchatUserAgent,
            "Referer": "$_baseUrl/",
          },
        );
        final parsed = StripchatMouflon.parseMasterVariants(text);
        if (parsed.variants.isEmpty) {
          continue;
        }
        return parsed;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final data = quality.data;
    if (data is! StripchatQualityData || data.streamUrl.isEmpty) {
      return LivePlayUrl(urls: []);
    }

    // 经过本地解密代理播放真实流。
    final proxied = await StripchatProxy.instance.proxyUrlFor(
      data.streamUrl,
      lowLatency: data.lowLatency,
    );
    return LivePlayUrl(urls: [proxied], headers: _headers);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    final model = await _findModelInList(roomId);
    if (model == null) {
      return false;
    }
    return model["isLive"] == true || model["isOnline"] == true;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
    LiveRoomDetail? detail,
  }) {
    // 该站不提供 SC 查询接口。
    return Future.value(<LiveSuperChatMessage>[]);
  }

  @override
  Future<List<LiveContributionRankItem>> getContributionRank({
    required String roomId,
    LiveRoomDetail? detail,
  }) {
    // 该站不提供贡献榜查询接口。
    return Future.value(<LiveContributionRankItem>[]);
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    final result = await _searchModels(keyword, page: page);
    return LiveSearchRoomResult(
      hasMore: result.hasMore,
      items: result.items.map(_parseRoomItem).whereType<LiveRoomItem>().toList(),
    );
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    final result = await _searchModels(keyword, page: page);
    final items = result.items
        .map(
          (item) => LiveAnchorItem(
            roomId: item["username"]?.toString() ?? "",
            avatar: item["avatarUrl"]?.toString() ?? "",
            userName: item["username"]?.toString() ?? "",
            liveStatus: item["isLive"] == true,
          ),
        )
        .where((item) => item.roomId.isNotEmpty)
        .toList();
    return LiveSearchAnchorResult(hasMore: result.hasMore, items: items);
  }

  Future<_SearchResult> _searchModels(String keyword, {int page = 1}) async {
    const pageSize = 20;
    const scanPages = 8;
    final key = keyword.trim().toLowerCase();
    if (key.isEmpty) {
      return _SearchResult(items: const [], hasMore: false);
    }

    var cache = _searchCache[key];
    if (cache == null ||
        DateTime.now().difference(cache.updatedAt) > const Duration(minutes: 5)) {
      final all = <Map<String, dynamic>>[];
      for (final tag in _primaryTags) {
        for (var p = 0; p < scanPages; p += 1) {
          final result = await _getJson(
            "/api/front/models",
            queryParameters: {
              "limit": 60,
              "offset": p * 60,
              "primaryTag": tag.id,
            },
          );
          if (result is! Map || result["models"] is! List) {
            break;
          }
          for (final item in result["models"]) {
            if (item is Map) {
              all.add(Map<String, dynamic>.from(item));
            }
          }
          final total = result["filteredCount"] ?? 0;
          final totalInt = total is int ? total : int.tryParse("$total") ?? 0;
          if ((p + 1) * 60 >= totalInt) {
            break;
          }
        }
      }
      final matched = all.where((item) {
        final username = item["username"]?.toString().toLowerCase() ?? "";
        final topic = item["topic"]?.toString().toLowerCase() ?? "";
        return username.contains(key) || topic.contains(key);
      }).toList();
      cache = _SearchCache(matched);
      _searchCache[key] = cache;
      if (_searchCache.length > 20) {
        _searchCache.remove(_searchCache.keys.first);
      }
    }

    final items = cache.items;
    final start = (page - 1) * pageSize;
    if (start >= items.length) {
      return _SearchResult(items: const [], hasMore: false);
    }
    final end = (start + pageSize) < items.length ? start + pageSize : items.length;
    return _SearchResult(
      items: items.sublist(start, end),
      hasMore: end < items.length,
    );
  }
}

class _SearchCache {
  final List<Map<String, dynamic>> items;
  final DateTime updatedAt = DateTime.now();

  _SearchCache(this.items);
}

class _SearchResult {
  final List<Map<String, dynamic>> items;
  final bool hasMore;

  _SearchResult({required this.items, required this.hasMore});
}

/// 房间弹幕/播放所需的附加数据。
class StripchatRoomData {
  final String streamName;
  final List<String> presets;
  final String? hlsPlaylist;

  StripchatRoomData({
    required this.streamName,
    this.presets = const [],
    this.hlsPlaylist,
  });

  @override
  String toString() {
    return json.encode({
      "streamName": streamName,
      "presets": presets,
      "hlsPlaylist": hlsPlaylist,
    });
  }
}

/// 单个清晰度的播放参数。
class StripchatQualityData {
  /// 带 pkey 的真实变体 m3u8 地址（交给本地解密代理）。
  final String streamUrl;

  /// 超低时延模式：小缓冲、低延迟，网络波动时可能卡顿。
  final bool lowLatency;

  StripchatQualityData({required this.streamUrl, this.lowLatency = false});

  @override
  String toString() {
    return json.encode({
      "streamUrl": streamUrl,
      "lowLatency": lowLatency,
    });
  }
}
