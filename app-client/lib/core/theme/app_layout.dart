/// 布局尺寸。桌面端与手机端共用一套数值，避免各页面自己写 padding。
abstract final class AppLayout {
  const AppLayout._();

  /// 列表在宽屏上不拉满，避免一行 40 个字的标题。
  static const double listMaxWidth = 880;

  /// 详情正文的阅读宽度。
  static const double detailMaxWidth = 960;

  /// 达到这个宽度后详情改成左右两栏。
  static const double twoColumnBreakpoint = 900;

  static const double pagePadding = 16;
  static const double cardRadius = 12;
  static const double coverWidth = 64;
  static const double coverHeight = 88;
  static const double detailCoverWidth = 220;
  static const double detailCoverHeight = 300;
}
