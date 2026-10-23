/// 路由路径集中在这里，页面之间跳转不要硬编码字符串。
abstract final class RoutePaths {
  const RoutePaths._();

  static const String contents = '/works';

  /// 登录页。从收藏页跳来时用 push，登录成功后 pop 回去。
  static const String login = '/login';

  /// 我的收藏。未登录时页面自己显示登录引导，不在这里做重定向——
  /// 冷启动直接落到收藏页时，用户需要知道「为什么看不到东西」。
  static const String collections = '/collections';

  /// 每日新番档期。与列表/收藏平级：从任何地方都能直接进。
  static const String schedule = '/schedule';

  /// 相对 `contents` 的子路由。
  static const String workDetailSegment = ':workId';

  static String workDetail(String workId) =>
      '$contents/${Uri.encodeComponent(workId)}';
}
