import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import 'my_comment.dart';
import 'my_comment_data_source.dart';

/// 骨架期的假数据。四条刻意覆盖列表最容易塌的情形：
/// 正常带作品 / 待审 / 被隐藏 / 作品已不可见（`work: null`），外加一条回复。
///
/// `coverUrl` 一律给 `null`：测试环境不允许发网络请求，给假 URL 只会让
/// `CoverImage` 走失败分支、把版式验证变成错误态验证。
class MyCommentMockDataSource implements MyCommentDataSource {
  const MyCommentMockDataSource();

  @override
  Future<List<MyComment>> fetchAll({required String userId}) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return [
      MyComment(
        commentId: 'C-mock-1',
        workId: 'W-mock-1',
        body: '第二季的作画比第一季稳太多了，第 6 话那段长镜头值得单独截出来看。',
        status: MyCommentStatus.published,
        createdAt: DateTime.utc(2026, 11, 5, 12, 20),
        work: const WorkSummary(
          workId: 'W-mock-1',
          workType: WorkType.anime,
          title: '街角魔族 第二季',
        ),
      ),
      MyComment(
        commentId: 'C-mock-2',
        workId: 'W-mock-2',
        body: '补完了原作再来回头看改编，删掉的那条支线其实挺可惜。',
        status: MyCommentStatus.pending,
        createdAt: DateTime.utc(2026, 11, 4, 3, 8),
        editedAt: DateTime.utc(2026, 11, 4, 3, 25),
        work: const WorkSummary(
          workId: 'W-mock-2',
          workType: WorkType.comic,
          title: '日常的归还',
        ),
      ),
      MyComment(
        commentId: 'C-mock-3',
        workId: 'W-mock-3',
        body: '同意楼上，节奏问题主要集中在中段三话。',
        status: MyCommentStatus.published,
        createdAt: DateTime.utc(2026, 11, 3, 9, 41),
        parentId: 'C-mock-1',
        work: const WorkSummary(
          workId: 'W-mock-1',
          workType: WorkType.anime,
          title: '街角魔族 第二季',
        ),
      ),
      MyComment(
        commentId: 'C-mock-4',
        workId: 'W-mock-4',
        body: '当年追连载的时候完全没看懂这条伏笔，重读才发现早就埋好了。',
        status: MyCommentStatus.hidden,
        createdAt: DateTime.utc(2026, 10, 28, 15, 2),
        // 作品后来不可见：评论正文照常返回，界面给占位而不是丢掉这一行。
      ),
    ];
  }
}
