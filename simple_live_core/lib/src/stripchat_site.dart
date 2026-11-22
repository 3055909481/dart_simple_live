import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/platform_identity.dart';

/// Stripchat 站点实现。
///
/// 数据接口为站点公开的 `api/front` 前端接口：
/// - 列表/分类：`GET /api/front/models?primaryTag=<tag>&limit=&offset=`
/// - 详情：模型主页 `https://stripchat.com/<username>` 内嵌的
///   `window.__PRELOADED_STATE__`（该站未开放单模型 JSON 接口）
/// - 播放：`hlsPlaylist` 字段给出的 doppiocdn HLS 直链
///
/// 该站接口对请求头较敏感，统一带浏览器 UA + Referer + Accept。
class StripchatSite implements LiveSite {
  static const String _baseUrl = "https://stripchat.com";
  static const String _hlsBase =
      "https://edge-hls.doppiocdn.media/hls";
  static const String _hlsPostfix = "master";

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
    // 先从列表数据里找，命中则无需解析整个页面。
    final cached = await _findModelInList(roomId);
    if (cached != null) {
      return _detailFromModel(cached);
    }

    // 兜底：解析模型主页内嵌的 SSR 状态。
    final html = await _getText("/$roomId");
    final state = _extractPreloadedState(html);
    if (state == null) {
      throw CoreError("Stripchat 房间数据解析失败，请稍后重试");
    }
    return _detailFromPageState(state, roomId);
  }

  /// 在若干页列表数据中查找指定 username，并缓存结果供详情/状态复用。
  Future<Map<String, dynamic>?> _findModelInList(String username) async {
    const pageSize = 100;
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
    if (data is! StripchatRoomData) {
      return const [];
    }
    final qualities = <LivePlayQuality>[
      LivePlayQuality(
        quality: "默认",
        data: StripchatQualityData(
          streamName: data.streamName,
          preset: null,
          fallbackUrl: data.hlsPlaylist,
        ),
        sort: 100,
      ),
    ];
    for (final preset in data.presets) {
      qualities.add(
        LivePlayQuality(
          quality: _presetDisplayName(preset),
          data: StripchatQualityData(
            streamName: data.streamName,
            preset: preset,
            fallbackUrl: data.hlsPlaylist,
          ),
          sort: _presetSort(preset),
        ),
      );
    }
    return qualities;
  }

  String _presetDisplayName(String preset) {
    switch (preset.toLowerCase()) {
      case "480p":
        return "超清 480P";
      case "240p":
        return "高清 240P";
      case "160p_blurred":
        return "流畅 160P";
      default:
        final match = RegExp(r'^(\d+)p').firstMatch(preset.toLowerCase());
        return match != null ? "${match.group(1)}P" : preset;
    }
  }

  int _presetSort(String preset) {
    final match = RegExp(r'(\d+)').firstMatch(preset);
    if (match == null) {
      return 0;
    }
    return int.tryParse(match.group(1) ?? "") ?? 0;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final data = quality.data;
    if (data is! StripchatQualityData) {
      return LivePlayUrl(urls: []);
    }

    final urls = <String>[];
    final built = buildHlsUrl(data.streamName, data.preset);
    if (built.isNotEmpty) {
      urls.add(built);
    }
    // 构造失败时回退到接口给出的原始 hlsPlaylist。
    final fallback = data.fallbackUrl ?? "";
    if (fallback.isNotEmpty && !urls.contains(fallback)) {
      urls.add(fallback);
    }
    return LivePlayUrl(urls: urls, headers: _headers);
  }

  /// 构造 HLS 直链。
  ///
  /// - 有 preset：`.../hls/<stream>/master/<stream>_<preset>.m3u8`
  /// - 无 preset：`.../hls/<stream>/master/<stream>.m3u8`
  String buildHlsUrl(String streamName, String? preset) {
    if (streamName.isEmpty) {
      return "";
    }
    final tail = preset == null || preset.isEmpty
        ? streamName
        : "${streamName}_$preset";
    return "$_hlsBase/$streamName/$_hlsPostfix/$tail.m3u8";
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
              "limit": 100,
              "offset": p * 100,
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
          if ((p + 1) * 100 >= totalInt) {
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
  final String streamName;
  final String? preset;
  final String? fallbackUrl;

  StripchatQualityData({
    required this.streamName,
    this.preset,
    this.fallbackUrl,
  });

  @override
  String toString() {
    return json.encode({
      "streamName": streamName,
      "preset": preset,
      "fallbackUrl": fallbackUrl,
    });
  }
}
