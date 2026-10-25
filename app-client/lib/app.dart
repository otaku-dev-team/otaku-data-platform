import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/site_auth_bootstrap.dart';
import 'features/reminders/reminder_bootstrap.dart';
import 'features/settings/settings_controller.dart';

/// 应用根组件。只负责装配主题与路由，不放业务逻辑。
///
/// 两层 bootstrap 都是「跟账号和数据走、不跟页面走」的东西：
/// - [SiteAuthBootstrap]：接站点授权回跳（回跳时 App 不一定停在登录页）；
/// - [ReminderBootstrap]：追番提醒的重排与通知点击。
class OtakuApp extends ConsumerWidget {
  const OtakuApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SiteAuthBootstrap(
      child: ReminderBootstrap(
        child: MaterialApp.router(
          title: 'Otaku',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          // 用户可在设置页里改；默认跟随系统。存在本机偏好里，
          // 因为它是设备级选择而不是账号设置。
          themeMode: ref.watch(themeModeProvider),
          routerConfig: ref.watch(appRouterProvider),
        ),
      ),
    );
  }
}
