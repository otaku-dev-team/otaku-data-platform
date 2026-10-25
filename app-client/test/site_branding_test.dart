import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/config/app_config.dart';
import 'package:otaku_app/core/config/site_branding.dart';

/// 品牌配置的默认值测试。
///
/// `--dart-define` 注入的那一半没法在单测里验证（编译期常量），
/// 但**默认值必须钉死**：换站的构建参数是给交付时用的，
/// 日常开发不传任何参数时，行为必须和以前一模一样。
void main() {
  group('SiteBranding 默认值（不传任何 dart-define）', () {
    test('应用名是 Otaku——与首站现状一致', () {
      expect(SiteBranding.appName, 'Otaku');
    });

    test('站点标识与 AppConfig 同源', () {
      expect(SiteBranding.siteId, AppConfig.siteId);
      expect(SiteBranding.siteId, 'otaku_site');
    });

    test('归属方是 com.otaku', () {
      expect(SiteBranding.company, 'com.otaku');
    });

    test('窗口标题带站点标识——多开时能从任务栏分清', () {
      expect(SiteBranding.windowTitle, 'Otaku · otaku_site');
    });

    test('版权行带归属方与当前年份', () {
      expect(SiteBranding.copyright, contains('com.otaku'));
      expect(SiteBranding.copyright, contains('${DateTime.now().year}'));
    });
  });
}
