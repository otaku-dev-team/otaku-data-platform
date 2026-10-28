import 'app_theme.dart';

/// 布局尺寸。桌面端与手机端共用一套数值，避免各页面自己写 padding。
abstract final class AppLayout {
  const AppLayout._();

  /// 列表在宽屏上不拉满，避免一行 40 个字的标题。
  static const double listMaxWidth = 880;

  /// 详情正文的阅读宽度。
  static const double detailMaxWidth = 960;

  /// 达到这个宽度后详情改成左右两栏。
  ///
  /// 定 720 而不是 900：Windows 上 1280 物理像素的窗口在 150% 缩放后逻辑宽度
  /// 只有 853，用 900 会让桌面端永远落到手机版堆叠布局，封面占掉半屏。
  static const double twoColumnBreakpoint = 720;

  static const double pagePadding = 16;

  /// 卡片圆角。**唯一来源是 [AppTheme.cardRadius]**，这里只是布局层的别名——
  /// 此前两处各写一个值（16 / 12），网格卡与横向卡的圆角对不上。
  static const double cardRadius = AppTheme.cardRadius;

  /// 卡片内部缩略图 / 封面的圆角。比卡片小一档，内外两层才不会贴在一起。
  static const double innerRadius = 12;

  /// 达到这个宽度后，桌面端在左侧常驻 [NavigationRail]。
  ///
  /// 定 600 而不是 900：与 Flutter 自己的 `medium` 断点一致。900 是「双栏详情」
  /// 那个手感断点的旧值，用在导航上会让 720–900 的窗口既没有侧栏、又有双栏，
  /// 布局逻辑互相打架。两个断点各管一件事：600 管「要不要侧栏」，
  /// 720 管「详情要不要分栏」。
  static const double railBreakpoint = 600;

  /// 侧栏收起文字后的宽度（Flutter 的默认 rail 宽度，显式写出来给测试用）。
  static const double railWidth = 80;

  /// 桌面窗口的最小尺寸（flutter-lead-plan §6）。
  static const double minWindowWidth = 900;
  static const double minWindowHeight = 600;

  /// 封面比例 2:3，与来源站 `.work-cover-box { aspect-ratio: 2/3 }` 一致。
  static const double posterAspect = 2 / 3;

  /// 海报网格的最小列宽：桌面 190、手机 150（对齐站点 `.works-grid` 的断点）。
  static const double gridMinCardWidth = 190;
  static const double gridMinCardWidthCompact = 150;

  /// 卡片正文固定高度：标题最多两行 + 元信息一行 + 标签一行。
  /// 网格用固定 `mainAxisExtent`，这里必须给死，否则长短标题会让行高不齐。
  static const double cardBodyHeight = 112;

  /// 收藏卡正文高度：比作品库卡片多一行「观看状态 + 更新时间」。
  ///
  /// 单独给一个值而不是把 [cardBodyHeight] 调大：作品库卡片的内容刚好装满
  /// 112，跟着变高只会在标签行下面多出一条空白。
  ///
  /// 124 是量出来的，不是估的——Android（1080×2340，网格两列）上收藏卡底部
  /// 报 `BOTTOM OVERFLOWED BY 7.0 PIXELS`，原来 112 正好差这 7px。
  /// 详情见 `docs/stage2-acceptance.md` 的「验收发现的问题」。
  static const double collectionCardBodyHeight = 124;

  static const double gridGap = 12;

  static const double coverWidth = 64;
  static const double coverHeight = 88;

  /// 按可用宽度算列数与单卡宽度。
  ///
  /// 骨架屏与真实列表共用这一处，否则首屏骨架的格子数和加载完后对不上，
  /// 会看到一次明显的跳动。
  static ({int columns, double cardWidth}) gridMetrics(
    double availableWidth, {
    double gap = gridGap,
  }) {
    final minWidth = availableWidth < 600
        ? gridMinCardWidthCompact
        : gridMinCardWidth;
    var columns = (availableWidth / minWidth).floor();
    if (columns < 2) columns = 2;
    // 上限 4 列（flutter-lead-plan §6「自适应网格 2–4 列」）。
    // 不限的话 1920 宽的窗口会算出 8 列、单卡不到 200 宽，标题全被截断。
    if (columns > 4) columns = 4;
    final cardWidth = (availableWidth - gap * (columns - 1)) / columns;
    return (columns: columns, cardWidth: cardWidth);
  }

  static const double detailCoverWidth = 220;
  static const double detailCoverHeight = 300;
}
