import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 登录令牌的存储接口。
///
/// 抽成接口而不是直接用 `FlutterSecureStorage`，是为了测试里能换内存实现——
/// 真实实现在单测环境没有平台通道，调用会直接抛 `MissingPluginException`。
abstract interface class TokenStore {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> clear();
}

/// 正式实现：Android 走 Keystore，Windows 走凭据管理器。
///
/// **只存令牌本身，不存用户对象**：Windows 凭据管理器单条有长度上限，
/// 塞整个用户 JSON 在部分环境会写入失败；用户信息每次都能从
/// `GET /api/auth/me` 重新拿到，没有必要落盘。
class SecureTokenStore implements TokenStore {
  const SecureTokenStore(this._storage);

  final FlutterSecureStorage _storage;

  /// key 带应用前缀，避免同机器上其他程序用同一凭据名。
  static const String _key = 'otaku.auth_token';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

final tokenStoreProvider = Provider<TokenStore>((ref) {
  return const SecureTokenStore(FlutterSecureStorage());
});
