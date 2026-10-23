import 'dart:convert';

import '../../data/models/recent_view.dart';

/// 「最近浏览」的本地存储。
///
/// 与 [WorkCache] / [CollectionCache] 分开是三类不同的东西：
/// - 作品缓存是服务端数据的副本，删了还能再拉；
/// - 收藏缓存也是副本，只是按账号分键；
/// - 浏览历史**只存在于本机**，删了就真没了——所以退出登录时不清它
///   （清理逻辑见各实现，收藏缓存在退出登录时会清）。
///
/// 但仍然按账号分桶：历史会暴露「这台机器上看过什么」，换个人登录不该
/// 看见上一个人的口味。未登录时写进 `guest` 桶。
///
/// 读写都是**同步**的：Hive 的 `Box.get/put` 在盒已打开时本身是同步的，
/// 接口若写成 `Future`，首页就得先闪一帧空白再显示内容。盒子在 `main()`
/// 里预先打开（见 `RecentViewsHolder`），正是为了让这条路径同步。
abstract interface class RecentViewsStore {
  /// 读某个账号的历史。
  ///
  /// 没有记录、读盘失败、数据损坏都返回空列表：「没看过」和「读不出来」
  /// 对界面是同一个意思——都不渲染这一块。
  List<RecentView> read(String ownerKey);

  /// 整体覆盖写入。历史上限只有几十条，不做增量。
  Future<void> write(String ownerKey, List<RecentView> items);

  /// 清空某个账号的历史。
  Future<void> clear(String ownerKey);
}

/// 历史记录的 JSON 编解码。
///
/// 单独抽出来是为了能单测：Hive 实现要平台通道，测试里跑不起来，
/// 而「坏数据怎么处理」恰恰是这段代码最容易出错的地方。
abstract final class RecentViewsCodec {
  const RecentViewsCodec._();

  static String encode(List<RecentView> items) =>
      jsonEncode([for (final item in items) item.toJson()]);

  /// 解析。**整个字符串坏掉**（不是 JSON）→ 空列表；
  /// **单条坏掉** → 跳过它，剩下的照常返回。
  ///
  /// 这个区别很重要：模型加字段后旧格式可能与新解析器不兼容，若整段作废，
  /// 用户会以为自己的浏览记录被清空了。
  static List<RecentView> decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <RecentView>[];
    }
    if (decoded is! List) return const <RecentView>[];

    final items = <RecentView>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        items.add(RecentView.fromJson(Map<String, dynamic>.from(entry)));
      } on FormatException {
        continue;
      }
    }
    return List<RecentView>.unmodifiable(items);
  }
}
