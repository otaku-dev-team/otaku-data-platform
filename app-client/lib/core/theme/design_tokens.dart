/// 设计令牌。**数值唯一来源是首站 `app/static/style.css` 的 `:root`（76 个）**。
///
/// 为什么单独一个文件：`AppTheme` 只接了其中 12 个（9 个颜色 + `radius-lg` +
/// 两档阴影的近似值），其余 64 个没有落点，于是间距、字号、语义色散在
/// `app-client/lib` 的 333 处硬编码里（`SizedBox` 162、`EdgeInsets` 90、
/// `Color(0x..)` 53、`BorderRadius.circular` 28）。
///
/// **只给新代码用，存量不改**。改那 333 处是纯风险、无收益。
///
/// ## 换算
///
/// CSS 用 `rem`，本项目按浏览器默认 `1rem = 16px` 换算成 Flutter 的 dp。
/// 全站没有改过 `html { font-size }`，所以这条换算是确定的。
///
/// ## 刻意不搬的两组
///
/// - **`--detail-*` 5 个**（详情封面 104px、标题 20、卡片最小 112、间距 10、元信息列 60）：
///   客户端详情页是另做的一套布局（封面 220、双栏断点 720），照搬会误导。
/// - **`--font-sans`**：首站是系统字体栈，Flutter 用自己的默认字体，没有可搬的字形文件。
///
/// ## 字号与行高是两件事
///
/// 首站 `--text-*` 只是尺寸，**没有绑定行高**——行高各元素单独写（正文块 1.7、
/// 标题 1.15 / 1.04 / 1.25、徽标 1.7）。所以这里不提供「字号 + 行高」的组合，
/// 用的时候按场景自己给 `height`，别为了省事硬塞一个统一值。
library;

import 'package:flutter/widgets.dart';

/// 色板：`--brand-*` 10 档、`--accent-*` 10 档、`--ink-*` 5 档、3 个底色，
/// 外加 1 个首站没提成变量的卡片描边。
///
/// **主色是 `brand400`（`#66CCFF`）**——站点 `:root` 的注释原话是「品牌主色
/// （天蓝 #66CCFF 族）—— 全站主视觉」。青绿 `accent500` 是辅助色。
///
/// 主色在这一档色阶里被拆成两个角色用，跟站点一样：
///
/// - **做底**：`brand400` + `OnBright.onBright` 深字。主按钮、顶栏、选中的
///   `tag-chip` 都是这个组合（白字压上去只有 1.8:1）。
/// - **做字**：`brand700`。白底上的链接、分类标签、区块色条用它
///   （`brand400` 当字只有 1.8:1，`brand700` 是 5.7:1）。
///
/// 深色主题首站没有实现，由 `AppTheme` 按同色相另推一套，不在这里。
abstract final class Palette {
  const Palette._();

  static const Color brand50 = Color(0xFFEAF6FF);
  static const Color brand100 = Color(0xFFD6ECFF);
  static const Color brand200 = Color(0xFFAEDFFF);
  static const Color brand300 = Color(0xFF85CDFF);

  /// 主色（站点 `--brand-400`）。
  static const Color brand400 = Color(0xFF66CCFF);

  static const Color brand500 = Color(0xFF46B6F7);
  static const Color brand600 = Color(0xFF2A9AE0);

  /// 主色在**白底上当文字**时的版本（站点 `a { color }` 那一档）。
  static const Color brand700 = Color(0xFF1C73B0);

  static const Color brand800 = Color(0xFF16598C);
  static const Color brand900 = Color(0xFF114770);

  static const Color accent50 = Color(0xFFE8FAF8);
  static const Color accent100 = Color(0xFFD2F4F0);
  static const Color accent200 = Color(0xFFAAECE6);
  static const Color accent300 = Color(0xFF7FE2DA);
  static const Color accent400 = Color(0xFF4FCFC4);
  static const Color accent500 = Color(0xFF39C5BB);
  static const Color accent600 = Color(0xFF25A79C);
  static const Color accent700 = Color(0xFF157D74);
  static const Color accent800 = Color(0xFF0F635D);
  static const Color accent900 = Color(0xFF0A4A45);

  /// 正文色阶。`ink800` 是首站 `body` 的默认前景色，不是 `ink900`。
  static const Color ink900 = Color(0xFF17142B);
  static const Color ink800 = Color(0xFF241F3F);
  static const Color ink700 = Color(0xFF3D3759);
  static const Color ink500 = Color(0xFF6F6A8A);

