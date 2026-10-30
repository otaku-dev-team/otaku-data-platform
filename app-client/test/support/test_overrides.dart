import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:otaku_app/core/storage/token_store.dart';
import 'package:otaku_app/data/datasources/auth_mock_data_source.dart';
import 'package:otaku_app/data/datasources/tag_mock_data_source.dart';
import 'package:otaku_app/data/repositories/auth_repository.dart';
import 'package:otaku_app/features/contents/tag_vocabulary_provider.dart';

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

/// 标签词表的测试替身：零延迟。
///
/// 搜索框聚焦会去取「热门标签」（`hotTagSuggestionsProvider`），默认
/// `MockTagDataSource` 带 `Future.delayed`——widget 测试跑到一半就报
/// 「Pending timers」，看起来像待测功能挂了，实际只是定时器没排空。
List<Override> tagOverrides() => [
  tagDataSourceProvider.overrideWithValue(
    MockTagDataSource(latency: Duration.zero),
  ),
];
