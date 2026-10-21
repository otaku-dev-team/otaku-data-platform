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
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}
