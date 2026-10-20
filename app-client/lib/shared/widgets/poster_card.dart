import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 海报卡外壳：白底、描边、圆角、hover 抬起 + 阴影加深。
///
/// 作品库和我的收藏共用这一层，否则两个页面的卡片会有细微差异
/// （圆角、阴影、hover 位移），看着像两个人做的。
/// 内部只放“封面 + 正文”，角标与悬浮按钮由调用方通过 [overlay] 叠上去。
class PosterCardShell extends StatefulWidget {
  const PosterCardShell({
    super.key,
    required this.onTap,
    required this.child,
    this.overlay,
  });

  final VoidCallback onTap;
  final Widget child;

  /// 叠在封面右上角的操作（如取消收藏），不参与卡片整体的 hover 变换。
  final Widget? overlay;

  @override
  State<PosterCardShell> createState() => _PosterCardShellState();
}

class _PosterCardShellState extends State<PosterCardShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppTheme.cardRadius);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            // 站点是 translateY(-4px) + 描边变浅 + 阴影加深。
            transform: Matrix4.translationValues(0, _hovered ? -4 : 0, 0),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppTheme.cardColor(context),
              borderRadius: radius,
              border: Border.all(
                color: _hovered
                    ? AppTheme.brandLine
                    : AppTheme.borderColor(context),
              ),
              boxShadow: _hovered
                  ? const [
                      BoxShadow(
                        color: Color(0x2E143652),
                        blurRadius: 38,
                        spreadRadius: -10,
                        offset: Offset(0, 16),
                      ),
                      BoxShadow(
                        color: Color(0x14143652),
                        blurRadius: 12,
                        spreadRadius: -4,
                        offset: Offset(0, 4),
                      ),
                    ]
                  : const [
                      BoxShadow(
                        color: Color(0x0D143652),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: widget.onTap, child: widget.child),
            ),
          ),
          if (widget.overlay != null)
            Positioned(top: 6, right: 6, child: widget.overlay!),
        ],
      ),
    );
  }
}
