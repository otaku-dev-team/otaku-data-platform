import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/core/telemetry/install_id.dart';
import 'package:otaku_app/core/telemetry/usage_ping.dart';

/// 启动心跳的行为约束。
///
/// 为什么值得一个专门的测试文件：这是**唯一**会把「用户在用这个 App」这件事
/// 告诉服务端的代码。它出错的方式不是崩溃，而是安静地少发/多发——
/// 少发会让日活偏低、多发会让日活虚高，两种都不会有人报 bug。
///
/// 所以这里钉住的是节流边界、失败不重试、坏 id 自愈这三件事，
/// 而不是「函数能跑通」。
void main() {
  group('InstallId', () {
    test('生成的是合法 UUID v4，且版本位/变体位正确', () {
      for (var i = 0; i < 50; i++) {
        final id = InstallId.generate();
        expect(id, hasLength(36));
        expect(InstallId.isValid(id), isTrue, reason: '第 $i 个：$id');
        // 版本位必须是 4、变体位必须是 8/9/a/b——服务端按这两条校验，
        // 少改一处就会整批 400（而且是静默的，客户端不看响应）
        expect(id[14], '4');
        expect('89ab', contains(id[19]));
      }
    });

    test('同一个随机源下不重复（这不是随机性证明，只防"写死返回常量"）', () {
      final ids = List.generate(200, (_) => InstallId.generate());
      expect(ids.toSet(), hasLength(200));
    });

    test('形状校验：拒绝全大写、拒绝 v1、拒绝缺位', () {
      expect(InstallId.isValid(null), isFalse);
      expect(InstallId.isValid(''), isFalse);
      // 大写不算：本机存的值一律由 generate() 产出，出现大写说明被手工改过
      expect(InstallId.isValid('3F2B8C1A-9D4E-4F6B-8A2C-1E5D7B9C0A3F'), isFalse);
      // 版本位不对（v1）
      expect(InstallId.isValid('3f2b8c1a-9d4e-1f6b-8a2c-1e5d7b9c0a3f'), isFalse);
      // 少一位
      expect(InstallId.isValid('3f2b8c1a-9d4e-4f6b-8a2c-1e5d7b9c0a3'), isFalse);
    });
  });

  group('UsagePing', () {
    late _RecordingAdapter adapter;
    late Dio dio;
    late InMemoryLocalPrefs prefs;
    late DateTime now;

    setUp(() {
      adapter = _RecordingAdapter();
      dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
        ..httpClientAdapter = adapter;
      prefs = InMemoryLocalPrefs();
      now = DateTime(2026, 10, 31, 3, 20);
    });

    UsagePing build({bool? enabled, int? status}) {
      adapter.status = status ?? 200;
      return UsagePing(
        prefs,
        dio,
        clock: () => now,
        platform: 'android',
        enabled: enabled ?? true,
      );
    }

    test('首次启动：发一次，带上合法 install_id / 版本 / 平台', () async {
      final ping = build();

      expect(await ping.pingIfDue(), isTrue);

      expect(adapter.paths, ['/api/client/ping']);
      final body = adapter.bodies.single;
      expect(InstallId.isValid(body['install_id'] as String?), isTrue);
      expect(body['platform'], 'android');
      expect(body['app_version'], isNotNull);
      // 落盘了：下次启动要复用同一个 id，否则每启动一次就是"一台新设备"
      expect(prefs.read(UsagePing.installIdKey), body['install_id']);
    });

    test('12 小时内再启动：不发；过了 12 小时：发，且是同一个 install_id', () async {
      final first = build();
      await first.pingIfDue();
      final id = prefs.read(UsagePing.installIdKey);

      // 过了 11 小时——差一小时，仍然不发（边界取 >=，不是 >）
      now = now.add(const Duration(hours: 11));
      expect(await build().pingIfDue(), isFalse);
      expect(adapter.bodies, hasLength(1));

      // 正好 12 小时：发（节流边界是闭区间，写死在这里防止有人改成 13 小时）
      now = now.add(const Duration(hours: 1));
      expect(await build().pingIfDue(), isTrue);
      expect(adapter.bodies, hasLength(2));
      expect(adapter.bodies.last['install_id'], id);
    });

    test('请求失败：不抛、不重试，且时间已落盘（弱网用户不会被反复打）', () async {
      final ping = build(status: 500);

      // 关键：这里必须是 false 而不是抛异常——调用方在 post-frame 回调里，
      // 抛出去会变成未捕获异常，flutter 测试里直接判红
      expect(await ping.pingIfDue(), isFalse);
      expect(adapter.paths, hasLength(1));

      // 失败的这次也记了时间：紧接着再调一次不会立刻重发
      now = now.add(const Duration(minutes: 1));
      expect(await build().pingIfDue(), isFalse);
      expect(adapter.paths, hasLength(1));
    });

    test('本机 id 坏掉：重新生成并写回，上报的是新的合法值', () async {
      prefs = InMemoryLocalPrefs({UsagePing.installIdKey: 'not-a-uuid'});

      expect(await build().pingIfDue(), isTrue);

      final sent = adapter.bodies.single['install_id'] as String;
      expect(InstallId.isValid(sent), isTrue);
      expect(sent, isNot('not-a-uuid'));
      expect(prefs.read(UsagePing.installIdKey), sent);
    });

    test('Mock 构建（enabled=false）：一次请求都不发', () async {
      // 这就是 AppConfig.useMock=true 时的行为；widget 测试全部跑在这个模式下
      expect(await build(enabled: false).pingIfDue(), isFalse);
      expect(adapter.paths, isEmpty);
      expect(prefs.read(UsagePing.lastPingKey), isNull);
    });

    test('时钟被回拨到"上次心跳之前"：按到点处理，不永久静音', () async {
      prefs = InMemoryLocalPrefs({
        UsagePing.installIdKey: InstallId.generate(),
        // 记的是"未来"的时间（用户改过系统时间，或上次写盘时时钟更快）
        UsagePing.lastPingKey: now
            .add(const Duration(days: 3))
            .millisecondsSinceEpoch
            .toString(),
      });

      expect(await build().pingIfDue(), isTrue);
    });
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  int status = 200;
  final List<String> paths = [];
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    bodies.add(Map<String, dynamic>.from(options.data as Map));
    return ResponseBody.fromString(
      jsonEncode({'ok': status < 400}),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
