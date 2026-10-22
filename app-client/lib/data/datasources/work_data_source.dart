import '../models/paged_result.dart';
import '../models/related_works.dart';
import '../models/work.dart';
import '../models/work_sort.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';

/// 数据来源的抽象。真接口与 Mock 各实现一份，仓储层只认这个接口，
/// 联调时替换实现即可，页面代码一行都不用改。
abstract interface class WorkDataSource {
  /// [sort] 省略等价于 [WorkSort.id]。真接口把它作为 `sort` 查询参数，
  /// Mock 在本地对结果做同样的排序——两边顺序一致，切换数据源才不会突变。
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
  });

  Future<Work> fetchDetail(String workId);

  /// 同标签推荐（详情页底部）。契约：作品没标签时返回空的 [RelatedWorks]，
  /// **不抛错**；作品不存在才 404。
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6});
}
