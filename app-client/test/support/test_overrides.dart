import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:otaku_app/core/storage/token_store.dart';
import 'package:otaku_app/data/datasources/auth_mock_data_source.dart';
import 'package:otaku_app/data/repositories/auth_repository.dart';

/// 内存令牌存储。真实实现要平台通道，单测与 widget 测试里调不了。
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore({this.token});

  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;

  @override
  Future<void> clear() async => token = null;
}

/// 预置令牌对应的用户名（`AuthMockDataSource` 的令牌格式是 `mock-token-<名字>`）。
const String signedInToken = 'mock-token-alice';

/// 认证相关的测试替身。
///
/// 列表页现在也挂账号入口（`AccountMenuButton`），任何 pump 到 `OtakuApp`
/// 的测试都会创建 `AuthController`——不给它内存令牌，就会走系统凭据管理器
/// 并在测试环境抛 `MissingPluginException`。默认给「未登录」，需要登录态的
/// 传 [signedInToken]。
/// `Override` 从 `flutter_riverpod/misc.dart` 取：主入口没有导出它。
List<Override> authOverrides({String? token}) => [
  tokenStoreProvider.overrideWithValue(MemoryTokenStore(token: token)),
  authDataSourceProvider.overrideWithValue(
    AuthMockDataSource(delay: Duration.zero),
  ),
];
