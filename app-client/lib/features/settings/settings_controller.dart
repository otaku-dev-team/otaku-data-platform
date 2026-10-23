import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_prefs_provider.dart';
import '../../core/storage/work_cache.dart';
import '../../core/storage/work_cache_provider.dart';

/// 主题模式。**设备级设置，不按账号分桶**。
///
/// 与浏览历史、搜索历史不同：那两样是「这台机器上的人干过什么」，换个人
/// 登录不该看见；深浅色是「这块屏幕的主人看得惯什么」，跟账号没关系。
/// 一个家庭共用的平板上，换个账号登录不该把界面刷成另一种颜色。
class ThemeModeController extends Notifier<ThemeMode> {
  static const String prefsKey = 'theme_mode';

  @override
  ThemeMode build() {
    final raw = ref.watch(localPrefsProvider).read(prefsKey);
    // 认不出来的值（旧版本写的、手改坏的）一律退回跟随系统：
    // 主题选错是「看起来奇怪」，而抛异常是「打不开」。
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => ThemeMode.system,
    );
  }

  void select(ThemeMode mode) {
    if (state == mode) return;
    state = mode;
    // 落盘不 await：界面立刻换主题，磁盘慢一拍不影响。
    unawaited(ref.read(localPrefsProvider).write(prefsKey, mode.name));
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

/// 作品离线缓存的占用。清除之后 `invalidate` 它重新统计。
///
/// 关掉自动重试：这是本机读盘，重试既不会变好，也只会在设置页上闪。
final cacheUsageProvider = FutureProvider<CacheUsage>((ref) {
  return ref.watch(workCacheProvider).usage();
}, retry: (retryCount, error) => null);

/// 清空作品离线缓存，并让设置页上的占用数字重算。
///
/// **只清作品缓存**。收藏缓存是服务端数据的副本、浏览历史只在本机、
/// 本机偏好里存着用户的选择——这三样在用户眼里都不是「缓存」，
/// 一起清掉属于「说了一套、做了一套」。
Future<void> clearWorkCache(WidgetRef ref) async {
  await ref.read(workCacheProvider).clear();
  ref.invalidate(cacheUsageProvider);
}
