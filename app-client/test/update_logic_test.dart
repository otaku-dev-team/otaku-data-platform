import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/features/update/update_controller.dart';
import 'package:otaku_app/features/update/update_manifest.dart';
import 'package:otaku_app/features/update/update_service.dart';
import 'package:otaku_app/features/update/update_store.dart';

const _manifest = UpdateManifest(
  versionCode: 2,
  versionName: '1.0.1',
  downloadUrl: 'https://example.com/otaku-1.0.1.apk',
  changelog: '修复了一些问题\n优化了加载速度',
);

class _FakeService extends UpdateService {
  _FakeService(this.manifest)
    : super(manifestUrl: 'http://test.invalid/downloads/latest.json');

  final UpdateManifest? manifest;

  @override
  Future<UpdateManifest?> fetchLatest() async => manifest;
}

void main() {
  group('UpdateManifest', () {
    test('解析 camelCase / snake_case / 数组 changelog', () {
      final camel = UpdateManifest.tryParse({
        'versionCode': 3,
        'versionName': '1.2.0',
        'downloadUrl': 'https://example.com/a.apk',
        'changelog': ['a', 'b'],
        'minSupportedVersionCode': 2,
      });
      expect(camel, isNotNull);
      expect(camel!.versionCode, 3);
      expect(camel.changelog, 'a\nb');
      expect(camel.isForced, isTrue);

      final snake = UpdateManifest.tryParse({
        'version_code': '4',
        'version_name': '1.3.0',
        'download_url': 'http://example.com/a.apk',
        'min_supported_version_code': '1',
      });
      expect(snake?.versionCode, 4);
      expect(snake?.versionName, '1.3.0');
      expect(snake?.isForced, isFalse);
    });

    test('关键字段缺失 / 非 http(s) 下载地址 → null', () {
      expect(
        UpdateManifest.tryParse({
          'versionCode': 2,
          'versionName': '1.0.1',
        }),
        isNull,
      );
      expect(
        UpdateManifest.tryParse({
          'versionCode': 2,
          'versionName': '1.0.1',
          'downloadUrl': 'file:///tmp/a.apk',
        }),
        isNull,
      );
      expect(UpdateManifest.tryParse('not a map'), isNull);
    });
  });

  group('UpdateIgnoreStore', () {
    test('忽略后同一版本不再自动提示；手动检查仍能看到', () async {
      final prefs = InMemoryLocalPrefs();
      final store = UpdateIgnoreStore(prefs);
      expect(store.isIgnored(_manifest), isFalse);

      await store.ignore(_manifest);
      expect(store.isIgnored(_manifest), isTrue);

      // 换成另一个更新的版本，旧忽略不生效。
      expect(
        store.isIgnored(
          const UpdateManifest(
            versionCode: 3,
            versionName: '1.1.0',
            downloadUrl: 'https://example.com/b.apk',
          ),
        ),
        isFalse,
      );
    });

    test('App 版本变了之后，旧忽略标记作废', () async {
      final prefs = InMemoryLocalPrefs();
      await prefs.write('update.ignored_version_code', '2');
      await prefs.write('update.ignored_on_app_code', '999');
      final store = UpdateIgnoreStore(prefs);

      expect(
        store.isIgnored(_manifest),
        isFalse,
        reason: '忽略只对当时那个 App 版本有效',
      );
    });
  });

  group('UpdateController', () {
    ProviderContainer create(UpdateManifest? manifest, InMemoryLocalPrefs prefs) {
      final container = ProviderContainer(
        overrides: [
          localPrefsProvider.overrideWithValue(prefs),
          updateServiceProvider.overrideWithValue(_FakeService(manifest)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('发现新版本 → available；没有更新 → idle', () async {
      final withUpdate = create(_manifest, InMemoryLocalPrefs());
      final found = await withUpdate
          .read(updateControllerProvider.notifier)
          .check();
      expect(found?.versionCode, 2);
      expect(withUpdate.read(updateControllerProvider).phase, UpdatePhase.available);

      final noUpdate = create(
        const UpdateManifest(
          versionCode: 1,
          versionName: '1.0.0',
          downloadUrl: 'https://example.com/same.apk',
        ),
        InMemoryLocalPrefs(),
      );
      expect(
        await noUpdate.read(updateControllerProvider.notifier).check(),
        isNull,
      );
      expect(noUpdate.read(updateControllerProvider).phase, UpdatePhase.idle);
    });

    test('自动检查尊重忽略；手动检查绕过忽略', () async {
      final prefs = InMemoryLocalPrefs();
      await UpdateIgnoreStore(prefs).ignore(_manifest);
      final container = create(_manifest, prefs);
      final controller = container.read(updateControllerProvider.notifier);

      expect(await controller.check(), isNull, reason: '自动检查应被忽略挡住');
      expect(
        await controller.check(manual: true),
        isNotNull,
        reason: '用户主动点检查，应该能看到',
      );
    });
  });

  group('UpdateState 进度推算', () {
    test('速度未知时不算剩余时间', () {
      const state = UpdateState(
        phase: UpdatePhase.downloading,
        progress: 0.3,
        receivedBytes: 3000,
        totalBytes: 10000,
      );

      expect(state.remaining, isNull);
    });

    test('按当前速度算剩余时间', () {
      const state = UpdateState(
        phase: UpdatePhase.downloading,
        progress: 0.5,
        receivedBytes: 500,
        totalBytes: 1000,
        bytesPerSecond: 100,
      );

      expect(state.remaining, const Duration(seconds: 5));
    });

    test('已下完 / 超额时不给负数剩余', () {
      const state = UpdateState(
        phase: UpdatePhase.downloading,
        progress: 1,
        receivedBytes: 1000,
        totalBytes: 1000,
        bytesPerSecond: 100,
      );

      expect(state.remaining, isNull);
    });

    test('服务器没给 Content-Length 时也不炸', () {
      const state = UpdateState(
        phase: UpdatePhase.downloading,
        receivedBytes: 4096,
        bytesPerSecond: 2048,
      );

      expect(state.remaining, isNull);
    });
  });
}
