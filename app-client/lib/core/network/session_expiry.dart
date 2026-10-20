import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「会话已失效」的单向广播。
///
/// 认证层和网络层不能互相依赖：`AuthController` 要用 dio，dio 的 401 拦截又要通知
/// 会话失效。所以这里放一个只带计数的信号：网络层只负责 `bump()`，
/// 认证层监听它并清会话。`core` 因此不必认识 `features`。
///
/// 用计数器而不是布尔值：连续两次 401 也要能被监听者看到（布尔会因去重而丢事件）。
class SessionExpiryNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// 只在收到 `401 UNAUTHORIZED` 时调用。
  /// `401 INVALID_CREDENTIALS`（登录密码错）**不能**走这里，否则会把已有会话踢掉。
  void notifyExpired() => state = state + 1;
}

final sessionExpiryProvider = NotifierProvider<SessionExpiryNotifier, int>(
  SessionExpiryNotifier.new,
);
