import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// 全局主题。
///
/// **色板来自首站的 `static/style.css`**，具体色值不写在这里——唯一来源是
/// [Palette]（`design_tokens.dart`）。站点是 `--brand-*` 蓝色阶 + `--accent-*`
/// 青色 + 浅蓝底 `#f1f6fc` + 白卡片。桌面端跟站点长一样，用户在两个端之间切换
/// 不会有"换了个软件"的错觉。
abstract final class AppTheme {
  /// 主色 = 站点 `--brand-400`（天蓝 `#66CCFF`）。
  ///
  /// 站点 `:root` 的注释是「品牌主色（天蓝 #66CCFF 族）—— 全站主视觉」，主按钮、
  /// 顶栏、Hero 全是这块纯亮天蓝打底、配 `--on-bright` 深字（对比 11.6:1）。
  ///
  /// 此前这里填的是 `--brand-600`（`#2A9AE0`）——那是**白底上的链接文字色**，
  /// 不是主色。两档在色阶里只差两级，单看某一屏都不像错，两端摆一起才看得出
  /// 一个是浅天蓝、一个是中蓝。
  ///
  /// 主色只做底、不做字：它在白底上的对比只有 1.8:1。要拿它写字用
  /// [brandInk]。
  static const Color brand = Palette.brand400;

  /// 站点 `--brand-300`：卡片 hover 时的描边、封面占位的渐变中段。
  static const Color brandLine = Palette.brand300;

  /// 主色在**亮底上画线 / 画环**时的版本 = 站点 `--brand-600`
  /// （`--focus-outline: 2px solid var(--brand-600)`）。
  ///
  /// 用常量而不是 `context` 读取，是因为有几处 `RefreshIndicator` 在
  /// `_buildList(...)` 这类方法里、拿不到 context；而这个色属于品牌 chrome，
  /// 跟系统取色无关。`RefreshIndicator` 默认读 `primary`，换主色之后那个
  /// 转圈在白底上只有 1.6:1，等于没有。
  static const Color brandStrong = Palette.brand600;

  /// 站点 `--brand-50`：选中态胶囊、很淡的品牌色底。
  static const Color brandSoft = Palette.brand50;

  /// 站点 `--accent-500`（favicon 里的那抹青）：封面占位渐变的尾段。
  static const Color accent = Palette.accent500;

  /// 站点 `--surface` / `--surface-2`。
  static const Color surface = Palette.surface;
  static const Color surfaceAlt = Palette.surface2;

  /// 站点 `--card-bg` 与卡片描边。
  static const Color card = Palette.card;
  static const Color cardBorder = Palette.cardBorder;

  /// 站点 `--ink-900` / `--ink-500`。
  static const Color ink = Palette.ink900;
  static const Color inkSoft = Palette.ink500;

  // 深色模式站点没有对应实现，按同一套色相推出，保证不是"另一套设计"。
  static const Color darkSurface = Color(0xFF0B1620);
  static const Color darkCard = Color(0xFF152431);
  static const Color darkBorder = Color(0xFF263D50);
  static const Color darkInk = Color(0xFFE6EDF5);
  static const Color darkInkSoft = Color(0xFF93A4B8);

  /// 卡片圆角 = 站点 `--radius-lg`。
  static const double cardRadius = Radii.lg;

  /// 卡片默认阴影 = 站点 `--shadow-sm`。
  ///
  /// 此前的值只抄了 `--shadow-sm` 的第二层（blur 3），漏了 blur 2 那层。
  /// 现在指向完整令牌，差的是叠加一层 5% 透明度的 2px 阴影，肉眼不可见。
  /// 深色主题里阴影几乎不可见，真正分层靠描边，所以两套主题共用这一份。
  static const List<BoxShadow> cardShadow = Shadows.sm;

  /// 桌面 hover 的阴影 = 站点 `--shadow-lg`（鼠标才有意义，手机不触发）。
  static const List<BoxShadow> cardShadowHover = Shadows.lg;

  static ThemeData light({ColorScheme? dynamicScheme, bool glass = false}) =>
      _build(Brightness.light, dynamicScheme, glass);

  static ThemeData dark({ColorScheme? dynamicScheme, bool glass = false}) =>
      _build(Brightness.dark, dynamicScheme, glass);

  /// 当前主题是不是「玻璃质感」。组件里用它决定要不要加模糊层。
  static bool isGlass(BuildContext context) =>
      Theme.of(context).extension<AppStyle>()?.glass ?? false;

