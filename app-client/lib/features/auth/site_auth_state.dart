import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/storage/local_prefs.dart';

/// 站点授权票据的寿命（契约：120 秒，一次性）。
///
/// 客户端拿不到「票据什么时候颁发」——那是站点侧的事。所以这里的 120 秒是
/// **从打开浏览器起算**的保守上限，不是票据的真实到期时刻。
const Duration siteAuthTicketTtl = Duration(seconds: 120);

/// 判定「是不是肯定过期了」时多给的通融。
///
/// 从点按钮到站点真正颁发票据，中间隔着浏览器冷启动 + 站点登录页，几秒到几十秒
/// 都正常。若严格按 `打开时刻 + 120s` 判定，会在票据还剩一口气的时候就说它过期
/// ——用户被迫重走一遍授权，而他明明来得及。
///
/// 放宽 60 秒的代价：偶尔放进一个确实已过期的票据，后端会返 401，用户看到的是
/// 「授权失败，请重试」。相比提前误杀，这个代价更小：一个是无谓重试，一个是
/// 多绕一趟授权。
const Duration siteAuthExpiryGrace = Duration(seconds: 60);

/// 一次站点授权尝试：发出去的 state + 什么时候打开的授权页。
///
/// **state 为什么必须有**：站点回调是浏览器发起的，任何 App 都能注册同一个
/// scheme。不带自己生成的 state 做校验，就等于谁构造一个回调 URI 都能把用户
/// 送进登录流程（CSRF）。
@immutable
class SiteAuthAttempt {
  const SiteAuthAttempt({required this.state, required this.startedAt});

  final String state;
  final DateTime startedAt;

  /// 是否已经不可能再用了（票据必然过期）。
  bool isExpired(DateTime now) =>
      now.isAfter(startedAt.add(siteAuthTicketTtl + siteAuthExpiryGrace));

  /// 回跳带回来的 state 和本地存的是否一致。
  ///
  /// 空值一律算不匹配：空 state 说明回跳构造得不完整，不能当成「碰巧对了」。
  bool matches(String? returned) =>
      returned != null && returned.isNotEmpty && returned == state;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'state': state,
    'started_at': startedAt.toUtc().toIso8601String(),
  };

  /// 解析失败一律返回 null——「读不出来」对调用方和「没有尝试过」是同一个意思：
  /// 重新走一遍授权。整段作废而不是猜一个值继续用。
  static SiteAuthAttempt? fromJson(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final state = decoded['state'];
      final startedAt = decoded['started_at'];
      if (state is! String || state.isEmpty) return null;
      final parsed = startedAt is String ? DateTime.tryParse(startedAt) : null;
      if (parsed == null) return null;
      return SiteAuthAttempt(state: state, startedAt: parsed.toUtc());
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'SiteAuthAttempt(${state.substring(0, 4)}…, $startedAt)';
}

/// state 生成与存取。
///
/// 生成是纯随机（`Random.secure`），长度 24 字节（base64url 后 32 字符）：
/// 足够防猜测，又不至于让 URL 长得可疑。
abstract final class SiteAuthState {
  const SiteAuthState._();

  static const int _stateBytes = 24;

  static String generate({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(_stateBytes, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

/// 把「这一次授权尝试」留在本机。
///
/// **必须落盘，不能只存内存**：Android 上从系统浏览器回到 App，进程完全可能
/// 已经被回收（内存压力、用户中途切走）。state 只存内存 → 回来时对不上 →
/// 用户看到「校验失败」，而实际什么都没错。这是实现期最容易漏的一条。
class SiteAuthStateStore {
  SiteAuthStateStore(this._prefs);

  final LocalPrefs _prefs;

  static const String prefsKey = 'site_auth_state';

  Future<void> save(SiteAuthAttempt attempt) =>
      _prefs.write(prefsKey, jsonEncode(attempt.toJson()));

  SiteAuthAttempt? read() => SiteAuthAttempt.fromJson(_prefs.read(prefsKey));

  Future<void> clear() => _prefs.remove(prefsKey);
}
