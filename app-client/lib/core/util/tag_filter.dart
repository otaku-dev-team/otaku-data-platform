/// 标签筛选的归一化。
///
/// 契约 `tags=a,b` 是**集合语义**（AND，最多 10 个），所以：
/// - 首尾空白去掉，空串丢弃（`tags=科幻,,机战` 里的空项没有意义）；
/// - 去重（同一个标签选两次不该变成两个条件）；
/// - 最多 10 个，超出直接截断——服务端对 11 个会返回 400，
///   与其让用户点了第 11 个才报错，不如界面上就选不动（见 `MAX_FILTER_TAGS`）。
///
/// 归一化只有这一份：请求参数、缓存键、界面 chip 都调它，
/// 否则「界面上显示 3 个、请求只发了 2 个」这类错会很难查。
const int maxFilterTags = 10;

List<String> normalizeTags(Iterable<String>? tags) {
  if (tags == null) return const [];
  final seen = <String>{};
  final result = <String>[];
  for (final raw in tags) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    if (!seen.add(name)) continue;
    result.add(name);
    if (result.length >= maxFilterTags) break;
  }
  return List.unmodifiable(result);
}

/// 缓存键用的稳定表示：与选择顺序无关。
///
/// 先点「科幻」再点「机战」和反过来是同一个查询，必须命中同一条缓存；
/// 用选择顺序拼键会让这两次各存一份。
String tagsCacheKey(Iterable<String>? tags) {
  final normalized = normalizeTags(tags).toList()..sort();
  return normalized.join('\u0001');
}
