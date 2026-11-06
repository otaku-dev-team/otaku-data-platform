import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/dio_client.dart';

/// 作品详情打开时的**服务端打点**（`POST /api/me/views`，契约 `recordView`）。
///
/// 和本地那份「浏览记录」（`recentViewsProvider`，Hive）是两件事：
///
/// - **本地**是功能：用户要看「我最近看过什么」，必须立刻写、必须持久；
/// - **上报**是打点：服务端靠它积累画像信号（`user_work_view`，V32 / #401），
///   可以失败、可以晚、不需要回执。
///
/// 合成一处会让两件事互相牵连：打点失败不该让本地记录丢，本地写失败也不该
/// 让服务端少一条信号。
///
/// 契约的三个约定直接决定了实现：
/// 1. **重复提交正常**：同一人反复打开只让 `view_count` 累加，客户端不去重；
/// 2. **不需要回执**：成功 `204`，没有响应体；
/// 3. **客户端时钟不可信**：请求体只带 `work_id`，时间以服务端收到为准。
abstract interface class ViewReporter {
  /// 记一次浏览。**永远不抛**——打点失败对用户没有可操作性。
  Future<void> report(String workId);
}

class HttpViewReporter implements ViewReporter {
  const HttpViewReporter(this._dio);

  final Dio _dio;

  static const String path = '/api/me/views';

  @override
  Future<void> report(String workId) async {
    try {
      await _dio.post<void>(path, data: <String, dynamic>{'work_id': workId});
    } on Object {
      // 故意吞掉。契约说「不需要回执」，而弹一个「打点失败」既没有可操作性、
      // 又会打断正在看详情页的人。
    }
  }
}

/// 换实现只改这一个 provider；测试用 `overrideWithValue` 注入假的上报器。
final viewReporterProvider = Provider<ViewReporter>(
  (ref) => HttpViewReporter(ref.watch(dioProvider)),
);
