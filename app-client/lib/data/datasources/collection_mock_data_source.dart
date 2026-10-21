import '../models/collection_entry.dart';
import '../models/collection_state.dart';
import '../models/work_type.dart';
import 'collection_data_source.dart';

/// 阶段 2 契约定稿前的假收藏源。
///
/// 内存实现，**实例级状态**：切换账号时数据不会自动区分用户——真实实现由
/// 服务端按令牌隔离（路径里没有 `user_id`）。这里不做用户隔离，是为了让
/// 「切账号后列表必须重新拉」这件事在界面上真的能被看出来。
///
/// 三条写语义与真实接口保持一致（upsert / 只改不建 / 幂等删除），
/// 所以界面在 Mock 与真实接口之间切换不需要改。默认仍走它，联调时用
/// `--dart-define=USE_MOCK=false` 切到 [RemoteCollectionDataSource]。
class CollectionMockDataSource implements CollectionDataSource {
  CollectionMockDataSource({this.delay = const Duration(milliseconds: 300)})
    : _items = _seed();

  final Duration delay;
  final List<CollectionEntry> _items;

  static List<CollectionEntry> _seed() {
    final now = DateTime.now().toUtc();
    return [
      CollectionEntry(
        workId: 'mock-w-001',
        workType: WorkType.anime,
        title: '航海王',
        status: CollectionStatus.watching,
        updatedAt: now.subtract(const Duration(minutes: 12)),
      ),
      CollectionEntry(
        workId: 'mock-w-002',
        workType: WorkType.anime,
        title: '葬送的芙莉莲',
        status: CollectionStatus.want,
        updatedAt: now.subtract(const Duration(hours: 3)),
      ),
      CollectionEntry(
        workId: 'mock-w-003',
        workType: WorkType.comic,
        title: '迷宫饭',
        status: CollectionStatus.watched,
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
      // 已收藏但没设状态：列表里显示「未设状态」，不是「未收藏」。
      CollectionEntry(
        workId: 'mock-w-004',
        workType: WorkType.anime,
        title: '冰海战记',
        updatedAt: now.subtract(const Duration(days: 2)),
      ),
      CollectionEntry(
        workId: 'mock-w-005',
        workType: WorkType.novel,
        title: '黄金神威（小说版）',
        status: CollectionStatus.want,
        updatedAt: now.subtract(const Duration(days: 4)),
      ),
    ];
  }

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async {
    await Future<void>.delayed(delay);
    final list = status == null
        ? _items
        : _items.where((item) => item.status == status).toList();
    // 排序与服务端一致：最近改动的在前。
    final sorted = [...list]
      ..sort((a, b) {
        final at = a.updatedAt;
        final bt = b.updatedAt;
        if (at == null && bt == null) return a.workId.compareTo(b.workId);
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return List.unmodifiable(sorted);
  }

  @override
  Future<CollectionState> fetchState(String workId) async {
    await Future<void>.delayed(delay);
    final index = _items.indexWhere((item) => item.workId == workId);
    if (index < 0) {
      // 未收藏是正常结果，不是错误。
      return CollectionState(workId: workId, collected: false);
    }
    final item = _items[index];
    return CollectionState(
      workId: workId,
      collected: true,
      status: item.status,
      updatedAt: item.updatedAt,
    );
  }

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) async {
    await Future<void>.delayed(delay);
    final index = _items.indexWhere((item) => item.workId == workId);
    if (index >= 0) {
      // upsert：已存在就覆盖状态。
      final updated = _items[index].withStatus(status);
      _items[index] = updated;
      return CollectionState(
        workId: workId,
        collected: true,
        status: updated.status,
        updatedAt: updated.updatedAt,
      );
    }
    final created = CollectionEntry(
      workId: workId,
      workType: WorkType.unknown,
      title: workId,
      status: status,
      updatedAt: DateTime.now().toUtc(),
    );
    _items.add(created);
    return CollectionState(
      workId: workId,
      collected: true,
      status: status,
      updatedAt: created.updatedAt,
    );
  }

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async {
    await Future<void>.delayed(delay);
    final index = _items.indexWhere((item) => item.workId == workId);
    // 只改不建：不存在就报错，**不顺手创建**（C11）。
    if (index < 0) throw collectionRequired;

    final updated = CollectionEntry(
      workId: _items[index].workId,
      workType: _items[index].workType,
      title: _items[index].title,
      coverUrl: _items[index].coverUrl,
      status: status,
      updatedAt: DateTime.now().toUtc(),
    );
    _items[index] = updated;
    return CollectionState(
      workId: workId,
      collected: true,
      status: updated.status,
      updatedAt: updated.updatedAt,
    );
  }

  @override
  Future<void> remove(String workId) async {
    await Future<void>.delayed(delay);
    // 幂等：不存在也当成功。
    _items.removeWhere((item) => item.workId == workId);
  }
}
