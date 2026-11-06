import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';

/// 站点品牌标识：方块徽标 + 站名。
///
/// 为什么徽标是「站名首字」而不是图片资源：换站时能跟着 `site.conf` 走的只有文字。
/// 图片要重新出图、按五档密度切、还得改 Android 的 launcher 资源；而一个字形的
/// 徽标换配置就生效。首站原本手写的就是一个「O」，这里只是把那个字改成从配置取。
///
/// 配色遵循 `design-style.md` §11 的既有口径：徽标底用品牌色渐变、字用
/// [OnBright.onBright] 深色（白字压在 `#66CCFF` 上只有 1.8:1）。
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 34,
    this.showName = true,
    this.subtitle,
    this.name,
  });

  /// 徽标边长。名字与副标题的字号跟着它缩放，避免两处各调一次。
  final double size;

  /// 是否在徽标右边显示站名。
  final bool showName;

  /// 站名下面那行小字（首页放日期）。为空则不占位。
  final String? subtitle;

  /// 覆盖站名。只给测试与演示用，正常一律取 [AppConfig.appName]。
  final String? name;

  String get _name => name ?? AppConfig.appName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = _name;
    final initial = name == null
        ? AppConfig.brandInitial
        : (resolved.trim().isEmpty
              ? '?'
              : String.fromCharCode(resolved.trim().runes.first).toUpperCase());

    final badge = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        // 品牌蓝 → 站点那抹青，和封面占位、渐变头图同一族色。
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.brand, AppTheme.accent],
        ),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: OnBright.onBright,
          fontSize: size * 0.53,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );

    if (!showName) return badge;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        badge,
        SizedBox(width: size * 0.3),
        // AppBar 里标题的宽度是抢来的（右边还有设置与账号），所以这一列
        // 必须能收缩：不包 Flexible，窄屏上两行文字会把工具条挤出 33px。
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                resolved,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  height: 1.1,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 一行小号署名，给空态 / 错误态 / 加载态用。
///
/// 这些状态下页面大半是空白的，是品牌最自然的落点；同时也让「这一屏是哪个站」
/// 在断网、空数据时也说得清——出问题时用户截图反馈，第一眼就能看出是哪个客户端。
class BrandSign extends StatelessWidget {
  const BrandSign({super.key, this.size = 18, this.text, this.dark = false});

  final double size;

  /// 覆盖署名文字，默认站名。
  final String? text;

  /// 深色底上用（浅色字），白底用 [Palette.brand700]（5.1:1）。
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final label = text ?? AppConfig.appName;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.32),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppTheme.brand, AppTheme.accent],
            ),
          ),
          child: Text(
            name6(label),
            style: TextStyle(
              color: OnBright.onBright,
              fontSize: size * 0.55,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: size * 0.72,
            height: 1.2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: dark ? Colors.white70 : Palette.brand700,
          ),
        ),
      ],
    );
  }

  static String name6(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '?';
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }
}
