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

/// 带内存缓存的令牌存储。
///
/// 每个鉴权请求都要读一次令牌，而 [SecureTokenStore] 在 Windows 上要走凭据管理器
/// （跨进程调用）、Android 上要走 Keystore，把它挂在每次请求的链路上不划算。
/// 这里首读之后走内存，写入/清除时同步更新缓存。
///
/// 只在进程内缓存：令牌的权威来源仍是系统安全存储，进程重启后重新读一次，
/// 因此「别处改了令牌」不会造成长期不一致。
class CachedTokenStore implements TokenStore {
  CachedTokenStore(this._inner);

  final TokenStore _inner;

  String? _cached;
  bool _loaded = false;

  @override
  Future<String?> read() async {
    if (_loaded) return _cached;
    _cached = await _inner.read();
    _loaded = true;
    return _cached;
  }

  @override
  Future<void> write(String token) async {
    // 先落盘再更新缓存：写失败时缓存必须保持原值，否则内存里会有一个
    // 存储中并不存在的令牌，重启后行为对不上。
    await _inner.write(token);
    _cached = token;
    _loaded = true;
  }

  @override
  Future<void> clear() async {
    await _inner.clear();
    _cached = null;
    _loaded = true;
  }
}

final tokenStoreProvider = Provider<TokenStore>((ref) {
  return CachedTokenStore(const SecureTokenStore(FlutterSecureStorage()));
});
