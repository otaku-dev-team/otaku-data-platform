import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import 'persona_view_data.dart';

/// 九维雷达图。
///
/// 纯绘制、无第三方图表库：这里画的是**已经归一化好的展示比例**，
/// 不做任何打分或聚合（§6：客户端只渲染）。
/// 轴数由 [PersonaDimension] 的数量决定，>=3 才画——二维雷达没有形状，
/// 直接返回空盒子比画一条线更诚实。
///
/// 九轴比六轴密：标签按象限选对齐方式（右上往右、左上往左），
/// 中间那根（正上方 / 正下方）居中，窄屏上也不会互相压住。
class PersonaRadarChart extends StatelessWidget {
  const PersonaRadarChart({super.key, required this.dimensions});

  final List<PersonaDimension> dimensions;

  @override
  Widget build(BuildContext context) {
    if (dimensions.length < 3) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 半径要留出标签的宽度：窄屏上按宽度收，宽屏上封顶 320，
        // 否则 880 的列表宽度会把六边形拉成一张饼。
        final side = math.min(constraints.maxWidth, 320.0);
        return SizedBox(
          width: constraints.maxWidth,
          height: side + Space.s6,
          child: CustomPaint(
            painter: _RadarPainter(
              dimensions: dimensions,
              primary: scheme.primary,
              outline: scheme.outlineVariant,
              labelStyle: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ) ??
                  TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
          ),
        );
      },
    );
  }
}

class _RadarPainter extends CustomPainter {
  const _RadarPainter({
    required this.dimensions,
    required this.primary,
    required this.outline,
    required this.labelStyle,
  });

  final List<PersonaDimension> dimensions;
  final Color primary;
  final Color outline;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 40 是留给轴标签的边距；标题最长四个字，够放。
    final radius = math.min(size.width, size.height) / 2 - 40;
    if (radius <= 0) return;

    final count = dimensions.length;
    double angleAt(int index) => -math.pi / 2 + index * 2 * math.pi / count;
    Offset pointAt(int index, double ratio) => center +
        Offset(
          math.cos(angleAt(index)) * radius * ratio,
          math.sin(angleAt(index)) * radius * ratio,
        );

    final grid = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // 四圈网格 + 轴线。先画网格再画数据，数据多边形才不会被线压住。
    for (final level in const <double>[0.25, 0.5, 0.75, 1.0]) {
      final path = Path();
      for (var i = 0; i < count; i++) {
        final p = pointAt(i, level);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, grid);
    }
    for (var i = 0; i < count; i++) {
      canvas.drawLine(center, pointAt(i, 1), grid);
    }

    final shape = Path();
    final vertices = <Offset>[];
    for (var i = 0; i < count; i++) {
      // clamp 兜底：即使上游给了越界值也只是画到边上，不会画到框外。
      final p = pointAt(i, dimensions[i].value.clamp(0.0, 1.0));
      vertices.add(p);
      if (i == 0) {
        shape.moveTo(p.dx, p.dy);
      } else {
        shape.lineTo(p.dx, p.dy);
      }
    }
    shape.close();

    canvas.drawPath(
      shape,
      Paint()
        ..color = primary.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      shape,
      Paint()
        ..color = primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final p in vertices) {
      canvas.drawCircle(p, 3, Paint()..color = primary);
    }

    // 轴标签：按所在象限选对齐方式，避免右侧标签被画布裁掉。
    for (var i = 0; i < count; i++) {
      final angle = angleAt(i);
      final anchor = pointAt(i, 1.16);
      final painter = TextPainter(
        text: TextSpan(text: dimensions[i].label, style: labelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: 72);

      final cos = math.cos(angle);
      final sin = math.sin(angle);
      final dx = cos > 0.3
          ? anchor.dx
          : (cos < -0.3 ? anchor.dx - painter.width : anchor.dx - painter.width / 2);
      final dy = sin > 0.3
          ? anchor.dy
          : (sin < -0.3 ? anchor.dy - painter.height : anchor.dy - painter.height / 2);
      painter.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.dimensions != dimensions ||
      old.primary != primary ||
      old.outline != outline ||
      old.labelStyle != labelStyle;
}
