import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../models/person_detail.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';

/// 人物详情（#455，消费 `GET /api/persons/{person_id}`）。
///
/// 独立接口，不塞进 `WorkDataSource`：作品数据源被列表 / 详情 / 收藏多处实现，
/// 加一个只服务人物页的方法会让所有 fake 都跟着补 stub（#410 踩过一次）。
abstract interface class PersonDataSource {
  Future<PersonDetail> fetch(String personId);
}

class RemotePersonDataSource implements PersonDataSource {
  RemotePersonDataSource(this._dio);

  final Dio _dio;

  @override
  Future<PersonDetail> fetch(String personId) async {
    // `person_id` 可能带 `bgm:` / `pname:` 前缀，冒号与斜杠都要编码。
    final path = '/api/persons/${Uri.encodeComponent(personId)}';
    try {
      final response = await _dio.get<Map<String, dynamic>>(path);
      final data = response.data;
      if (data == null) {
        throw const ApiException(
          code: ApiErrorCode.unknown,
          message: '服务端返回了空响应',
        );
      }
      return PersonDetail.fromJson(data);
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}

/// 开发期预览：一个人 + 三条作品，刻意覆盖「既配音又制作 / 只配音 / 只制作」
/// 三种形态——页面上两类信息如何排布，靠这三条就能看出来。
class MockPersonDataSource implements PersonDataSource {
  const MockPersonDataSource();

  @override
  Future<PersonDetail> fetch(String personId) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return PersonDetail(
      personId: personId,
      personName: '水樹奈々（Mock）',
      entityType: 'person',
      castCount: 2,
      creditCount: 1,
      works: [
        PersonCredit(
          work: const WorkSummary(
            workId: 'W-mock-1',
            workType: WorkType.anime,
            title: '魔法少女小圆',
            releaseYear: 2011,
          ),
          characters: const ['鹿目圆'],
          roles: const ['主题歌演唱'],
        ),
        PersonCredit(
          work: const WorkSummary(
            workId: 'W-mock-2',
            workType: WorkType.anime,
            title: '街角魔族 2丁目',
            releaseYear: 2022,
          ),
          characters: const ['阴影'],
        ),
        PersonCredit(
          work: const WorkSummary(
            workId: 'W-mock-3',
            workType: WorkType.game,
            title: '某部游戏',
            releaseYear: 2018,
          ),
          roles: const ['角色原案'],
        ),
      ],
    );
  }
}

/// 切换 Mock / 真接口的唯一开关（与 `articleDataSourceProvider` 同一套模式）。
final personDataSourceProvider = Provider<PersonDataSource>((ref) {
  if (AppConfig.useMock) return const MockPersonDataSource();
  return RemotePersonDataSource(ref.watch(dioProvider));
});
