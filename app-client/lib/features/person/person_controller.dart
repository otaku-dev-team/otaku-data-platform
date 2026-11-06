import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/person_data_source.dart';
import '../../data/models/person_detail.dart';

/// 人物详情。family 按 `person_id` 缓存：从 A 的作品列表点进另一个人再点回来，
/// 不会重复请求。
///
/// `retry: null` 与全站一致——自动重试会让 404 看起来像「一直在加载」。
final personDetailProvider = FutureProvider.family<PersonDetail, String>(
  (ref, personId) => ref.watch(personDataSourceProvider).fetch(personId),
  retry: (retryCount, error) => null,
);
