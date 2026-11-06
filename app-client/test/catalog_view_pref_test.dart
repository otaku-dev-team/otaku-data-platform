import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/features/contents/contents_page.dart';

/// 作品库的网格 / 列表切换要**跨启动记住**。
///
/// 之前只在会话内记，注释给的理由是「项目里还没有通用的本地偏好存储」——
/// 那个前提早就不成立了。结果：每次冷启动都回到网格，用户得重新点一次。
void main() {
  ProviderContainer makeContainer(InMemoryLocalPrefs prefs) {
    final container = ProviderContainer(
      overrides: [localPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('没存过时默认网格', () {
    final container = makeContainer(InMemoryLocalPrefs());

    expect(container.read(catalogViewProvider), CatalogView.grid);
  });

  test('存过「列表」：下次启动直接是列表', () {
    final container = makeContainer(
      InMemoryLocalPrefs(<String, String>{
        CatalogViewController.storageKey: CatalogView.list.name,
      }),
    );

    expect(container.read(catalogViewProvider), CatalogView.list);
  });

  test('切换后写进本机偏好，重启仍生效', () {
    final prefs = InMemoryLocalPrefs();
    final container = makeContainer(prefs);

    container.read(catalogViewProvider.notifier).select(CatalogView.list);

    expect(container.read(catalogViewProvider), CatalogView.list);
    expect(prefs.read(CatalogViewController.storageKey), 'list');

    // 换一个容器模拟「重启」：同一个 prefs，读出来还是列表。
    final restarted = makeContainer(prefs);
    expect(restarted.read(catalogViewProvider), CatalogView.list);
  });

  test('坏值回落网格：一个偏好坏了不该让页面打不开', () {
    final container = makeContainer(
      InMemoryLocalPrefs(<String, String>{
        CatalogViewController.storageKey: 'grid_v2',
      }),
    );

    expect(container.read(catalogViewProvider), CatalogView.grid);
  });
}
