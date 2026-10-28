import 'dart:io';

/// 平台判断集中在这里。
///
/// 页面和 widget 不直接 import `dart:io`：一是让「哪些地方依赖平台」一目了然，
/// 二是将来真要出 Web 版时只需要改这一个文件。当前计划 §3.2 明确不做 Flutter Web。
abstract final class PlatformInfo {
  /// 桌面端（Windows / Linux / macOS）。
  ///
  /// 注意这与「窗口宽度够宽」是两件事：手机横屏也能超过 600 逻辑像素，
  /// 但 §6 的两端差异是平台差异，不能只按宽度判断。
  static bool get isDesktop =>
      desktopOverride ??
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// 覆盖「是不是桌面端」，仅供测试用。
  ///
  /// **为什么需要它**：单测跑在 Windows 上，`Platform.isWindows` 恒为 true，
  /// 于是「手机形态出底栏、桌面形态出侧栏」这类断言在测试里只能验到桌面那一半。
  /// 而 Android 与桌面的两端差异正是本项目要守的东西
  /// （`docs/flutter-lead-plan.md` §6「两端差异清单」），不能因为测试跑在桌面上
  /// 就验不到手机那一半。
  ///
  /// 留空（null）就是真实平台。生产代码不设它。
  static bool? desktopOverride;

  /// 恢复成真实平台。测试的 `tearDown` 里调它，漏掉时会污染后续用例。
  static void resetOverride() => desktopOverride = null;
}
