import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/session_expiry.dart';
import '../../core/config/app_config.dart';
import '../../core/storage/collection_cache_provider.dart';
import '../../core/storage/local_prefs_provider.dart';
import '../../data/models/account_user.dart';
import '../../data/repositories/auth_repository.dart';
import 'site_auth_launcher.dart';
import 'site_auth_state.dart';
import 'site_auth_webview_launcher.dart';

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
  /// 会话恢复（读本地令牌 + 校验）完成信号。
  ///
  /// 为什么需要它：`build()` 里的恢复是异步的，而登录/授权随时可能发生。
  /// 不等它，恢复完成时会把 `signedOut` 整个盖掉正在进行的登录状态——
  /// 表现是「按钮转完圈却没登上」，而且只在冷启动后立刻登录时出现，
  /// 复测十次未必碰得到一次。
  final Completer<void> _restored = Completer<void>();

  @override
  AuthState build() {
    // 401 的统一落点：网络层只发信号，清会话在这里做（C6/C7）。
    ref.listen(sessionExpiryProvider, (previous, next) {
      if (previous == null || next <= previous) return;
      _handleSessionExpired();
    });

    // Notifier.build 不能是 async，先给出 checking，再在微任务里恢复会话。
    Future<void>.microtask(() async {
      try {
        await _restore();
      } finally {
        if (!_restored.isCompleted) _restored.complete();
      }
    });
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
    // 站点身份账号先尝试静默重走一次授权（契约 §5：authorize 对已登录用户
    // 幂等、无同意页）。平台账号不重走——它的 401 是会话/密码问题，
    // 重走授权解决不了，只会让用户多等一轮。
    if (state.user?.isSiteIdentity == true && _canSilentReauth()) {
      _lastSilentReauthAt = DateTime.now();
      await beginSiteLogin();
      // 浏览器已经打开，授权成功与否由回跳那条路决定（见 SiteAuthBootstrap）；
      // 这里不清会话——用户看起来只是「浏览器闪了一下」。
      if (ref.mounted) return;
    }
    await _clearCollectionCache();
    await ref.read(authRepositoryProvider).clearSession();
    if (!ref.mounted) return;
    state = const AuthState(status: AuthStatus.signedOut);
  }

  /// 静默重走的冷却：60 秒内不重复。
  ///
  /// 没有它，一次批量请求里的多个 401 会把用户反复弹去浏览器——那既是
  /// 骚扰，也说明链路有问题，该停下来让人看，而不是继续试。
  DateTime? _lastSilentReauthAt;

  bool _canSilentReauth() {
    final last = _lastSilentReauthAt;
    if (last == null) return true;
    return DateTime.now().difference(last) > const Duration(seconds: 60);
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
    await _restored.future;
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

  // ---- 站点授权登录（W1 账号绑定，方案见 docs/w1-login-dual-entry.md）----

  /// 开始授权：生成 state、落盘、打开系统浏览器。
  ///
  /// state 先落盘再开浏览器：浏览器回来时进程可能已被回收，那时再生成
  /// 就对不上了。
  Future<void> beginSiteLogin() async {
    await _restored.future;
    final launcher = ref.read(siteAuthLauncherProvider);
    if (!launcher.supported) return;

    state = state.copyWith(submitting: true, clearError: true);
    final store = ref.read(siteAuthStateStoreProvider);
    final attempt = SiteAuthAttempt(
      state: SiteAuthState.generate(),
      startedAt: DateTime.now().toUtc(),
    );
    try {
      await store.save(attempt);

      final opened = await launcher.openAuthorize(state: attempt.state);
      if (!ref.mounted) return;
      if (!opened) {
        // 打不开浏览器（没有可处理的 Activity 等）要说出来，别让用户
        // 盯着一个没反应的按钮猜。
        await store.clear();
        state = state.copyWith(
          submitting: false,
          error: const ApiException(
            code: ApiErrorCode.unknown,
            message: '打不开授权页面，请检查是否安装了浏览器',
          ),
        );
      }
      // opened == true 时 submitting 继续保持：等回跳（成功）或取消（见
      // [cancelSiteLogin]）来收尾。
    } on Object catch (raw) {
      // 落盘 / 推路由的意外异常也不能把按钮留在转圈状态。
      if (!ref.mounted) return;
      await store.clear();
      state = state.copyWith(
        submitting: false,
        error: ApiException.fromAny(raw),
      );
    }
  }

  /// 用户在授权页里放弃登录（返回 / 关页）时收尾。
  ///
  /// 这不是错误：用户主动退出，不该弹红色错误条，只把「正在登录」放下，
  /// 让登录按钮回到可点状态。已登录时不动——回跳成功后又取消的情况以成功为准。
  void cancelSiteLogin() {
    if (!ref.mounted) return;
    if (state.status == AuthStatus.signedIn) return;
    if (!state.submitting) return;
    state = state.copyWith(submitting: false);
  }

  /// 处理站点回跳：`com.otaku.app:/oauth2redirect?ticket=…&state=…`。
  ///
  /// 返回是否登录成功，供调用方决定跳转。
  ///
  /// 三个守卫按顺序做，**每一个失败都要说清是哪种失败**——「过期」和
  /// 「校验失败」的用户动作不同（前者重走一次就行，后者要重新点登录），
  // 合成一句「授权失败」会让用户反复重试同一个坏票据。
  Future<bool> handleSiteRedirect(Uri uri) async {
    await _restored.future;
    final store = ref.read(siteAuthStateStoreProvider);
    final attempt = store.read();
    // 不管成败，这一次尝试到此为止：票据一次性，留着只会让下一次误判。
    await store.clear();

    if (attempt == null) {
      // 没有进行中的授权。可能是别的 App 拿同一个 scheme 试探，
      // 也可能是用户清理过数据——不弹错误，安静结束。
      // 但要把「正在登录」放下：票据没了却留着 submitting，就是永远转圈。
      if (state.status != AuthStatus.signedIn) {
        state = state.copyWith(submitting: false);
      }
      return false;
    }
    if (!attempt.matches(uri.queryParameters['state'])) {
      state = state.copyWith(
        submitting: false,
        error: const ApiException(
          code: ApiErrorCode.unknown,
          message: '登录状态校验失败，请重新登录',
        ),
      );
      return false;
    }
    if (attempt.isExpired(DateTime.now())) {
      state = state.copyWith(
        submitting: false,
        error: const ApiException(
          code: ApiErrorCode.unknown,
          message: '授权已过期，请重新授权',
        ),
      );
      return false;
    }

    final ticket = uri.queryParameters['ticket'];
    if (ticket == null || ticket.isEmpty) {
      state = state.copyWith(
        submitting: false,
        error: const ApiException(
          code: ApiErrorCode.unknown,
          message: '授权没有返回票据，请重试',
        ),
      );
      return false;
    }

    // 直接走内部完成步骤：submitting 在 beginSiteLogin 里已经置上了，
    // 再走 siteLogin() 的「正在提交」检查会把这次回跳当成重复点击挡掉。
    return _completeSiteLogin(ticket);
  }

  /// 票据换会话。失败统一呈现为「授权失败，请重试」。
  ///
  /// 不区分过期/被用过/secret 错：那三者的用户动作完全一样，而区分需要
  /// 平台后端细分错误码（#147 待确认，见方案 §5）。
  Future<bool> siteLogin(String ticket) async {
    await _restored.future;
    if (state.submitting) return false;
    return _completeSiteLogin(ticket);
  }

  Future<bool> _completeSiteLogin(String ticket) async {
    state = state.copyWith(submitting: true, clearError: true);
    try {
      final user = await ref.read(authRepositoryProvider).siteLogin(ticket);
      if (!ref.mounted) return false;
      state = AuthState(status: AuthStatus.signedIn, user: user);
      return true;
    } on Object catch (raw) {
      if (!ref.mounted) return false;
      state = AuthState(
        status: AuthStatus.signedOut,
        error: ApiException.fromAny(_siteLoginError(raw)),
      );
      return false;
    }
  }

  /// 站点票据换会话的失败分档。
  ///
  /// 为什么要分：契约 §1.1 给三类失败规定了**不同的用户动作**，混成一句
  /// 「授权失败，请重试」会让人去做一件必然失败的事。
  ///
  /// - **401**（后端实测返 `INVALID_CREDENTIALS`，见下方判据）→ 票据过期 /
  ///   被用过 / 平台侧 secret 错，**引导重新授权**。文案必须是「重新授权」
  ///   而不是「重试」：票据是一次性的，重试＝拿同一张票再发一次，必然再失败，
  ///   只有重走授权才拿得到新票。这正是契约那句「不要静默重试」的意思。
  /// - **503** `SITE_UNAVAILABLE` → 站点侧不可用，**不要**引导重走授权，
  ///   交给 [ApiErrorCode.siteUnavailable] 自己的文案（只说稍后再试）。
  /// - **403** `USER_DISABLED` → 账号被禁用，重做几次都一样，停在「已禁用」。
  ///
  /// ⚠️ 判据里 `unauthorized` 不能删：那是**旧实现的码**，也是本文件历史注释
  /// 写的码。后端实际返 `INVALID_CREDENTIALS`（2026-10-29 对生产实测确认），
  /// 只认其中一个，另一个就会整档失效——而失效的表现是测试照绿、真机错文案。
  static Object _siteLoginError(Object raw) {
    if (raw is! ApiException) return raw;
    return switch (raw.code) {
      ApiErrorCode.invalidCredentials || ApiErrorCode.unauthorized =>
        const ApiException(code: ApiErrorCode.unknown, message: '授权已失效，请重新授权'),
      _ => raw,
    };
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// 站点授权的「打开授权页」能力。
///
/// - Mock：假实现，不真开授权页，桌面走查与测试能跑通整条授权链；
/// - 生产：App 内 WebView（Issue #238 方案 A，注册与授权同域，见
///   [`SiteAuthWebViewLauncher`](site_auth_webview_launcher.dart)）。
///   平台没有 WebView 实现（Windows 桌面）或构建期没注入 `SITE_BASE_URL` 时，
///   它自己的 `supported` 为 false，登录页据此**隐藏**入口而不是置灰。
final siteAuthLauncherProvider = Provider<SiteAuthLauncher>((ref) {
  if (AppConfig.useMock) return MockSiteAuthLauncher();
  return WebViewSiteAuthLauncher(ref);
});

/// 「这一次授权尝试」的本机存储。
///
/// 必须落在盘上：从系统浏览器回来时进程可能已被回收（方案 §2.2）。
final siteAuthStateStoreProvider = Provider<SiteAuthStateStore>((ref) {
  return SiteAuthStateStore(ref.watch(localPrefsProvider));
});
