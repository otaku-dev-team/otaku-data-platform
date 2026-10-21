import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform_info.dart';

/// 桌面端键盘快捷键（flutter-lead-plan §6「刷新 / 返回」两行）。
///
/// - `Ctrl+R` 刷新，对应手机端的下拉刷新；
/// - `Esc` 返回上一页，对应手机端的系统返回手势。
///
/// 用 [CallbackShortcuts] 而不是全局 `HardwareKeyboard` 监听：
/// 前者只在自身焦点子树内有焦点时触发，不会在对话框里误伤；
/// 后者是全局的，任何一个 TextField 里按 Ctrl+R 都会被页面抢走。
///
/// 手机端直接返回 [child]——没有物理键盘，装了只是白占一层 widget。
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({super.key, this.onRefresh, required this.child});

  /// 为 null 表示这一页没有「刷新」语义（例如详情页），此时 Ctrl+R 不响应。
  final VoidCallback? onRefresh;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isDesktop) return child;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () {
          onRefresh?.call();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
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
