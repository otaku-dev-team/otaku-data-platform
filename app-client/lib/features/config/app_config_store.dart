import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_prefs.dart';
import '../../core/storage/local_prefs_provider.dart';
import '../../data/models/remote_config.dart';

/// 配置的本机缓存（`LocalPrefs` 里两个键）。
///
/// 为什么要缓存：拉配置失败、或用户没网时，公告/开关应该退回**上一次的**状态，
/// 而不是突然全空——「昨天还在的公告今天莫名其妙没了」比不显示更让人困惑。
///
/// 为什么关公告要记版本：只记一个布尔的话，运营改了文案（新版本）也再不会出现，
/// 等于公告功能对老用户永久失效。记「关掉的是哪一版」，新版本自然重新出现。
class AppConfigStore {
  AppConfigStore(this._prefs);

  final LocalPrefs _prefs;

  static const String configKey = 'app_config_json';
  static const String noticeDismissedKey =
      'app_config_notice_dismissed_version';

  RemoteConfig read() {
    final raw = _prefs.read(configKey);
    if (raw == null || raw.isEmpty) {
      return RemoteConfig.empty;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return RemoteConfig.empty;
      }
      return RemoteConfig.fromJson(decoded);
    } catch (_) {
      // 坏缓存按"没有缓存"处理：配置读不出来不该让 App 起不来
      return RemoteConfig.empty;
    }
  }

  Future<void> write(RemoteConfig config) =>
      _prefs.write(configKey, jsonEncode(config.toJson()));

  bool isNoticeDismissed(int version) =>
      _prefs.read(noticeDismissedKey) == version.toString();

  Future<void> dismissNotice(int version) =>
      _prefs.write(noticeDismissedKey, version.toString());
}

final appConfigStoreProvider = Provider<AppConfigStore>(
  (ref) => AppConfigStore(ref.watch(localPrefsProvider)),
);
