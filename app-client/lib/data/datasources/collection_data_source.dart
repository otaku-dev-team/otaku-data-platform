import '../../core/network/api_exception.dart';
import '../models/collection_entry.dart';
import '../models/collection_state.dart';

/// 本人收藏的服务端能力。
///
/// 接口形状见 `docs/openapi.yaml` 的 `/api/me/collections*`（契约正文在
/// `docs/stage2-account-collection-contract.md` §4.4–§4.8）。
///
/// 三条语义写在这里，实现方不能改：
/// 1. [add] 是 upsert（PUT），可以带初始状态；
/// 2. [updateStatus] **只改不建**（PATCH），记录不存在必须抛
///    [ApiErrorCode.collectionRequired]，**绝不能顺手创建**——C11 靠这条成立；
/// 3. [remove] 幂等，删整条记录，状态随之消失。
///
/// 写操作的返回值是 [CollectionState] 而不是 [CollectionEntry]：契约的响应里
/// **没有作品字段**，硬凑一个 `CollectionEntry` 只能凭空填 `title`。
abstract class CollectionDataSource {
  /// 契约要求分页（默认 20、上限 50）。骨架阶段一次取完，
  /// 真实实现按 `page` / `page_size` 翻页，调用方签名不变。
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status});

  /// 单条状态。未收藏返回 `collected: false`，**不是 404**。
  Future<CollectionState> fetchState(String workId);

  Future<CollectionState> add(String workId, {CollectionStatus? status});

  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  );

  Future<void> remove(String workId);
}

/// 改一条**不存在**的收藏时抛这个。
const ApiException collectionRequired = ApiException(
  code: ApiErrorCode.collectionRequired,
  message: '该作品不在收藏中，请刷新后重试',
  statusCode: 409,
);
