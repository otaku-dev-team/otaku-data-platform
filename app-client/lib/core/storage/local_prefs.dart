import 'dart:convert';

/// 本机偏好与轻量本地状态。
///
/// 与 `WorkCache` / `RecentViewsStore` / `CollectionCache` 分开，是因为
/// 它们回答的是不同的问题：
/// - 那三者是**服务端数据的副本**（缓存、收藏）或**使用痕迹**（浏览历史），
///   有「同步时间」或「账号」的语义；
/// - 这里是**设备级的设置**：主题选的是浅色还是深色、搜索框里上次输的是什么。
///   没有同步时间可言，也不需要复用服务端那条链路。
///
/// 值统一是字符串，编解码归上层——一个键值袋能覆盖「主题」「搜索历史」
/// 这类杂项，不必每加一个小状态就开一个新盒子。
///
/// **读写都是同步的**（`read` 不是 `Future`）：`MaterialApp` 的第一帧就要
/// 知道用哪套主题，异步读会让应用先闪一帧系统主题再切过去。盒子在
/// `main()` 里预先打开（见 `LocalPrefsHolder`），正是为了让这条路径同步。
abstract interface class LocalPrefs {
  /// 读一个键。没有、读盘失败、类型不对都返回 `null`——
  /// 「没设过」和「读不出来」对调用方是同一个意思：用默认值。
  String? read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);
}

/// 字符串列表的 JSON 编解码。搜索历史用它。
///
/// 抽出来而不是塞进控制器：格式变化（比如以后想存「查询 + 时间」）
/// 只改这里，而「坏数据怎么处理」是可以单测的纯函数。
abstract final class StringListCodec {
  const StringListCodec._();

  static String encode(List<String> values) => jsonEncode(values);

  /// 解析。**整个字符串坏掉**（不是 JSON、不是数组）→ 空列表；
  /// **单条不是字符串** → 跳过它，剩下的照常返回。
  ///
  /// 这个区别与 `RecentViewsCodec` 一致：整段作废会让用户以为历史被清空了，
  /// 而实际只是某一条写坏了。
  static List<String> decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <String>[];
    }
    if (decoded is! List) return const <String>[];

    final values = <String>[];
    for (final entry in decoded) {
      if (entry is! String) continue;
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      values.add(trimmed);
    }
    return List<String>.unmodifiable(values);
  }
}
