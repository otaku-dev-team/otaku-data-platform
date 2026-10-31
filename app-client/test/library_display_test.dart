import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/local_prefs.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/theme/app_layout.dart';
import 'package:otaku_app/core/theme/library_density.dart';
import 'package:otaku_app/features/settings/display_settings.dart';
import 'package:otaku_app/shared/widgets/skeleton_list.dart';

/// 内存版本机偏好。真实实现要平台通道，单测里调不了。
class _MemoryPrefs implements LocalPrefs {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  group('LibraryDensity', () {
    test('fromKey 认不出的值回落到默认（坏设置不该让列表打不开）', () {
      expect(LibraryDensity.fromKey(null), LibraryDensity.comfort);
      expect(LibraryDensity.fromKey('不存在'), LibraryDensity.comfort);
      expect(LibraryDensity.fromKey(''), LibraryDensity.comfort);
    });

    test('fromKey 认得 name 写进 LocalPrefs 的那三种', () {
      for (final density in LibraryDensity.values) {
        expect(LibraryDensity.fromKey(density.name), density);
      }
    });

    test('密度越紧，文字区越矮；仅封面是 0', () {
      expect(
        LibraryDensity.coversOnly.bodyHeight,
        lessThan(LibraryDensity.compact.bodyHeight),
      );
      expect(
        LibraryDensity.compact.bodyHeight,
        lessThan(LibraryDensity.comfort.bodyHeight),
      );
      expect(LibraryDensity.coversOnly.bodyHeight, 0);
    });
  });

  group('AppLayout.gridMetrics', () {
    test('同一宽度下，密度越紧列数不减少', () {
      const width = 400.0;
      final comfort = AppLayout.gridMetrics(
        width,
        density: LibraryDensity.comfort,
      );
      final compact = AppLayout.gridMetrics(
        width,
        density: LibraryDensity.compact,
      );
      final covers = AppLayout.gridMetrics(
        width,
        density: LibraryDensity.coversOnly,
      );

      expect(compact.columns, greaterThanOrEqualTo(comfort.columns));
      expect(covers.columns, greaterThanOrEqualTo(compact.columns));
    });

    test('不带参数时与改动前一致（默认舒适）', () {
      const width = 393.0; // 常见手机逻辑宽度
      final explicit = AppLayout.gridMetrics(
        width,
        density: LibraryDensity.comfort,
      );
      final implicit = AppLayout.gridMetrics(width);
      expect(implicit.columns, explicit.columns);
      expect(implicit.cardWidth, explicit.cardWidth);
    });

    test('手动列数覆盖自适应，且不受自适应的 4 列上限约束', () {
      // 1600 宽自适应会算到 8 列，被压到 4；手动选 5 应该真的给 5。
      expect(AppLayout.gridMetrics(1600).columns, 4);
      expect(
        AppLayout.gridMetrics(1600, overrideColumns: 5).columns,
        5,
      );
    });

    test('手动列数下限仍是 2（一列会退化成列表）', () {
      expect(AppLayout.gridMetrics(400, overrideColumns: 1).columns, 2);
    });

    test('手机宽度下覆盖列数被最小卡宽压回（6 列只剩 45px 封面）', () {
      // 360 逻辑宽 − 2×16 页边距 = 328 可用宽；仅封面档最小卡宽 92 → 最多 3 列。
      const usable = 328.0;
      final auto = AppLayout.gridMetrics(
        usable,
        density: LibraryDensity.coversOnly,
      );
      expect(auto.columns, 3);

      final forced = AppLayout.gridMetrics(
        usable,
        density: LibraryDensity.coversOnly,
        overrideColumns: 6,
      );
      // 覆盖值不能压过本档密度的最小卡宽：压回自适应列数，而不是画 45px 的封面。
      expect(forced.columns, auto.columns);
      expect(forced.cardWidth, greaterThan(90));
    });

    test('宽屏覆盖列数不被压低（放得下就按用户选的来）', () {
      // 1920 − 2×16 = 1888，舒适档最小卡宽 190 → 放得下 6 列，不该被兜底改掉。
      const usable = 1888.0;
      final forced = AppLayout.gridMetrics(
        usable,
        density: LibraryDensity.comfort,
        overrideColumns: 6,
      );
      expect(forced.columns, 6);
      expect(forced.cardWidth, greaterThanOrEqualTo(190));
    });

    test('gridCellExtent：仅封面只剩封面高度', () {
      final comfort = AppLayout.gridCellExtent(
        cardWidth: 150,
        density: LibraryDensity.comfort,
        textScale: 1,
      );
      final covers = AppLayout.gridCellExtent(
        cardWidth: 150,
        density: LibraryDensity.coversOnly,
        textScale: 1,
      );
      expect(covers, lessThan(comfort));
      // 封面高度 = 卡宽 / (2/3)
      expect(covers, closeTo(150 / AppLayout.posterAspect, 0.001));
    });

    test('gridCellExtent 跟着字号缩放（大字体撑破卡片的旧 bug）', () {
      final normal = AppLayout.gridCellExtent(
        cardWidth: 150,
        density: LibraryDensity.comfort,
        textScale: 1,
      );
      final large = AppLayout.gridCellExtent(
        cardWidth: 150,
        density: LibraryDensity.comfort,
        textScale: 2,
      );
      expect(large, greaterThan(normal));
    });
  });

