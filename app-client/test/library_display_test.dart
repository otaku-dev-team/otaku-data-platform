import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/local_prefs.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/theme/app_layout.dart';
import 'package:otaku_app/core/theme/library_density.dart';
import 'package:otaku_app/features/settings/display_settings.dart';

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
