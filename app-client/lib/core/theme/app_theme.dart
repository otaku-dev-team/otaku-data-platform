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

  static ThemeData light({ColorScheme? dynamicScheme, bool glass = false}) =>
      _build(Brightness.light, dynamicScheme, glass);

  static ThemeData dark({ColorScheme? dynamicScheme, bool glass = false}) =>
      _build(Brightness.dark, dynamicScheme, glass);

  /// 当前主题是不是「玻璃质感」。组件里用它决定要不要加模糊层。
  static bool isGlass(BuildContext context) =>
      Theme.of(context).extension<AppStyle>()?.glass ?? false;

  /// 卡片底色 / 描边，按当前亮度取，避免每个组件自己判 `isDark`。
  static Color cardColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkCard : card;

  static Color borderColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkBorder : cardBorder;

  static ThemeData _build(
    Brightness brightness,
    ColorScheme? dynamicScheme,
    bool glass,
  ) {
    final isDark = brightness == Brightness.dark;
    // 系统取色：直接拿 dynamic_color 从壁纸生成的整套配色，连 surface 一起用。
    // 只覆盖 `outlineVariant`：我们的描边是「比卡片深一点的同色系」，
    // 而 Material You 的 outlineVariant 偏灰，压在带色的底上会显脏。
    final border = isDark ? darkBorder : cardBorder;
    final scheme = (dynamicScheme ??
            ColorScheme.fromSeed(seedColor: brand, brightness: brightness))
        .copyWith(
          // fromSeed 生成的 surface 偏灰白，站点是明显带蓝的浅底，直接覆盖。
          surface: dynamicScheme != null
              ? dynamicScheme.surface
              : (isDark ? darkSurface : surface),
          onSurface: dynamicScheme != null
              ? dynamicScheme.onSurface
              : (isDark ? darkInk : ink),
          onSurfaceVariant: dynamicScheme != null
              ? dynamicScheme.onSurfaceVariant
              : (isDark ? darkInkSoft : inkSoft),
          outlineVariant: border,
          primary: dynamicScheme != null
              ? dynamicScheme.primary
              : (isDark ? const Color(0xFF66CCFF) : const Color(0xFF1C73B0)),
          secondary: dynamicScheme != null ? dynamicScheme.secondary : accent,
        );

    // 玻璃质感：让「层」变成半透明，露出 [GlassBackdrop] 那层渐变。
    final cardFill = glass
        ? (isDark
              ? const Color(0x59162431)
              : scheme.surfaceContainerLow.withValues(alpha: 0.55))
        : (isDark ? darkCard : card);
    final cardEdge = BorderSide(
      color: glass
          ? (isDark
                ? const Color(0x33FFFFFF)
                : scheme.outline.withValues(alpha: 0.16))
          : border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[AppStyle(glass: glass)],
      // 玻璃模式下 Scaffold 必须透明，否则那层渐变永远看不见。
      scaffoldBackgroundColor: glass ? Colors.transparent : scheme.surface,
      appBarTheme: AppBarTheme(
        // 与页面同色而不是纯白：白条压在浅蓝底上会切出一条明显的横缝，
        // 首页尤其突兀（顶上一条白、下面一片浅蓝）。分层交给卡片和描边。
        // 玻璃模式下直接透明，让背景透上来（模糊由 GlassBackdrop 的色块提供层次）。
        backgroundColor: glass
            ? Colors.transparent
            : (isDark ? darkSurface : scheme.surface),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cardFill,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: cardEdge,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: glass
            ? (isDark
                  ? const Color(0xCC162431)
                  : scheme.surfaceContainerLow.withValues(alpha: 0.9))
            : (isDark ? darkCard : card),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: glass
            ? Colors.transparent
            : (isDark ? darkSurface : scheme.surface),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: glass ? Colors.transparent : scheme.surface,
      ),
      dividerTheme: DividerThemeData(
        color: glass
            ? scheme.outline.withValues(alpha: 0.12)
            : (isDark ? darkBorder : border),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glass
            ? (isDark
                  ? const Color(0x33FFFFFF)
                  : scheme.surface.withValues(alpha: 0.45))
            : (isDark ? darkSurface : card),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? darkBorder : border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? darkBorder : border),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 主题上的实验开关（[ThemeData.extensions]）。
///
/// 做成 extension 而不是全局状态：组件只在自己 build 时读一次，
/// 主题一旦重建（开关改了）整棵树跟着更新，不用手动订阅 provider。
@immutable
class AppStyle extends ThemeExtension<AppStyle> {
  const AppStyle({required this.glass});

  final bool glass;

  @override
  AppStyle copyWith({bool? glass}) => AppStyle(glass: glass ?? this.glass);

  @override
  AppStyle lerp(ThemeExtension<AppStyle>? other, double t) {
    if (other is! AppStyle) return this;
    // 开关没有中间态：t < 0.5 保持原值，过了就切过去。
    return t < 0.5 ? this : other;
  }
}
