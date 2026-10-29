import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/storage/local_prefs.dart';
import '../../core/storage/local_prefs_provider.dart';
import 'update_manifest.dart';

/// 「忽略此次更新」的持久化。
///
/// 语义按产品要求：**只在当前 App 版本内有效**。用户点了忽略，之后启动
/// 不再弹同一个更新；一旦 App 版本变了（说明用户已经更新过），旧标记作废，
/// 该提示就提示。
class UpdateIgnoreStore {
  UpdateIgnoreStore(this._prefs);

  final LocalPrefs _prefs;

  static const _ignoredVersionKey = 'update.ignored_version_code';
  static const _ignoredOnAppKey = 'update.ignored_on_app_code';

  bool isIgnored(UpdateManifest manifest) {
    final ignored = int.tryParse(_prefs.read(_ignoredVersionKey) ?? '');
    final ignoredOn = int.tryParse(_prefs.read(_ignoredOnAppKey) ?? '');
    if (ignored == null || ignoredOn == null) return false;
    if (ignoredOn != AppConfig.versionCode) return false;
    return ignored == manifest.versionCode;
  }

  Future<void> ignore(UpdateManifest manifest) async {
    await _prefs.write(_ignoredVersionKey, '${manifest.versionCode}');
    await _prefs.write(_ignoredOnAppKey, '${AppConfig.versionCode}');
  }
}

final updateIgnoreStoreProvider = Provider<UpdateIgnoreStore>((ref) {
  return UpdateIgnoreStore(ref.watch(localPrefsProvider));
});
