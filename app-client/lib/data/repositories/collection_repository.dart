import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/dio_client.dart';
import '../datasources/collection_data_source.dart';
import '../datasources/collection_mock_data_source.dart';
import '../datasources/collection_remote_data_source.dart';
import '../models/collection_entry.dart';
import '../models/collection_state.dart';

/// 收藏的门面。控制器只认这一层，Mock 与真实实现互换不影响界面。
class CollectionRepository {
  CollectionRepository(this._dataSource);

  final CollectionDataSource _dataSource;

  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) =>
      _dataSource.fetchAll(status: status);

  Future<CollectionState> fetchState(String workId) =>
      _dataSource.fetchState(workId);

  Future<CollectionState> add(String workId, {CollectionStatus? status}) =>
      _dataSource.add(workId, status: status);

  /// 只改状态、不创建。记录不存在会抛 `COLLECTION_REQUIRED`。
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) => _dataSource.updateStatus(workId, status);

  Future<void> remove(String workId) => _dataSource.remove(workId);
}

/// 默认走 Mock；联调时加 `--dart-define=USE_MOCK=false` 切真实接口。
///
/// 与作品列表用同一个开关是有意的：只切一半会出现「作品来自真接口、收藏写着假数据」
/// 的混合状态，那种环境下的 bug 最难判断归属。
final collectionDataSourceProvider = Provider<CollectionDataSource>((ref) {
  if (AppConfig.useMock) return CollectionMockDataSource();
  return RemoteCollectionDataSource(ref.watch(dioProvider));
});

final collectionRepositoryProvider = Provider<CollectionRepository>((ref) {
  return CollectionRepository(ref.watch(collectionDataSourceProvider));
});
