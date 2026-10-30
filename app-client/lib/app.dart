import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/platform_info.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/site_auth_bootstrap.dart';
import 'features/settings/settings_controller.dart';
import 'features/telemetry/usage_ping_bootstrap.dart';
import 'features/update/update_bootstrap.dart';
import 'shared/widgets/glass_backdrop.dart';

/// 应用根组件。只负责装配主题与路由，不放业务逻辑。
///
/// [SiteAuthBootstrap] 是「跟账号和数据走、不跟页面走」的东西：
/// 接站点授权回跳（回跳时 App 不一定停在登录页）。
///
/// [UpdateBootstrap] 同理：每次启动检查一次更新，弹窗挂在根 Navigator 上，
/// 不依赖用户落在哪一页。
///
/// 外观实验（设置 → 外观）：系统取色与玻璃质感都在这里装配，
/// 两个开关全关时走的就是原来的品牌蓝 + 实心卡片。
class OtakuApp extends ConsumerWidget {
  const OtakuApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);

    // 系统取色只在 Android 上问：其余平台恒为 null，问了只是白问
    // （插件在桌面端没有实现，测试环境里调它会抛 MissingPluginException）。
    if (appearance.dynamicColor && PlatformInfo.isAndroid) {
      return DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) => _app(
          ref,
          glass: appearance.glass,
          lightScheme: lightDynamic,
          darkScheme: darkDynamic,
        ),
      );
    }
    return _app(ref, glass: appearance.glass);
  }

  Widget _app(
    WidgetRef ref, {
    required bool glass,
    ColorScheme? lightScheme,
    ColorScheme? darkScheme,
  }) {
    return SiteAuthBootstrap(
      child: UsagePingBootstrap(
        child: UpdateBootstrap(
          child: MaterialApp.router(
            title: 'Otaku',
            debugShowCheckedModeBanner: false,
            // 取不到系统配色时（机型不支持 / 桌面端）退回品牌色，
            // 而不是给一套残缺的配色。
            theme: AppTheme.light(dynamicScheme: lightScheme, glass: glass),
            darkTheme: AppTheme.dark(dynamicScheme: darkScheme, glass: glass),
            // 用户可在设置页里改；默认跟随系统。存在本机偏好里，
            // 因为它是设备级选择而不是账号设置。
            themeMode: ref.watch(themeModeProvider),
            routerConfig: ref.watch(appRouterProvider),
            // 玻璃模式下垫一层带色块的渐变：半透明的前提是下面有东西可透。
            builder: glass
                ? (context, child) =>
                      GlassBackdrop(child: child ?? const SizedBox())
                : null,
          ),
        ),
      ),
    );
  }
}
