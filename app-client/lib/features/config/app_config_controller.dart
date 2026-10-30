import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/dio_client.dart';
import '../../data/datasources/app_config_data_source.dart';
import '../../data/datasources/app_config_mock_data_source.dart';
import '../../data/datasources/app_config_remote_data_source.dart';
import '../../data/models/remote_config.dart';
import 'app_config_store.dart';

/// 运行期配置的读接口。
///
/// 与更新检查不同，配置失败**不打扰用户**：拉不到就用缓存 / 空配置，
/// 因为它的内容（公告、开关）本来就是可选装饰。
final appConfigDataSourceProvider = Provider<AppConfigDataSource>((ref) {
  if (AppConfig.useMock) {
    return const MockAppConfigDataSource();
  }
  return RemoteAppConfigDataSource(ref.watch(dioProvider));
});

@immutable
class AppConfigState {
  const AppConfigState({
    this.config = RemoteConfig.empty,
    this.noticeDismissed = false,
  });

  final RemoteConfig config;

  /// 用户是否已经关掉了**当前这一版**公告（换版本会重新出现，见 `AppConfigStore`）。
  final bool noticeDismissed;

  RemoteNotice? get notice => config.notice;

  bool get showNotice => !noticeDismissed && (notice?.enabled ?? false);

  AppConfigState copyWith({RemoteConfig? config, bool? noticeDismissed}) =>
      AppConfigState(
        config: config ?? this.config,
        noticeDismissed: noticeDismissed ?? this.noticeDismissed,
      );
}

/// 启动时先给缓存（同步，第一帧就能用），随后由 `AppConfigBootstrap` 触发一次刷新。
///
/// **不在 build 里发请求**：provider 的 build 会在任意 widget 首次 watch 时执行，
/// 那里发网络请求会让"什么时候打请求"变得不可预测，测试里还会留下未完成的异步任务。
class AppConfigController extends Notifier<AppConfigState> {
  @override
  AppConfigState build() {
    final store = ref.watch(appConfigStoreProvider);
    final cached = store.read();
    return AppConfigState(
      config: cached,
      noticeDismissed: store.isNoticeDismissed(cached.version),
    );
  }

  Future<void> refresh() async {
    final fresh = await ref.read(appConfigDataSourceProvider).fetch();

    // 拉失败返回的是空壳（version 0）：保留现有状态，别把用户的公告/开关清零
    if (fresh.version == 0) {
      return;
    }
    if (fresh.version == state.config.version) {
      return;
    }

    final store = ref.read(appConfigStoreProvider);
    state = AppConfigState(
      config: fresh,
      noticeDismissed: store.isNoticeDismissed(fresh.version),
    );
    await store.write(fresh);
  }

  Future<void> dismissNotice() async {
    state = state.copyWith(noticeDismissed: true);
    await ref.read(appConfigStoreProvider).dismissNotice(state.config.version);
  }
}

final appConfigProvider = NotifierProvider<AppConfigController, AppConfigState>(
  AppConfigController.new,
);
