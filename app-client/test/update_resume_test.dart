import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/features/update/update_controller.dart';
import 'package:otaku_app/features/update/update_installer.dart';
import 'package:otaku_app/features/update/update_manifest.dart';
import 'package:otaku_app/features/update/update_service.dart';

/// 用本地 HTTP 服务器验证断点续传。
///
/// 为什么要起真服务器而不是 mock dio：续传的关键事实是「发出的请求里到底
/// 有没有 `Range`」和「追加写之后文件内容对不对」，两者都只有真跑一遍
/// socket 才能证明。mock 掉层面只会测到自己的假设。
class _Server {
  _Server(this.supportsRange, {this.chunkDelay});

  final bool supportsRange;

  /// 每 4KB 停顿多久。给「取消」用例用：loopback 太快，不减速的话
  /// 还没来得及取消就已经下完了。
  final Duration? chunkDelay;

  late HttpServer _server;
  final List<String?> receivedRanges = [];

  String get url => 'http://127.0.0.1:${_server.port}/app.apk';

  Future<void> start(Uint8List body) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      receivedRanges.add(range);

      var start = 0;
      if (supportsRange && range != null && range.startsWith('bytes=')) {
        final spec = range.substring('bytes='.length);
        final dash = spec.indexOf('-');
        start = int.tryParse(spec.substring(0, dash)) ?? 0;
      }

      final slice = body.sublist(start);
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${body.length - 1}/${body.length}',
        );
      }
      request.response.headers.contentLength = slice.length;

      const chunk = 4096;
      for (var offset = 0; offset < slice.length; offset += chunk) {
        final end = (offset + chunk).clamp(0, slice.length);
        request.response.add(slice.sublist(offset, end));
        await request.response.flush();
        final delay = chunkDelay;
        if (delay != null) await Future<void>.delayed(delay);
      }
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller(this.path);

  final String path;

  @override
  Future<String> prepareDownloadPath(int versionCode) async => path;

  @override
  Future<InstallResult> install(String filePath) async => InstallResult.unsupported;
}

class _FakeService extends UpdateService {
  _FakeService(this.manifest)
    : super(manifestUrl: 'http://test.invalid/downloads/latest.json');

  final UpdateManifest? manifest;

  @override
  Future<UpdateManifest?> fetchLatest() async => manifest;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('otaku_update_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 200KB 的可辨识内容（每个字节都是 i % 251，避免压缩/对齐带来的巧合）。
  final body = Uint8List.fromList(
    List<int>.generate(200 * 1024, (i) => i % 251),
  );
  final digest = sha256.convert(body).toString();

  Future<ProviderContainer> containerFor(
    String url,
    String targetPath, {
    String? sha,
  }) async {
    final manifest = UpdateManifest(
      versionCode: 99,
      versionName: '9.9.9',
      downloadUrl: url,
      sha256: sha ?? digest,
    );
    final container = ProviderContainer(
      overrides: [
        localPrefsProvider.overrideWithValue(InMemoryLocalPrefs()),
        updateServiceProvider.overrideWithValue(_FakeService(manifest)),
        updateInstallerProvider.overrideWithValue(
          _FakeInstaller(targetPath),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(updateControllerProvider.notifier).check();
    return container;
  }

  test('有 .part 残片时带 Range 续传，最终文件完整且校验通过', () async {
    final server = _Server(true);
    await server.start(body);
    addTearDown(server.stop);

    final target = '${tmp.path}/update.apk';
    const already = 50 * 1024;
    await File('$target.part').writeAsBytes(body.sublist(0, already));

    final container = await containerFor(server.url, target);
    final ok = await container.read(updateControllerProvider.notifier).download();

    expect(ok, isTrue);
    expect(
      server.receivedRanges,
      ['bytes=$already-'],
      reason: '第二段应该只请求剩下的部分，而不是从头再下一遍',
    );

    final file = File(target);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), body);
    expect(
      await File('$target.part').exists(),
      isFalse,
      reason: '下完要改名，不能留着 .part',
    );
  });

  test('服务器不认 Range（回 200 全量）时作废重下，不产生重复内容', () async {
    final server = _Server(false);
    await server.start(body);
    addTearDown(server.stop);

    final target = '${tmp.path}/update.apk';
    await File('$target.part').writeAsBytes(body.sublist(0, 50 * 1024));

    final container = await containerFor(server.url, target);
    final ok = await container.read(updateControllerProvider.notifier).download();

    expect(ok, isTrue, reason: '应当自动纠正后成功，而不是把错误内容当成品');
    expect(
      server.receivedRanges.length,
      2,
      reason: '第一次追加后发现是 200，作废重来一次',
    );
    expect(await File(target).readAsBytes(), body);
  });

  test('取消下载保留 .part，下次可续传', () async {
    // 每个 4KB 停 15ms：200KB 要下三秒多，取消一定落在中途。
    final server = _Server(true, chunkDelay: const Duration(milliseconds: 15));
    await server.start(body);
    addTearDown(server.stop);

    final target = '${tmp.path}/update.apk';
    final container = await containerFor(server.url, target);
    final notifier = container.read(updateControllerProvider.notifier);

    final future = notifier.download();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    notifier.cancelDownload();
    await future;

    final part = File('$target.part');
    expect(
      await part.exists(),
      isTrue,
      reason: '取消不该把已下的部分删掉——那是下次续传的本钱',
    );
    expect(await File(target).exists(), isFalse);

    // 再下一次：应当从残片的长度接着要，而不是从头来。
    server.receivedRanges.clear();
    final resumed = await notifier.download();
    expect(resumed, isTrue);
    expect(server.receivedRanges.single, startsWith('bytes='));
    expect(server.receivedRanges.single, isNot('bytes=0-'));
    expect(await File(target).readAsBytes(), body);
  });
}
