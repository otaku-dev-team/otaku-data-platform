import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform_info.dart';

/// 桌面端键盘快捷键（flutter-lead-plan §6「刷新 / 返回」两行）。
///
/// - `Ctrl+R` 刷新，对应手机端的下拉刷新；
/// - `Esc` 返回上一页，对应手机端的系统返回手势；
/// - `/` 聚焦搜索框（只有传了 [onSearch] 的页面才有，目前是作品库）。
///
/// 用 [CallbackShortcuts] 而不是全局 `HardwareKeyboard` 监听：
/// 前者只在自身焦点子树内有焦点时触发，不会在对话框里误伤；
/// 后者是全局的，任何一个 TextField 里按 Ctrl+R 都会被页面抢走。
///
/// `/` 不会抢走输入框里的斜杠：`EditableText` 先消费字符键并标记已处理，
/// 祖先的 [CallbackShortcuts] 收不到——所以「聚焦后继续打 `/`」是安全的。
///
/// 手机端直接返回 [child]——没有物理键盘，装了只是白占一层 widget。
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({
    super.key,
    this.onRefresh,
    this.onSearch,
    this.onEscape,
    required this.child,
  });

  /// 为 null 表示这一页没有「刷新」语义（例如详情页），此时 Ctrl+R 不响应。
  final VoidCallback? onRefresh;

  /// 为 null 表示这一页没有搜索框，此时 `/` 不响应。
  final VoidCallback? onSearch;

  /// 页面先处理 Esc（返回 true 表示已消费，不再走默认的「返回上一页」）。
  ///
  /// 用途：搜索框有焦点时，Esc 应该是「退出输入」而不是「退出页面」。
  /// 这类二义性交给页面判断——只有页面知道此刻有没有「更近的一层」可以退。
  final bool Function()? onEscape;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isDesktop) return child;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () {
          onRefresh?.call();
        },
        const SingleActivator(LogicalKeyboardKey.slash): () {
          onSearch?.call();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (onEscape?.call() ?? false) return;
          _popIfPossible(context);
        },
      },
      // FocusScope 而不是 Focus：scope 只把焦点留在本页，不抢子控件的焦点。
      child: FocusScope(autofocus: true, child: child),
    );
  }

  static void _popIfPossible(BuildContext context) {
    final navigator = Navigator.maybeOf(context);
    if (navigator == null || !navigator.canPop()) return;
    navigator.pop();
  }
}
