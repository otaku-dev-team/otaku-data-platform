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
import 'package:otaku_app/features/settings/settings_controller.dart';
import 'package:otaku_app/features/reminders/reminder_settings.dart';

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

      expect(find.text('暂无缓存'), findsOneWidget);
      final clear = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '清除'),
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

      expect(find.textContaining('1 条'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '清除'));
      await tester.pumpAndSettle();
      // 二次确认：清除是不可逆的（离线时再也看不到这些内容）。
      expect(find.text('清除离线缓存？'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '清除'));
      await tester.pumpAndSettle();

      expect(find.text('暂无缓存'), findsOneWidget);
      expect((await cache.usage()).entries, 0);
      expect(find.text('已清除离线缓存'), findsOneWidget);
    });
  });

  group('追番提醒', () {
    test('默认关：没写过偏好就不该开', () {
      final container = ProviderContainer(
        overrides: [localPrefsProvider.overrideWithValue(InMemoryLocalPrefs())],
      );
      addTearDown(container.dispose);

      expect(container.read(reminderEnabledProvider), isFalse);
    });

    test('写过 true 才开', () {
      final container = ProviderContainer(
        overrides: [
          localPrefsProvider.overrideWithValue(
            InMemoryLocalPrefs({'reminder_enabled': 'true'}),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(reminderEnabledProvider), isTrue);
    });

    testWidgets('桌面端禁用开关并说明原因，不给点了没反应的按钮', (tester) async {
      final container = createContainer();
      await pumpSettings(tester, container);

      expect(find.textContaining('桌面端暂不支持系统通知'), findsOneWidget);
      // 测试跑在 Windows 上（desktop 模式），这一项必须是禁用的。
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.onChanged, isNull);
    });
  });

  group('关于', () {
    testWidgets('显示版本与来源声明', (tester) async {
      final container = createContainer();
      await pumpSettings(tester, container);

      expect(find.text('1.0.0'), findsOneWidget);
      // 铁律 3 的对外说法：抓不到 ≠ 已删除。用户在设置里也该看得到这句。
      expect(find.textContaining('只读同步'), findsOneWidget);
      expect(find.textContaining('不等于来源站已删除'), findsOneWidget);
    });
  });
}
