/// 路由路径集中在这里，页面之间跳转不要硬编码字符串。
abstract final class RoutePaths {
  const RoutePaths._();

  static const String contents = '/works';

  /// 相对 `contents` 的子路由。
  static const String workDetailSegment = ':workId';

  static String workDetail(String workId) =>
      '$contents/${Uri.encodeComponent(workId)}';
}
