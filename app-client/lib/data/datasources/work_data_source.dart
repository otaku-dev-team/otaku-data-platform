import '../models/paged_result.dart';
import '../models/work.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';

/// 数据来源的抽象。真接口与 Mock 各实现一份，仓储层只认这个接口，
/// 联调时替换实现即可，页面代码一行都不用改。
abstract interface class WorkDataSource {
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    int page = 1,
    int pageSize = 20,
  });

  Future<Work> fetchDetail(String workId);
}
