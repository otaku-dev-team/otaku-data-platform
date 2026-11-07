import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../auth/auth_controller.dart';

/// 作品评分概览（`GET /api/works/{id}/reviews/summary`）。
@immutable
class WorkReviewSummary {
  const WorkReviewSummary({
    required this.total,
    required this.rated,
    this.average,
    this.distribution = const <int, int>{},
  });

  factory WorkReviewSummary.fromJson(Map<String, dynamic> json) {
    final distribution = <int, int>{};
    final raw = json['distribution'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final score = int.tryParse(entry.key.toString());
        final count = entry.value;
        if (score != null && count is num) {
          distribution[score] = count.toInt();
        }
      }
    }
    final average = json['average'];
    return WorkReviewSummary(
      total: _int(json['total']),
      rated: _int(json['rated']),
      average: average is num ? average.toDouble() : null,
      distribution: distribution,
    );
  }

  /// 已发布点评总条数（含只写文字不打分的）。
  final int total;

  /// 打了分的条数。均分只算这部分。
  final int rated;

  /// 均分（1–10）；一条都没打分时为 `null`，不是 0。
  final double? average;

  /// 分数 → 条数。没有的分数不出现（不补 0）。
  final Map<int, int> distribution;

  /// 还没人点评：整块不显示。「0 条点评」没有信息量。
  bool get isEmpty => total == 0;
}

/// 一条作品点评。
@immutable
class WorkReview {
  const WorkReview({
    required this.reviewId,
    required this.workId,
    required this.author,
    this.rating,
    this.body,
    this.status = 'published',
  });

  factory WorkReview.fromJson(Map<String, dynamic> json) {
    final reviewId = json['review_id'];
    final workId = json['work_id'];
    if (reviewId is! String || reviewId.isEmpty) {
      throw const FormatException('review_id 缺失');
    }
    if (workId is! String || workId.isEmpty) {
      throw const FormatException('work_id 缺失');
    }
    final rating = json['rating'];
    final body = json['body'];
    return WorkReview(
      reviewId: reviewId,
      workId: workId,
      author: json['author'] is String ? json['author'] as String : '',
      rating: rating is num ? rating.toInt() : null,
      body: (body is String && body.trim().isNotEmpty) ? body.trim() : null,
      status: json['status'] is String
          ? json['status'] as String
          : 'published',
    );
  }

  final String reviewId;
  final String workId;

  /// 用户名。**已注销用户显示「已注销用户」**，所以它不等于 `user_id`。
  final String author;

  /// 1–10；`null` = 只写了文字没打分。
  final int? rating;

  /// 长评正文；`null` = 只打了分。
  final String? body;

  /// `published` / `pending` / `hidden`。先审后发的站点新点评是 `pending`。
  final String status;

  bool get isPending => status == 'pending';
}

int _int(Object? raw) => raw is num ? raw.toInt() : 0;

/// 作品点评的读写（`/api/me/reviews` 与 `/api/works/{id}/reviews`）。
///
/// ⚠️ **没有「查我的点评」端点**（#531）：`/api/me/reviews` 只有 POST / PATCH /
/// DELETE，`UgcReview` 里也只有 `author` 用户名。所以 [fetchMine] 只能拉公开列表
/// 第一页、按用户名比对——点评超过一页时找不到，此时界面显示「写点评」，
/// 提交才会拿到 `409 REVIEW_EXISTS`。端点定了以后只改这一个方法。
abstract interface class UgcReviewDataSource {
  Future<WorkReviewSummary> fetchSummary(String workId);

  Future<WorkReview?> fetchMine(String workId, String username);

  Future<WorkReview> create({
    required String workId,
    int? rating,
    String? body,
  });

  Future<WorkReview> update(String reviewId, {int? rating, String? body});

  Future<void> delete(String reviewId);
}

class HttpUgcReviewDataSource implements UgcReviewDataSource {
  const HttpUgcReviewDataSource(this._dio);

  final Dio _dio;

  static const String myReviewsPath = '/api/me/reviews';

  static String listPath(String workId) =>
      '/api/works/${Uri.encodeComponent(workId)}/reviews';

  static String summaryPath(String workId) => '${listPath(workId)}/summary';

  @override
  Future<WorkReviewSummary> fetchSummary(String workId) async {
    final response = await _dio.get<Map<String, dynamic>>(summaryPath(workId));
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return WorkReviewSummary.fromJson(data);
  }