  group('SkeletonGrid', () {
    Future<SliverGridDelegateWithFixedCrossAxisCount> pumpSkeleton(
      WidgetTester tester,
      LibraryDensity density, {
      int? columns,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 600,
              child: SkeletonGrid(density: density, columns: columns),
            ),
          ),
        ),
      );
      final grid = tester.widget<GridView>(find.byType(GridView));
      return grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    }

    testWidgets('骨架屏列数与高度跟着密度走，不是写死舒适档', (tester) async {
      // 360 宽 − 2×16 = 328 可用：舒适 2 列、仅封面 3 列。
      final comfort = await pumpSkeleton(tester, LibraryDensity.comfort);
      expect(comfort.crossAxisCount, 2);
      final comfortExtent = comfort.mainAxisExtent!;

      // 同一棵树上换密度，必须真的重算——这就是「切档后加载完跳一下」的回归点。
      final covers = await pumpSkeleton(tester, LibraryDensity.coversOnly);
      expect(covers.crossAxisCount, 3);
      expect(covers.mainAxisExtent!, lessThan(comfortExtent));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('骨架屏与真实网格用同一套算法（同宽度同密度结果一致）', (tester) async {
      final delegate = await pumpSkeleton(tester, LibraryDensity.coversOnly);
      const usable = 360 - AppLayout.pagePadding * 2;
      final metrics = AppLayout.gridMetrics(
        usable,
        density: LibraryDensity.coversOnly,
      );
      expect(delegate.crossAxisCount, metrics.columns);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('LibraryDisplayController', () {
    ProviderContainer createContainer(_MemoryPrefs prefs) {
      final container = ProviderContainer(
        overrides: [localPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('默认舒适 + 自适应（列数 null）', () {
      final container = createContainer(_MemoryPrefs());
      final display = container.read(libraryDisplayProvider);

      expect(display.density, LibraryDensity.comfort);
      expect(display.columns, isNull);
    });

    test('切密度会写进偏好，重建后还在', () async {
      final prefs = _MemoryPrefs();
      final container = createContainer(prefs);
      container
          .read(libraryDisplayProvider.notifier)
          .setDensity(LibraryDensity.coversOnly);
      await Future<void>.delayed(Duration.zero);

      expect(prefs.values[LibraryDisplayController.densityKey], 'coversOnly');

      // 新容器读同一份偏好 → 恢复成仅封面（模拟重开 App）。
      final reopened = createContainer(prefs);
      expect(
        reopened.read(libraryDisplayProvider).density,
        LibraryDensity.coversOnly,
      );
    });

    test('设列数写入偏好；设回 null 会清掉键（回到自适应）', () async {
      final prefs = _MemoryPrefs();
      final container = createContainer(prefs);
      final controller = container.read(libraryDisplayProvider.notifier);

      controller.setColumns(3);
      await Future<void>.delayed(Duration.zero);
      expect(prefs.values[LibraryDisplayController.columnsKey], '3');
      expect(container.read(libraryDisplayProvider).columns, 3);

      // 关键回归：copyWith 的 `??` 会把 null 吃掉，导致「点自适应没反应」。
      controller.setColumns(null);
      await Future<void>.delayed(Duration.zero);
      expect(prefs.values.containsKey(LibraryDisplayController.columnsKey), isFalse);
      expect(container.read(libraryDisplayProvider).columns, isNull);
    });

    test('坏掉的列数（非数字 / < 2）按自适应处理', () {
      final prefs = _MemoryPrefs()
        ..values[LibraryDisplayController.columnsKey] = 'abc';
      expect(
        createContainer(prefs).read(libraryDisplayProvider).columns,
        isNull,
      );

      final small = _MemoryPrefs()
        ..values[LibraryDisplayController.columnsKey] = '1';
      expect(
        createContainer(small).read(libraryDisplayProvider).columns,
        isNull,
      );
    });

    test('坏掉的密度按舒适处理', () {
      final prefs = _MemoryPrefs()
        ..values[LibraryDisplayController.densityKey] = '???';
      expect(
        createContainer(prefs).read(libraryDisplayProvider).density,
        LibraryDensity.comfort,
      );
    });
  });
}
