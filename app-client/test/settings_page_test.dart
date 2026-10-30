import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/core/storage/memory_work_cache.dart';
import 'package:otaku_app/core/storage/work_cache.dart';
import 'package:otaku_app/core/storage/work_cache_provider.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/core/config/app_config.dart';
import 'package:otaku_app/features/settings/settings_controller.dart';
import 'package:otaku_app/features/settings/storage_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryLocalPrefs prefs;
  late InMemoryWorkCache cache;

  setUp(() {
    prefs = InMemoryLocalPrefs();
    cache = InMemoryWorkCache();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        localPrefsProvider.overrideWithValue(prefs),
        workCacheProvider.overrideWithValue(cache),
        appInitialLocationProvider.overrideWithValue(RoutePaths.settings),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpSettings(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const OtakuApp()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  ThemeMode currentThemeMode(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

  group('主题模式', () {
    testWidgets('默认跟随系统，切成深色后立刻生效并落盘', (tester) async {
      final container = createContainer();
      await pumpSettings(tester, container);

      expect(currentThemeMode(tester), ThemeMode.system);

      // 主题选择搬到了「外观」二级页：主页面只引入口。
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('深色'));
      await tester.pump();

      expect(currentThemeMode(tester), ThemeMode.dark);
      expect(prefs.read(ThemeModeController.prefsKey), 'dark');
    });

    test('重开应用仍然记得上次的选择', () {
      final first = ProviderContainer(
        overrides: [localPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(first.dispose);
      first.read(themeModeProvider.notifier).select(ThemeMode.light);

      final second = ProviderContainer(
        overrides: [localPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(second.dispose);
      expect(second.read(themeModeProvider), ThemeMode.light);
    });

    test('本机存了认不出来的值 → 退回跟随系统，而不是崩', () {
      final dirty = InMemoryLocalPrefs({ThemeModeController.prefsKey: '紫色'});
      final container = ProviderContainer(
        overrides: [localPrefsProvider.overrideWithValue(dirty)],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), ThemeMode.system);
    });
  });

  group('离线缓存', () {
    testWidgets('没有缓存时说「暂无缓存」，清除按钮不可点', (tester) async {
      final container = createContainer();
      await pumpSettings(tester, container);

      await tester.tap(find.text('离线缓存'));
      await tester.pumpAndSettle();

      // 主页面那行入口的副标题也写着「暂无缓存」，这里只看二级页里的那张卡。
      expect(
        find.descendant(
          of: find.byType(StorageSettingsPage),
          matching: find.text('暂无缓存'),
        ),
        findsOneWidget,
      );
      // 这一页有两张卡都带「清除」（离线缓存 / 图片缓存），这里看第一张。
      final clear = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '清除').first,
      );
      expect(clear.onPressed, isNull);
    });

    testWidgets('有缓存时显示条数，清除后回到暂无缓存', (tester) async {
      await cache.writeDetail(
        const DetailCacheKey('W-1'),
        const Work(workId: 'W-1', workType: WorkType.anime, title: '进击的巨人'),
      );

      final container = createContainer();
      await pumpSettings(tester, container);

      await tester.tap(find.text('离线缓存'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(StorageSettingsPage),
          matching: find.textContaining('1 条'),
        ),
        findsOneWidget,
      );

      // 同上：取第一张卡的「清除」（离线缓存）。
      await tester.tap(find.widgetWithText(TextButton, '清除').first);
      await tester.pumpAndSettle();
      // 二次确认：清除是不可逆的（离线时再也看不到这些内容）。
      expect(find.text('清除离线缓存？'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '清除'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(StorageSettingsPage),
          matching: find.text('暂无缓存'),
        ),
        findsOneWidget,
      );
      expect((await cache.usage()).entries, 0);
      expect(find.text('已清除离线缓存'), findsOneWidget);
    });
  });

  group('关于', () {
    testWidgets('显示版本与来源声明', (tester) async {
      final container = createContainer();
      await pumpSettings(tester, container);

      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();

      expect(find.text('1.0.0'), findsOneWidget);
      // 铁律 3 的对外说法：抓不到 ≠ 已删除。用户在设置里也该看得到这句。
      expect(find.textContaining('只读同步'), findsOneWidget);
      expect(find.textContaining('不等于来源站已删除'), findsOneWidget);
    });
  });

  group('设置入口', () {
    testWidgets('主页面只有三行入口，各自带当前值', (tester) async {
      final container = createContainer();
      await pumpSettings(tester, container);

      expect(find.text('外观'), findsOneWidget);
      expect(find.text('离线缓存'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
      // 入口上直接写当前值，省得用户点进去才知道现在是深色还是浅色。
      expect(find.text('跟随系统'), findsOneWidget);
      expect(find.textContaining('v${AppConfig.version}'), findsOneWidget);

      // 内容已经搬走：主页面不该再出现主题选择器。
      expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
    });
  });
}
