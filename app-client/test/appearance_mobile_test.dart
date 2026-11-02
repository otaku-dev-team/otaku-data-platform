import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/core/theme/library_density.dart';
import 'package:otaku_app/features/settings/appearance_settings_page.dart';
import 'package:otaku_app/features/settings/display_settings.dart';
import 'package:otaku_app/features/settings/settings_controller.dart';

void main() {
  testWidgets('320宽双倍字号下外观选项不缩字，可选择并持久保存', (tester) async {
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = InMemoryLocalPrefs();
    final container = ProviderContainer(
      overrides: [localPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const AppearanceSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FittedBox), findsNothing);
    expect(tester.takeException(), isNull);
    final dark = find.widgetWithText(ChoiceChip, '深色');
    await tester.ensureVisible(dark);
    await tester.tap(dark);
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(prefs.read(ThemeModeController.prefsKey), 'dark');
    final compact = find.widgetWithText(ChoiceChip, '紧凑');
    await tester.ensureVisible(compact);
    await tester.tap(compact);
    await tester.pumpAndSettle();
    expect(
      container.read(libraryDisplayProvider).density,
      LibraryDensity.compact,
    );
    final columns = find.widgetWithText(ChoiceChip, '3');
    await tester.ensureVisible(columns);
    await tester.tap(columns);
    await tester.pumpAndSettle();
    expect(container.read(libraryDisplayProvider).columns, 3);
    expect(prefs.read(LibraryDisplayController.columnsKey), '3');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