  /// 首站注释明确限定为「装饰用」，正文不要用（对比度不足）。
  static const Color ink400 = Color(0xFF9A95B3);

  static const Color surface = Color(0xFFF1F6FC);
  static const Color surface2 = Color(0xFFE6EEF8);
  static const Color card = Color(0xFFFFFFFF);

  /// 卡片描边 `#dfe9f4`。**严格说不是 `:root` 令牌**——首站在 14 处直接写死
  /// 这个值、没有提成变量。收进来是因为它已经是卡片视觉的一部分，且客户端
  /// 一直在用，留一份散值反而更容易走样。
  static const Color cardBorder = Color(0xFFDFE9F4);
}

/// 语义色：状态提示、徽标、表单校验。首站是「浅底 + 深字」成对出现的。
///
/// 客户端此前没有这组，红/绿都是各处手写的字面量（同一件事在不同页面
/// 用了不同的绿），所以这里一次给全，新代码只从这里取。
abstract final class Semantic {
  const Semantic._();

  static const Color okBg = Color(0xFFE7F8EF);
  static const Color okFg = Color(0xFF157347);

  static const Color warnBg = Color(0xFFFFF5E0);
  static const Color warnFg = Color(0xFF855C00);

  static const Color errBg = Color(0xFFFDECF0);
  static const Color errFg = Color(0xFFC32D4D);

  static const Color infoBg = Color(0xFFEAF7FF);
  static const Color infoFg = Color(0xFF0F5E8C);

  /// 通过 / 不通过。首站只给了前景色（用在测试结果行上），没有配套底色。
  static const Color passFg = Color(0xFF157347);
  static const Color failFg = Color(0xFFC32D4D);
}

/// 作品类型色：动画蓝 / 漫画粉 / 游戏青 / 小说紫。
///
/// 值来自首站 `.type-tab[data-type=...]` 的 `--type-a`（浅，选中态渐变起点）与
/// `--type-b`（深，图标与文字色）。客户端只用一个色（图标 + 14% 透明底），
/// 所以取 `--type-b`；浅档留着做渐变。
///
/// **这四个色相的归谁是有意的，别按「好看」重排。** 2026-11-01 之前客户端自己配了
/// 一套（动画靛、漫画粉、游戏紫、小说青），其中**游戏与小说跟首站正好互换**——
/// 同一部作品在两个端看到的是不同颜色，而这正是「品牌色对齐」最容易漏掉的一处：
/// 看的不是品牌蓝有没有用对，是同一语义在两端的色相是否一致。
///
/// 漫画粉与小说紫首站是直接写死的色值、没提成 `:root` 变量，所以这两对严格说
/// 不是令牌搬运，是把首站的两处散值收了进来（同 [Palette.cardBorder] 的处理）。
abstract final class TypeColor {
  const TypeColor._();

  static const Color animeLight = Palette.brand300;
  static const Color anime = Palette.brand600;

  static const Color comicLight = Color(0xFFFFB3C7);
  static const Color comic = Color(0xFFE8557D);

  static const Color gameLight = Palette.accent300;
  static const Color game = Palette.accent600;

  static const Color novelLight = Color(0xFFCDB4F6);
  static const Color novel = Color(0xFF7C5CD6);

  /// 类型未知。首站没有这一档（它的四类枚举是闭合的），取 `--ink-400`：
  /// 首站注释说它是「装饰用」，作图标色正好，不当正文。
  static const Color unknown = Palette.ink400;
}

/// 亮色大图上的文字（首页 hero、海报拼贴那类区域）。
abstract final class OnBright {
  const OnBright._();

  static const Color onBright = Color(0xFF0A2D42);

  /// `rgba(10, 45, 66, 0.72)`——0.72 × 255 ≈ 184。
  static const Color onBrightSoft = Color(0xB80A2D42);

  /// `rgba(10, 45, 66, 0.24)`——0.24 × 255 ≈ 61。
  static const Color onBrightLine = Color(0x3D0A2D42);

  /// 首站 `--deep-800`：比 `onBright` 更深一档，用在深底再叠一层的地方。
  static const Color deep800 = Color(0xFF123A55);
}

/// 间距 8pt 刻度。首站注释写的是「全站唯一来源」。
///
/// 客户端目前 `SizedBox` 162 处、`EdgeInsets` 90 处各自写死。新代码用这里。
abstract final class Space {
  const Space._();

  /// `--space-1` 0.25rem
  static const double s1 = 4;

  /// `--space-2` 0.5rem
  static const double s2 = 8;

