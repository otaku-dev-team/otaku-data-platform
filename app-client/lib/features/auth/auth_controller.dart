import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/session_expiry.dart';
import '../../core/storage/collection_cache_provider.dart';
import '../../data/models/account_user.dart';
import '../../data/repositories/auth_repository.dart';

enum AuthStatus {
  /// 还在读本地令牌。此时既不能显示「已登录」，也不该闪一下登录页。
  checking,
  signedOut,
  signedIn,
}

@immutable
class AuthState {
  const AuthState({
    required this.status,
    this.user,
    this.submitting = false,
    this.error,
  });

  final AuthStatus status;
  final AccountUser? user;

  /// 登录/退出请求进行中。按钮据此禁用，避免重复提交。
  final bool submitting;

  /// 上一次登录失败的原因。**只在登录页展示，不影响已登录状态**。
  final ApiException? error;

  bool get isSignedIn => status == AuthStatus.signedIn && user != null;

  AuthState copyWith({
    AuthStatus? status,
    AccountUser? user,
    bool? submitting,
    ApiException? error,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      submitting: submitting ?? this.submitting,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  String toString() => 'AuthState($status, user=$user, submitting=$submitting)';
}

/// 会话状态机。
///
/// 三态而不是「user 可空」：`checking` 必须能和「确定未登录」区分开，
/// 否则冷启动时会先闪一下登录页再跳回列表。
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    // 401 的统一落点：网络层只发信号，清会话在这里做（C6/C7）。
    ref.listen(sessionExpiryProvider, (previous, next) {
      if (previous == null || next <= previous) return;
      _handleSessionExpired();
    });

    // Notifier.build 不能是 async，先给出 checking，再在微任务里恢复会话。
    Future<void>.microtask(_restore);
    return const AuthState(status: AuthStatus.checking);
  }

  /// 令牌已被服务端判定无效：清本地令牌、回未登录。
  ///
  /// 不调 `logout`——那会再拿一个 401，还会把「本机主动退出」和「被动失效」混在一起。
  /// 退出登录 / 会话失效时清掉这个人的收藏缓存。
  ///
  /// 缓存按 `user_id` 分键，下一个人其实**读不到**——清它不是为了防串号，
  /// 而是不该把私人数据留在磁盘上等人来捡。
  ///
  /// 清不掉也不能挡住登出：缓存是附属品，登出是主流程。
  Future<void> _clearCollectionCache() async {
    final userId = state.user?.userId;
    if (userId == null) return;
    try {
      await ref.read(collectionCacheProvider).clearUser(userId);
    } catch (_) {
      // 忽略，理由见上。
    }
  }

  Future<void> _handleSessionExpired() async {
    if (state.status == AuthStatus.signedOut) return;
    await _clearCollectionCache();
    await ref.read(authRepositoryProvider).clearSession();
    if (!ref.mounted) return;
    state = const AuthState(status: AuthStatus.signedOut);
  }

  Future<void> _restore() async {
    try {
      final user = await ref.read(authRepositoryProvider).restoreSession();
      if (!ref.mounted) return;
      state = user == null
          ? const AuthState(status: AuthStatus.signedOut)
          : AuthState(status: AuthStatus.signedIn, user: user);
    } on Object {
      if (!ref.mounted) return;
      // 断网等情况：这次按未登录处理，但令牌没被清（见 AuthRepository.restoreSession）。
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  /// 返回是否登录成功，方便页面决定要不要 `context.go`。
  ///
  /// 失败**不抛异常**：登录失败是正常分支，页面读 [AuthState.error] 展示即可，
  /// 抛出去会让调用方多写一层 try/await 判断。
  Future<bool> login(String username, String password) async {
    if (state.submitting) return false;

    state = state.copyWith(submitting: true, clearError: true);
    try {
      final user = await ref
          .read(authRepositoryProvider)
          .login(username: username, password: password);
      if (!ref.mounted) return false;
      state = AuthState(status: AuthStatus.signedIn, user: user);
      return true;
    } on Object catch (raw) {
      if (!ref.mounted) return false;
      state = AuthState(
        status: AuthStatus.signedOut,
        error: ApiException.fromAny(raw),
      );
      return false;
    }
  }

  /// 退出登录：只结束当前会话，桌面端不受影响（C9）。
  ///
  /// 个人数据的清理不在这里做——`CollectionController` 监听当前 `user_id`，
  /// 用户一变就会重新查询，天然满足「切账号不残留」（C6）。
  Future<void> logout() async {
    state = state.copyWith(submitting: true, clearError: true);
    await _clearCollectionCache();
    await ref.read(authRepositoryProvider).logout();
    if (!ref.mounted) return;
    state = const AuthState(status: AuthStatus.signedOut);
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
