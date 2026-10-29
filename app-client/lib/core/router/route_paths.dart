/// 路由路径集中在这里，页面之间跳转不要硬编码字符串。
abstract final class RoutePaths {
  const RoutePaths._();

  static const String contents = '/works';

  /// 首页。落地页，把分类浏览 / 本日新番 / 高分作品 / 最新资讯四块聚在一起。
  ///
  /// 路径就用 `/`：它是信息架构的根，也是深链接最自然的入口。
  static const String home = '/';

  /// 最新资讯列表。与 `contents` 平级，不是它的子路由——
  /// 资讯和作品的筛选、分页各管一套，套在一起只会互相干扰。
  static const String articles = '/articles';

  /// 相对 `articles` 的子路由，与 `workDetailSegment` 同构。
  static const String articleDetailSegment = ':articleId';

  static String articleDetail(String articleId) =>
      '$articles/${Uri.encodeComponent(articleId)}';

  /// 登录页。从收藏页跳来时用 push，登录成功后 pop 回去。
  static const String login = '/login';

  /// App 内 WebView 承载站点登录 / 注册页（W1 账号绑定，Issue #238）。
  ///
  /// 不作为可深链的公开路由：它由 `WebViewSiteAuthLauncher` 用 push 打开，
  /// 并带上 `SiteAuthWebViewArgs`；直接访问会因为缺 extra 而显示错误态。
  static const String siteAuth = '/auth/site';

  /// 我的收藏。未登录时页面自己显示登录引导，不在这里做重定向——
  /// 冷启动直接落到收藏页时，用户需要知道「为什么看不到东西」。
  static const String collections = '/collections';

  /// 每日新番档期。与列表/收藏平级：从任何地方都能直接进。
  static const String schedule = '/schedule';

  /// 设置：主页面只放分组入口，内容在二级页。
  ///
  /// 平级而不是挂在某个页面下面：主题与缓存是设备级的，与「当前在看什么」无关。
  static const String settings = '/settings';

  /// 设置二级页（相对 [settings]）。
  ///
  /// 设置项会越加越多（主题、缓存、更新、来源声明，以后还有通知、数据导出），
  /// 全铺在一屏会变成一条长走廊。拆成二级后主页面永远是三五行，
  /// 加东西只影响它自己那一页。
  static const String appearanceSettingsSegment = 'appearance';
  static const String storageSettingsSegment = 'storage';
  static const String aboutSettingsSegment = 'about';

  static const String appearanceSettings = '$settings/$appearanceSettingsSegment';
  static const String storageSettings = '$settings/$storageSettingsSegment';
  static const String aboutSettings = '$settings/$aboutSettingsSegment';

  /// 相对 `contents` 的子路由。
  static const String workDetailSegment = ':workId';

  static String workDetail(String workId) =>
      '$contents/${Uri.encodeComponent(workId)}';
}
