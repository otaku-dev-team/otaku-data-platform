/// 路由路径集中在这里，页面之间跳转不要硬编码字符串。
abstract final class RoutePaths {
  const RoutePaths._();

  static const String contents = '/works';

  /// 首页搜索直接进入输入状态；作品库消费参数后恢复普通浏览路径。
  static const String contentsSearch = '$contents?search=1';

  /// 首页。落地页，把高分精选 / 本日新番 / 高分作品 / 最新资讯几块聚在一起。
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

  /// 人物详情（#455）。`person_id` 是**不透明字符串**——现在库里是裸数字，
  /// 切 v3 数据集后带 `bgm:` / `pname:` / `cname:` 前缀，整值编码后放进路径。
  static const String persons = '/persons';
  static const String personSegment = ':personId';

  static String person(String personId) =>
      '$persons/${Uri.encodeComponent(personId)}';

  /// 制作公司页（#557）。公司名**就是主键**，没有 id：`work_studios` 只有名字。
  /// 整值编码后放路径段，大小写敏感——后端按二进制排序规则精确匹配。
  static const String studios = '/studios';
  static const String studioSegment = ':name';

  static String studio(String name) =>
      '$studios/${Uri.encodeComponent(name)}';

  /// 系列页（#557）。`key` 是来源站内部 id：**不透明字符串**，整值编码后当路径段，
  /// 不解析、不截断、不拿它当标题（没名字时页面退化成「系列」二字）。
  static const String series = '/series';
  static const String seriesSegment = ':key';

  static String seriesPage(String key) =>
      '$series/${Uri.encodeComponent(key)}';

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

  /// 个人空间：账号资料、收藏与浏览记录的汇总入口（二级页）。
  ///
  /// 以前这些收在「我的」底部弹层里。弹层只能竖着堆列表，放不下头像、
  /// 统计带与分区，所以改成独立页面，版式与站点 `/me` 对齐。
  /// 路径用 `/me`：与站点同一个语义，深链接进来也知道这是哪儿。
  static const String profile = '/me';

  /// 阿宅画像（#375）。挂在 `/me` 下而不是顶层：它是「我的数据」的一种视图，
  /// 从个人空间点进来、返回也回个人空间，和设置二级页同一种形态。
  static const String personaSegment = 'persona';
  static const String persona = '$profile/persona';

  /// 冷启动补标（#505）：画像页的下一级。选完直接回画像页。
  static const String personaQuizSegment = 'quiz';
  static const String personaQuiz = '$persona/quiz';

  /// 全库搜索补标：预设题面之外，自己搜作品标记。
  static const String personaQuizSearchSegment = 'search';
  static const String personaQuizSearch = '$personaQuiz/search';

  /// 登录设备（#378）。与画像同一种形态：挂在 `/me` 下的二级页，
  /// 从个人空间点进来、返回也回个人空间。
  static const String devicesSegment = 'devices';
  static const String devices = '$profile/devices';

  /// 编辑资料（#378 第一层）：与画像、登录设备同形态的 `/me` 二级页。
  static const String profileEditSegment = 'edit';
  static const String profileEdit = '$profile/edit';

  /// 我的评论（#449 客户端，与画像 / 登录设备同形态）。
  ///
  /// **路由注册但没有任何入口 push 它**：本轮按「有这个功能但不用」的口径，
  /// 个人空间里的 tile 标「未开放」且不可点。启用时只需给那个 tile 补 `onTap`。
  static const String myCommentSegment = 'comments';
  static const String myComment = '$profile/$myCommentSegment';

  /// 每日新番档期。与列表/收藏平级：从任何地方都能直接进。
  static const String schedule = '/schedule';

  /// 设置：主页面只放分组入口，内容在二级页。
  ///
  /// 平级而不是挂在某个页面下面：主题与缓存是设备级的，与「当前在看什么」无关。
  static const String settings = '/settings';

  /// 最近浏览的完整列表（二级页）。
  ///
  /// 首页那条横排只放得下「最近这几部」，想回头找更早看过的就得有地方去。
  /// 挂在顶层而不是某个 branch 下面：它与「当前在哪个 tab」无关，
  /// 从首页进、返回也回首页，和设置页同一种形态（覆盖全屏、没有底部导航）。
  static const String recentHistory = '/recent';

  /// 设置二级页（相对 [settings]）。
  ///
  /// 设置项会越加越多（主题、缓存、更新、来源声明，以后还有通知、数据导出），
  /// 全铺在一屏会变成一条长走廊。拆成二级后主页面永远是三五行，
  /// 加东西只影响它自己那一页。
  static const String appearanceSettingsSegment = 'appearance';
  static const String storageSettingsSegment = 'storage';
  static const String aboutSettingsSegment = 'about';

  static const String appearanceSettings =
      '$settings/$appearanceSettingsSegment';
  static const String storageSettings = '$settings/$storageSettingsSegment';
  static const String aboutSettings = '$settings/$aboutSettingsSegment';

  /// 相对 `contents` 的子路由。
  static const String workDetailSegment = ':workId';

  /// 作品详情。
  ///
  /// [heroTag] 只在列表里点进来时给：详情页用它把封面接成一次 [Hero] 转场。
  /// 标签必须**屏内唯一**，所以由列表按「轨道 + 下标」拼，见 `HeroCover`。
  static String workDetail(String workId, {String? heroTag}) {
    final path = '$contents/${Uri.encodeComponent(workId)}';
    if (heroTag == null || heroTag.isEmpty) return path;
    return '$path?hero=${Uri.encodeQueryComponent(heroTag)}';
  }
}
