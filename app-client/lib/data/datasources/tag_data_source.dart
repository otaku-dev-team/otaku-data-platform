import '../models/tag_vocabulary.dart';
import '../models/work_type.dart';

/// 标签词表的数据来源（契约 `GET /api/tags`）。
///
/// **单独一个接口，不塞进 [WorkDataSource]**：词表只在标签面板里用，
/// 塞进去会让每一个列表相关的测试桩都要多实现一个方法，
/// 而这些桩根本用不到词表。
abstract interface class TagDataSource {
  /// [type] 省略表示统计全部类型；[limit] 省略由服务端决定（上限 2000）。
  Future<TagVocabulary> fetchTags({WorkType? type, int? limit});
}
