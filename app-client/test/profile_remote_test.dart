import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/features/profile/avatar_data_source.dart';
import 'package:otaku_app/features/profile/profile_data_source.dart';

/// 账号资料与头像的**远程数据源**。
///
/// 钉的都是「写错了会静默失败」的地方：
/// - 路径写成 `/api/me/profile` 会打到阿宅画像上（同一 GET 返回的是口味权重）；
/// - multipart 字段名写错，服务端直接 400，而客户端只会显示一个通用错误；
/// - `PUT` 省略字段 = 「不改」，而编辑页要的是「清空」，两者语义相反。
void main() {
  group('账号资料', () {
    test('GET /api/me/account 映射成 UserProfile', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'user_id': 'U-1',
          'username': 'alice',
          'display_name': '深夜考据派',
          'bio': '看片做笔记',
          'avatar_url': 'https://cdn.test/a.webp',
        },
      );

      final profile = await ProfileRemoteDataSource(_dio(stub)).fetch();

      expect(stub.requests.single.method, 'GET');
      expect(stub.requests.single.path, '/api/me/account');
      expect(profile.displayName, '深夜考据派');
      expect(profile.bio, '看片做笔记');
      expect(profile.avatarUrl, 'https://cdn.test/a.webp');
    });

    test('空串 / 全空格都归一成 null，不留一片空白', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'user_id': 'U-1',
          'username': 'alice',
          'display_name': '   ',
          'bio': '',
          'avatar_url': null,
        },
      );

      final profile = await ProfileRemoteDataSource(_dio(stub)).fetch();

      expect(profile.displayName, isNull);
      expect(profile.bio, isNull);
      expect(profile.avatarUrl, isNull);
    });

    test('PUT 显式传两个字段：null 表示清空，不是「别动」', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'user_id': 'U-1',
          'username': 'alice',
          'display_name': null,
          'bio': '新简介',
          'avatar_url': null,
        },
      );

      await ProfileRemoteDataSource(
        _dio(stub),
      ).update(displayName: null, bio: '新简介');

      final request = stub.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/api/me/account');
      expect(request.data, <String, dynamic>{
        'display_name': null,
        'bio': '新简介',
      });
    });

    test('200 但空响应体：抛错，不当成一份空资料', () async {
      final stub = _Stub();

      expect(
        () => ProfileRemoteDataSource(_dio(stub)).fetch(),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('头像', () {
    late Directory tmpDir;
    late String filePath;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('otaku_avatar_remote');
      // 内容不重要：服务端按魔数判断，本地只负责把它塞进 multipart。
      final file = File('${tmpDir.path}/a.png')
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
      filePath = file.path;
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('POST multipart，字段名必须是 file', () async {
      final stub = _Stub(
        statusCode: 200,
        body: <String, dynamic>{'avatar_url': 'https://cdn.test/new.webp'},
      );

      final url = await HttpAvatarDataSource(_dio(stub)).upload(filePath);

      final request = stub.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/me/account/avatar');
      expect(url, 'https://cdn.test/new.webp');

      // 字段名错了服务端只会 400，而客户端拿到的是通用错误——
      // 这条断言是唯一能提前发现的地方。
      final form = request.data as FormData;
      expect(form.files.map((e) => e.key), <String>['file']);
    });

    test('200 但没给地址：抛错，不返回空串让界面显示空头像', () async {
      final stub = _Stub(statusCode: 200, body: <String, dynamic>{});

      expect(
        () => HttpAvatarDataSource(_dio(stub)).upload(filePath),
        throwsA(isA<ApiException>()),
      );
    });

    test('删除走 DELETE，路径与上传相同', () async {
      final stub = _Stub(statusCode: 204);

      await HttpAvatarDataSource(_dio(stub)).delete();

      final request = stub.requests.single;
      expect(request.method, 'DELETE');
      expect(request.path, '/api/me/account/avatar');
    });
  });
}

Dio _dio(Interceptor stub) =>
    Dio(BaseOptions(baseUrl: 'https://example.com'))..interceptors.add(stub);

class _Stub extends Interceptor {
  _Stub({this.statusCode = 200, this.body});

  final int statusCode;
  final Map<String, dynamic>? body;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: statusCode,
        data: body,
      ),
    );
  }
}
