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

/// 外观实验开关：系统取色（Material You）与玻璃质感。
///
/// 两个都是**设备级、可关**的实验特性，默认全关——关掉就是现有品牌蓝 +
/// 实心卡片，和发布版一模一样。做成开关而不是直接替换，是因为：
/// 系统取色会把主色换成壁纸色（品牌蓝消失），玻璃质感在低端机上更费电，
/// 两者都该由用户自己决定要不要。
@immutable
class AppearanceStyle {
  const AppearanceStyle({this.dynamicColor = false, this.glass = false});

  /// 用系统壁纸配色（Android 12+）。其他平台没有这个能力，取值恒为 null。
  final bool dynamicColor;

  /// 半透明 + 模糊的层叠质感。
  final bool glass;

  AppearanceStyle copyWith({bool? dynamicColor, bool? glass}) =>
      AppearanceStyle(
        dynamicColor: dynamicColor ?? this.dynamicColor,
        glass: glass ?? this.glass,
      );
}

class AppearanceController extends Notifier<AppearanceStyle> {
  static const String dynamicKey = 'appearance_dynamic_color';
  static const String glassKey = 'appearance_glass';

  @override
  AppearanceStyle build() {
    final prefs = ref.watch(localPrefsProvider);
    // 只认明确的 'true'：缺省、坏值都按关闭处理——实验特性不该自己打开。
    return AppearanceStyle(
      dynamicColor: prefs.read(dynamicKey) == 'true',
      glass: prefs.read(glassKey) == 'true',
    );
  }

  void setDynamicColor(bool value) {
    if (state.dynamicColor == value) return;
    state = state.copyWith(dynamicColor: value);
    unawaited(
      ref.read(localPrefsProvider).write(dynamicKey, value.toString()),
    );
  }

  void setGlass(bool value) {
    if (state.glass == value) return;
    state = state.copyWith(glass: value);
    unawaited(ref.read(localPrefsProvider).write(glassKey, value.toString()));
  }
}

final appearanceProvider =
    NotifierProvider<AppearanceController, AppearanceStyle>(
      AppearanceController.new,
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
