import 'package:flutter/material.dart';

/// 全局主题。只依赖 flutter，不引入第三方，方便单测时直接构造。
abstract final class AppTheme {
  /// 主题种子色。改这一个值即可整体换色。
  static const Color seed = Color(0xFF6E56CF);

  /// 列表卡片的圆角，列表与详情页共用，避免两处不一致。
  static const double cardRadius = 12;

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
