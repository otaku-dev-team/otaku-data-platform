import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_prefs_provider.dart';
import '../../core/theme/library_density.dart';

/// 作品库网格的显示偏好：密度 + 列数。
///
/// **设备级设置，不按账号分桶**——网格多密是「这块屏幕的主人看得惯什么」，
/// 换个账号登录不该把列表重排回去（与主题、外观实验同一个理由）。
///
/// 列数默认 `null` = 自适应（按可用宽度算 2–4 列，见 `AppLayout.gridMetrics`）。
/// 用户显式选了数字才覆盖，并且覆盖值放宽到 6 列：1920 宽的桌面选 5 列是合理的。
class LibraryDisplayController extends Notifier<LibraryDisplay> {
  static const String densityKey = 'library_density';
  static const String columnsKey = 'library_columns';

  @override
  LibraryDisplay build() {
    final prefs = ref.watch(localPrefsProvider);
    // 坏值一律回落到默认：设置项坏一个不该让列表打不开。
    final rawColumns = int.tryParse(prefs.read(columnsKey) ?? '');
    return LibraryDisplay(
      density: LibraryDensity.fromKey(prefs.read(densityKey)),
      columns: (rawColumns != null && rawColumns >= 2) ? rawColumns : null,
    );
  }

  void setDensity(LibraryDensity value) {
    if (state.density == value) return;
    state = state.withDensity(value);
    unawaited(ref.read(localPrefsProvider).write(densityKey, value.name));
  }

  /// 传 `null` 回到自适应。
  void setColumns(int? value) {
    if (state.columns == value) return;
    // 不用 copyWith：`columns ?? this.columns` 表达不了「设回 null（自适应）」，
    // 传 null 会变成"保持原值"，看起来点了没反应。
    state = LibraryDisplay(density: state.density, columns: value);
    final prefs = ref.read(localPrefsProvider);
    unawaited(
      value == null
          ? prefs.remove(columnsKey)
          : prefs.write(columnsKey, value.toString()),
    );
  }
}

@immutable
class LibraryDisplay {
  const LibraryDisplay({required this.density, this.columns});

  final LibraryDensity density;

  /// 覆盖列数；`null` = 按宽度自适应。
  final int? columns;

  /// 只能改密度。列数请走 [LibraryDisplayController.setColumns]：
  /// 这里若也接受 `int?`，传 null 会被 `??` 吃掉，无法表达「回到自适应」。
  LibraryDisplay withDensity(LibraryDensity value) =>
      LibraryDisplay(density: value, columns: columns);
}

final libraryDisplayProvider =
    NotifierProvider<LibraryDisplayController, LibraryDisplay>(
      LibraryDisplayController.new,
    );
