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
  static const double cardRadius = 12;

  /// 封面比例 2:3，与来源站 `.work-cover-box { aspect-ratio: 2/3 }` 一致。
  static const double posterAspect = 2 / 3;

  /// 海报网格的最小列宽：桌面 190、手机 150（对齐站点 `.works-grid` 的断点）。
  static const double gridMinCardWidth = 190;
  static const double gridMinCardWidthCompact = 150;

  /// 卡片正文固定高度：标题最多两行 + 元信息一行 + 标签一行。
  /// 网格用固定 `mainAxisExtent`，这里必须给死，否则长短标题会让行高不齐。
  static const double cardBodyHeight = 112;

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
    final cardWidth = (availableWidth - gap * (columns - 1)) / columns;
    return (columns: columns, cardWidth: cardWidth);
  }
  static const double detailCoverWidth = 220;
  static const double detailCoverHeight = 300;
}
