import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../datasources/collection_data_source.dart';
import '../datasources/collection_mock_data_source.dart';
import '../models/collection_entry.dart';

/// 收藏的门面。控制器只认这一层，Mock 与真实实现互换不影响界面。
class CollectionRepository {
  CollectionRepository(this._dataSource);

  final CollectionDataSource _dataSource;

  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) =>
      _dataSource.fetchAll(status: status);

  Future<CollectionEntry> add(String workId, {CollectionStatus? status}) =>
      _dataSource.add(workId, status: status);

  /// 只改状态、不创建。记录不存在会抛 `COLLECTION_REQUIRED`。
  Future<CollectionEntry> updateStatus(
    String workId,
    CollectionStatus? status,
  ) => _dataSource.updateStatus(workId, status);

  Future<void> remove(String workId) => _dataSource.remove(workId);
}

/// 阶段 2 契约定稿（Issue #32）后在这里切到 `RemoteCollectionDataSource`。
final collectionDataSourceProvider = Provider<CollectionDataSource>((ref) {
  return CollectionMockDataSource();
});

final collectionRepositoryProvider = Provider<CollectionRepository>((ref) {
  return CollectionRepository(ref.watch(collectionDataSourceProvider));
});