  /// `--space-3` 0.75rem
  static const double s3 = 12;

  /// `--space-4` 1rem
  static const double s4 = 16;

  /// `--space-5` 1.25rem
  static const double s5 = 20;

  /// `--space-6` 1.5rem
  static const double s6 = 24;

  /// `--space-8` 2rem
  static const double s8 = 32;

  /// `--space-10` 2.5rem
  static const double s10 = 40;

  /// `--space-12` 3rem
  static const double s12 = 48;
}

/// 字号阶梯。首站全站用了 115 处（`xs` 59、`sm` 33、`base` 11 最多）。
///
/// **不带行高**，见文件头说明。
abstract final class FontSize {
  const FontSize._();

  /// `--text-xs` 0.75rem
  static const double xs = 12;

  /// `--text-sm` 0.8125rem
  static const double sm = 13;

  /// `--text-base` 0.875rem——首站正文字号。
  static const double base = 14;

  /// `--text-md` 1rem
  static const double md = 16;

  /// `--text-lg` 1.125rem
  static const double lg = 18;

  /// `--text-xl` 1.25rem
  static const double xl = 20;

  /// `--text-2xl` 1.5rem
  static const double xxl = 24;

  /// `--text-3xl` 1.875rem
  static const double xxxl = 30;
}

/// 圆角 4 档。
abstract final class Radii {
  const Radii._();

  /// `--radius-sm`
  static const double sm = 8;

  /// `--radius-md`——首站封面框、输入框用的就是这档。
  static const double md = 12;

  /// `--radius-lg`——卡片。
  static const double lg = 16;

  /// `--radius-xl`
  static const double xl = 20;

  static BorderRadius circularSm() => BorderRadius.circular(sm);
  static BorderRadius circularMd() => BorderRadius.circular(md);
  static BorderRadius circularLg() => BorderRadius.circular(lg);
  static BorderRadius circularXl() => BorderRadius.circular(xl);
}

/// 阴影 3 档。原值是 CSS `box-shadow`，这里是逐条换算，不是近似。
///
/// 换算口径：`0 1px 2px rgb(20 54 82 / 0.05)` →
/// `BoxShadow(offset: Offset(0,1), blurRadius: 2, color: rgb(20,54,82) @5%)`。
/// `rgb(20 54 82)` = `#143652`；alpha 乘 255 取整（0.05→13、0.06→15、0.08→20、0.18→46）。
abstract final class Shadows {
  const Shadows._();

  /// `--shadow-sm`
  static const List<BoxShadow> sm = [
    BoxShadow(color: Color(0x0D143652), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F143652), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// `--shadow-md`
  static const List<BoxShadow> md = [
    BoxShadow(
      color: Color(0x14143652),
      blurRadius: 12,
      spreadRadius: -2,
      offset: Offset(0, 4),
    ),
    BoxShadow(
      color: Color(0x0D143652),
      blurRadius: 6,
      spreadRadius: -2,
      offset: Offset(0, 2),
    ),
  ];

  /// `--shadow-lg`
  static const List<BoxShadow> lg = [
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
}

/// 动效：一条缓动曲线 + 两档时长。
abstract final class Motion {
  const Motion._();

  /// `--ease` = `cubic-bezier(0.4, 0, 0.2, 1)`，Material 的标准缓出。
  static const Cubic ease = Cubic(0.4, 0, 0.2, 1);

  /// `--dur-fast` 150ms
  static const Duration fast = Duration(milliseconds: 150);

  /// `--dur-base` 240ms
  static const Duration base = Duration(milliseconds: 240);
}

/// 焦点环。桌面端键盘导航要靠它，移动端不触发。
abstract final class FocusTokens {
  const FocusTokens._();

  /// `--focus-outline` = `2px solid var(--brand-600)` 的宽度部分。
  static const double outlineWidth = 2;

  /// `--focus-ring` = `0 0 0 3px rgba(43, 154, 224, 0.30)` 的扩散。
  ///
  /// 注意首站原值的 rgb 是 `(43, 154, 224)`，而 `--brand-600` 是
  /// `rgb(42, 154, 224)`——红值差 1，应是手写笔误。这里**照抄原值不改**：
  /// 改成与 brand600 一致会让两边比对时多出一条无意义的差异，而这 1/255
  /// 肉眼不可见。
  static const double ringSpread = 3;

  static const BoxShadow ring = BoxShadow(
    color: Color(0x4D2B9AE0),
    spreadRadius: ringSpread,
  );
}
