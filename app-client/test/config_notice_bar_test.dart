import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/data/datasources/app_config_data_source.dart';
import 'package:otaku_app/data/models/remote_config.dart';
import 'package:otaku_app/features/config/app_config_controller.dart';
import 'package:otaku_app/features/config/app_config_store.dart';
import 'package:otaku_app/shared/widgets/config_notice_bar.dart';

/// 配置驱动的公告条。
///
/// 测的是"不发版也能改"这条链路的可见结果：拉配置 → 显示公告 → 关掉 → 换版本又出现。
/// 关掉只记版本号是关键——只记布尔的话，运营改了文案老用户永远看不到。
class _StubSource implements AppConfigDataSource {
  _StubSource(this.config);

  RemoteConfig config;

  @override
  Future<RemoteConfig> fetch() async => config;
}

RemoteConfig _noticeConfig(int version, String text) => RemoteConfig(
  version: version,
  values: <String, dynamic>{
    'app.notice': <String, dynamic>{'enabled': true, 'text': text},
  },
);

void main() {
  testWidgets('公告：拉到配置才显示，关掉后消失，换版本重新出现', (tester) async {
    final prefs = InMemoryLocalPrefs();
    final source = _StubSource(_noticeConfig(100, '维护公告：今晚 23 点升级'));
    final container = ProviderContainer(
      overrides: [
        localPrefsProvider.overrideWithValue(prefs),
        appConfigDataSourceProvider.overrideWithValue(source),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ConfigNoticeBar())),
      ),
    );

    // 启动时只有本地缓存（空的），不该凭空出现公告
    expect(find.textContaining('维护公告'), findsNothing);

    await container.read(appConfigProvider.notifier).refresh();
    await tester.pump();
    expect(find.textContaining('维护公告'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭公告'));
    await tester.pump();
    expect(find.textContaining('维护公告'), findsNothing);
    expect(prefs.read(AppConfigStore.noticeDismissedKey), '100');

    // 运营改了文案 → 版本变化 → 重新出现（不是永久关闭）
    source.config = _noticeConfig(200, '新公告：新番合集已上线');
    await container.read(appConfigProvider.notifier).refresh();
    await tester.pump();
    expect(find.textContaining('新公告'), findsOneWidget);
  });

  testWidgets('开关关闭 / 文案为空时不占位', (tester) async {
    final container = ProviderContainer(
      overrides: [
        localPrefsProvider.overrideWithValue(InMemoryLocalPrefs()),
        appConfigDataSourceProvider.overrideWithValue(
          _StubSource(
            RemoteConfig(
              version: 1,
              values: <String, dynamic>{
                'app.notice': <String, dynamic>{'enabled': false, 'text': '不该显示'},
              },
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ConfigNoticeBar())),
      ),
    );
    await container.read(appConfigProvider.notifier).refresh();
    await tester.pump();

    expect(find.text('不该显示'), findsNothing);
    expect(tester.getSize(find.byType(ConfigNoticeBar)), Size.zero);
  });
}