  @override
  Future<WorkReview?> fetchMine(String workId, String username) async {
    if (username.isEmpty) return null;
    final response = await _dio.get<Map<String, dynamic>>(
      listPath(workId),
      queryParameters: const <String, dynamic>{'page': 1, 'page_size': 20},
    );
    final items = response.data?['items'];
    if (items is! List) return null;
    for (final raw in items) {
      if (raw is! Map) continue;
      try {
        final review = WorkReview.fromJson(Map<String, dynamic>.from(raw));
        // `username` 是稳定的：`PUT /api/me/account` 只改 `display_name`。
        if (review.author == username) return review;
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  @override
  Future<WorkReview> create({
    required String workId,
    int? rating,
    String? body,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      myReviewsPath,
      data: <String, dynamic>{
        'work_id': workId,
        'rating': rating,
        'body': body,
      },
    );
    return _reviewOrThrow(response.data);
  }

  @override
  Future<WorkReview> update(
    String reviewId, {
    int? rating,
    String? body,
  }) async {
    final response = await _dio.patch<Map<String, dynamic>>(
      '$myReviewsPath/${Uri.encodeComponent(reviewId)}',
      // 契约：**省略 = 沿用原值**，`null` = 清空。编辑页保存整份表单，
      // 所以两项都传——用户清空正文就是真的清空。
      data: <String, dynamic>{'rating': rating, 'body': body},
    );
    return _reviewOrThrow(response.data);
  }

  @override
  Future<void> delete(String reviewId) =>
      _dio.delete<void>('$myReviewsPath/${Uri.encodeComponent(reviewId)}');

  static WorkReview _reviewOrThrow(Map<String, dynamic>? data) {
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return WorkReview.fromJson(data);
  }
}

/// 开发期实现（`USE_MOCK=true`，默认）：内存里存一条。
///
/// 概览给几条假数据，否则详情页那块永远是空的、开发时看不到版式。
///
/// **不加 `Future.delayed`**：即使是 `Duration.zero`，`Future.delayed` 也会
/// 留下一个 Timer，`pumpAndSettle` 之后仍然 pending，widget 测试会报
/// `!timersPending` 断言失败（`real_data_render_test` 就踩过）。
class MockUgcReviewDataSource implements UgcReviewDataSource {
  MockUgcReviewDataSource();

  WorkReview? _mine;

  @override
  Future<WorkReviewSummary> fetchSummary(String workId) async =>
      const WorkReviewSummary(
        total: 3,
        rated: 3,
        average: 8.0,
        distribution: <int, int>{8: 2, 9: 1},
      );

  @override
  Future<WorkReview?> fetchMine(String workId, String username) async => _mine;

  @override
  Future<WorkReview> create({
    required String workId,
    int? rating,
    String? body,
  }) async {
    final review = WorkReview(
      reviewId: 'R-mock',
      workId: workId,
      author: 'mock',
      rating: rating,
      body: body,
    );
    _mine = review;
    return review;
  }

  @override
  Future<WorkReview> update(
    String reviewId, {
    int? rating,
    String? body,
  }) async {
    final review = WorkReview(
      reviewId: reviewId,
      workId: _mine?.workId ?? '',
      author: _mine?.author ?? 'mock',
      rating: rating,
      body: body,
    );
    _mine = review;
    return review;
  }

  @override
  Future<void> delete(String reviewId) async {
    _mine = null;
  }
}

final ugcReviewDataSourceProvider = Provider<UgcReviewDataSource>((ref) {
  if (AppConfig.useMock) return MockUgcReviewDataSource();
  return HttpUgcReviewDataSource(ref.watch(dioProvider));
});

/// 是否该查 / 写点评。游客不查（401 会被拦截器广播成会话过期）。
final ugcReviewAudienceProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider).isSignedIn,
);

/// 当前用户名。点评的「我的」是按用户名比对的，所以这里只取它。
final ugcReviewUsernameProvider = Provider<String>((ref) {
  final user = ref.watch(authControllerProvider).user;
  return user?.username ?? '';
});

/// 作品评分概览。未登录也能看（公开读）。
final workReviewSummaryProvider =
    FutureProvider.family<WorkReviewSummary, String>((ref, workId) async {
      return ref.watch(ugcReviewDataSourceProvider).fetchSummary(workId);
    }, retry: (retryCount, error) => null);

/// 「我」对这部作品的点评。游客恒为 `null`（不发请求）。
final myWorkReviewProvider = FutureProvider.family<WorkReview?, String>((
  ref,
  workId,
) async {
  if (!ref.watch(ugcReviewAudienceProvider)) return null;
  return ref
      .watch(ugcReviewDataSourceProvider)
      .fetchMine(workId, ref.watch(ugcReviewUsernameProvider));
}, retry: (retryCount, error) => null);