  /// 品牌色在**亮底上当文字 / 图标**时的版本：亮色用站点 `--brand-700`
  /// （`a { color: var(--brand-700) }` 那一档），深色用回主色。
  ///
  /// 主色 `#66CCFF` 在白底上只有 1.8:1，当字读不出来；站点也是这么拆的——
  /// 按钮、导航用 400 打底，链接用 700 写字。反过来，深色主题的底上 700
  /// 只有 2.3:1，所以那边直接用 400。
  ///
  /// 系统取色开着的时候跟着系统的 primary 走，否则开了取色还会冒出
  /// 一块固定天蓝。
  static Color brandInk(BuildContext context) =>
      Theme.of(context).extension<AppStyle>()?.brandInk ??
      (Theme.of(context).brightness == Brightness.dark
          ? brand
          : Palette.brand700);

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
    // 主色当「字」和「焦点」用的两档，跟站点一样分开：
    // 亮色下字用 `--brand-700`（5.7:1），焦点环与进度环用 `--brand-600`；
    // 深色下主色本身就有 8.7:1，两处都直接用主色。
    final brandText = dynamicScheme != null
        ? dynamicScheme.primary
        : (isDark ? brand : Palette.brand700);
    final brandFocus = dynamicScheme != null
        ? dynamicScheme.primary
        : (isDark ? brand : Palette.brand600);
    // 种子仍然是 `--brand-600`：它只生成我们没显式覆盖的那些派生档
    // （容器色、outline、inverse 一类）。主色本身在下面直接覆盖，种子换了
    // 只会把这些已经调好的中性色一起带着漂，没必要。
    final scheme = (dynamicScheme ??
            ColorScheme.fromSeed(
              seedColor: Palette.brand600,
              brightness: brightness,
            ))
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
          // 主色在亮暗两套里都是那抹天蓝：深色底上它的对比是 8.7:1，
          // 不需要另配一档。`onPrimary` 必须跟着改成深字——留白字只有 1.8:1。
          primary: dynamicScheme != null ? dynamicScheme.primary : brand,
          onPrimary: dynamicScheme != null
              ? dynamicScheme.onPrimary
              : OnBright.onBright,
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
      extensions: <ThemeExtension<dynamic>>[
        // 亮底上的品牌字色。系统取色开着时必须是系统的 primary
        // ——否则底色是系统色、字还是固定天蓝，两块对不上。
        AppStyle(glass: glass, brandInk: brandText),
      ],
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
        shape: RoundedRectangleBorder(borderRadius: Radii.circularXl()),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: glass
            ? Colors.transparent
            : (isDark ? darkSurface : scheme.surface),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: Radii.circularMd(),
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
      // 文字按钮与描边按钮的默认前景色是 `primary`，也就是那抹天蓝。
      // 天蓝只能做底不能做字（白底 1.8:1），所以默认改成一档深的。
      // 单独在每处写 `foregroundColor` 也行，但 22 个 TextButton 里只有两个
      // 写了，剩下的全靠默认值——默认值对了才不会漏。
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: brandText),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: brandText),
      ),
      // 进度环也是拿 primary 画的，同样的问题，跟着焦点色走（`--brand-600`）。
      progressIndicatorTheme: ProgressIndicatorThemeData(color: brandFocus),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glass
            ? (isDark
                  ? const Color(0x33FFFFFF)
                  : scheme.surface.withValues(alpha: 0.45))
            : (isDark ? darkSurface : card),
        border: OutlineInputBorder(
          borderRadius: Radii.circularMd(),
          borderSide: BorderSide(color: isDark ? darkBorder : border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.circularMd(),
          borderSide: BorderSide(color: isDark ? darkBorder : border),
        ),
        // 站点 `--focus-outline`：2px solid `--brand-600`。Material 默认的
        // 焦点边框是 primary，换了主色之后会变成一根淡蓝细线。
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.circularMd(),
          borderSide: BorderSide(color: brandFocus, width: 1.6),
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
  const AppStyle({required this.glass, required this.brandInk});

  final bool glass;

  /// 亮底上的品牌文字 / 图标色，见 [AppTheme.brandInk]。
  final Color brandInk;

  @override
  AppStyle copyWith({bool? glass, Color? brandInk}) => AppStyle(
    glass: glass ?? this.glass,
    brandInk: brandInk ?? this.brandInk,
  );

  @override
  AppStyle lerp(ThemeExtension<AppStyle>? other, double t) {
    if (other is! AppStyle) return this;
    // 开关没有中间态：t < 0.5 保持原值，过了就切过去。
    return AppStyle(
      glass: t < 0.5 ? glass : other.glass,
      brandInk: Color.lerp(brandInk, other.brandInk, t)!,
    );
  }
}
