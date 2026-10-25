import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/features/auth/site_auth_state.dart';

void main() {
  group('SiteAuthAttempt', () {
    test('生成的 state 够长且每次不同', () {
      final a = SiteAuthState.generate();
      final b = SiteAuthState.generate();
      expect(a.length, greaterThanOrEqualTo(32));
      expect(a, isNot(b));
      // base64url：不含会污染 URL 的字符
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    });

    test('注入随机源可复现——否则「随机」没法测', () {
      final a = SiteAuthState.generate(random: _FixedRandom());
      final b = SiteAuthState.generate(random: _FixedRandom());
      expect(a, b);
    });

    test('matches：空值与不一致都算不匹配', () {
      final attempt = SiteAuthAttempt(
        state: 'abc',
        startedAt: DateTime.utc(2026, 10, 25, 12),
      );
      expect(attempt.matches('abc'), isTrue);
      expect(attempt.matches('xyz'), isFalse);
      expect(attempt.matches(null), isFalse);
      expect(attempt.matches(''), isFalse);
    });

    test('过期判定：票据寿命 + 通融窗内不算过期', () {
      final started = DateTime.utc(2026, 10, 25, 12, 0);
      final attempt = SiteAuthAttempt(state: 'abc', startedAt: started);

      // 打开后 100 秒：票据可能刚颁发，绝不能说过期
      expect(attempt.isExpired(started.add(const Duration(seconds: 100))), isFalse);
      // 120 + 60 = 180 秒：通融窗用完
      expect(attempt.isExpired(started.add(const Duration(seconds: 179))), isFalse);
      expect(attempt.isExpired(started.add(const Duration(seconds: 181))), isTrue);
    });

    test('JSON 往返保留 state 与时刻', () {
      final restored = SiteAuthAttempt.fromJson(
        '{"state":"state-value","started_at":"2026-10-25T12:00:00.000Z"}',
      );
      expect(restored, isNotNull);
      expect(restored!.state, 'state-value');
      expect(restored.startedAt, DateTime.utc(2026, 10, 25, 12, 0));
    });

    test('坏数据一律按「没有尝试」处理，不抛异常', () {
      expect(SiteAuthAttempt.fromJson(null), isNull);
      expect(SiteAuthAttempt.fromJson(''), isNull);
      expect(SiteAuthAttempt.fromJson('不是 JSON'), isNull);
      expect(SiteAuthAttempt.fromJson('[]'), isNull);
      expect(SiteAuthAttempt.fromJson('{"state":""}'), isNull);
      expect(SiteAuthAttempt.fromJson('{"state":"a"}'), isNull, reason: '缺时刻');
      expect(SiteAuthAttempt.fromJson('{"started_at":"2026-10-25T12:00:00.000Z"}'), isNull);
    });
  });

  group('SiteAuthStateStore', () {
    late InMemoryLocalPrefs prefs;
    late SiteAuthStateStore store;

    setUp(() {
      prefs = InMemoryLocalPrefs();
      store = SiteAuthStateStore(prefs);
    });

    test('写入后能读回，clear 之后读不到', () async {
      expect(store.read(), isNull);
      await store.save(
        SiteAuthAttempt(
          state: 's1',
          startedAt: DateTime.utc(2026, 10, 25, 12),
        ),
      );
      expect(store.read()?.state, 's1');
      await store.clear();
      expect(store.read(), isNull);
    });

    test('读的是本地偏好里的同一个键（迁移/排查时找得到）', () async {
      await store.save(
        SiteAuthAttempt(
          state: 's1',
          startedAt: DateTime.utc(2026, 10, 25, 12),
        ),
      );
      expect(prefs.read(SiteAuthStateStore.prefsKey), isNotNull);
    });

    test('磁盘上被写坏时按「没有尝试」处理', () async {
      await prefs.write(SiteAuthStateStore.prefsKey, '{ 坏数据');
      expect(store.read(), isNull);
    });
  });
}

/// 恒定随机源：让「每次生成都不同」的反向断言可写。
class _FixedRandom implements Random {
  final _r = _Lcg(42);

  @override
  int nextInt(int max) => _r.next(max);

  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 0.5;
}

class _Lcg {
  _Lcg(this._seed);

  int _seed;

  int next(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }
}
