import 'package:flutter/material.dart';

/// 全局主题。
///
/// **色板来自来源站的 `static/style.css`**，不是随手取的近似值：
/// 站点是 `--brand-*` 蓝色阶 + `--accent-*` 青色 + 浅蓝底 `#f1f6fc` + 白卡片。
/// 桌面端跟站点长一样，用户在两个端之间切换不会有"换了个软件"的错觉。
/// 改色只改这里的常量。
abstract final class AppTheme {
  /// 主题种子色 = 站点 `--brand-600`。
  static const Color brand = Color(0xFF2A9AE0);

  /// 站点 `--brand-300`：卡片 hover 时的描边、封面占位的渐变中段。
  static const Color brandLine = Color(0xFF85CDFF);

  /// 站点 `--brand-50`：选中态胶囊、很淡的品牌色底。
  static const Color brandSoft = Color(0xFFEAF6FF);

  /// 站点 `--accent-500`（favicon 里的那抹青）：封面占位渐变的尾段。
  static const Color accent = Color(0xFF39C5BB);

  /// 站点 `--surface` / `--surface-2`。
  static const Color surface = Color(0xFFF1F6FC);
  static const Color surfaceAlt = Color(0xFFE6EEF8);

  /// 站点 `--card-bg` 与卡片描边 `#dfe9f4`。
  static const Color card = Color(0xFFFFFFFF);
  static const Color cardBorder = Color(0xFFDFE9F4);

  /// 站点 `--ink-900` / `--ink-500`。
  static const Color ink = Color(0xFF17142B);
  static const Color inkSoft = Color(0xFF6F6A8A);

  // 深色模式站点没有对应实现，按同一套色相推出，保证不是"另一套设计"。
  static const Color darkSurface = Color(0xFF0B1620);
  static const Color darkCard = Color(0xFF152431);
  static const Color darkBorder = Color(0xFF263D50);
  static const Color darkInk = Color(0xFFE6EDF5);
  static const Color darkInkSoft = Color(0xFF93A4B8);

  /// 卡片圆角 = 站点 `--radius-lg`。
  static const double cardRadius = 16;

  /// 卡片默认阴影：只做一点点浮起。深色主题里阴影几乎不可见，
  /// 真正分层靠描边，所以两套主题共用这一份，不各写一套。
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x0D143652), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// 桌面 hover 的阴影（鼠标才有意义，手机不触发）。
  static const List<BoxShadow> cardShadowHover = [
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
  ];

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  /// 卡片底色 / 描边，按当前亮度取，避免每个组件自己判 `isDark`。
  static Color cardColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkCard : card;

  static Color borderColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkBorder : cardBorder;

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(seedColor: brand, brightness: brightness).copyWith(
          // fromSeed 生成的 surface 偏灰白，站点是明显带蓝的浅底，直接覆盖。
          surface: isDark ? darkSurface : surface,
          onSurface: isDark ? darkInk : ink,
          onSurfaceVariant: isDark ? darkInkSoft : inkSoft,
          outlineVariant: isDark ? darkBorder : cardBorder,
          primary: isDark ? const Color(0xFF66CCFF) : const Color(0xFF1C73B0),
          secondary: accent,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? darkCard : card,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? darkCard : card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: isDark ? darkBorder : cardBorder),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? darkSurface : card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? darkBorder : cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? darkBorder : cardBorder),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
