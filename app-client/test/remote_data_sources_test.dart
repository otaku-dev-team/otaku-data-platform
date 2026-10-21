import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/network/auth_token_interceptor.dart';
import 'package:otaku_app/core/network/error_interceptor.dart';
import 'package:otaku_app/core/storage/token_store.dart';
import 'package:otaku_app/data/datasources/auth_remote_data_source.dart';
import 'package:otaku_app/data/datasources/collection_remote_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';

/// 假后端：按 `METHOD 路径` 查表返回响应，同时记录所有请求，便于断言
/// 「用的是 PUT 还是 POST」「有没有把令牌带上」这类**契约层面**的事实。
///
/// 不用 mock 框架：这些断言只关心发出的报文，手写一个拦截器就够，
/// 也避免了给项目引入新的测试依赖。
class _FakeBackend extends Interceptor {
  _FakeBackend(this.routes);

  final Map<String, Response<Map<String, dynamic>> Function(RequestOptions)> routes;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    requests.add(options);
    final handlerFor = routes['${options.method} ${options.path}'];
    if (handlerFor == null) {
      handler.reject(
        _failure(options, status: 404, code: 'WORK_NOT_FOUND'),
      );
      return;
    }

    final response = handlerFor(options);
    final status = response.statusCode ?? 200;
    if (status >= 400) {
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
        ),
      );
      return;
    }
    handler.resolve(response);
  }

  static DioException _failure(
    RequestOptions options, {
    required int status,
    required String code,
  }) {
    return DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: status,
        data: <String, dynamic>{
          'error': <String, dynamic>{'code': code, 'message': 'test'},
        },
      ),
    );
  }

  RequestOptions lastOf(String method, String path) {
    return requests.lastWhere(
      (r) => r.method == method && r.path == path,
      orElse: () => throw StateError('没有发出过 $method $path'),
    );
  }
}

Response<Map<String, dynamic>> _ok(
  RequestOptions options,
  Map<String, dynamic> data, {
  int status = 200,
}) {
  return Response<Map<String, dynamic>>(
    requestOptions: options,
    statusCode: status,
    data: data,
  );
}

Response<Map<String, dynamic>> _error(
  RequestOptions options, {
  required int status,
  required String code,
}) {
  return Response<Map<String, dynamic>>(
    requestOptions: options,
    statusCode: status,
    data: <String, dynamic>{
      'error': <String, dynamic>{'code': code, 'message': 'test'},
    },
  );
}

Dio _dioWith(_FakeBackend backend) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  // 与生产同一条错误链路：业务异常必须在数据源出口就已经是 ApiException。
  dio.interceptors.add(ErrorInterceptor());
  dio.interceptors.add(backend);
  return dio;
}

class _FakeTokenStore implements TokenStore {
  _FakeTokenStore([this.value]);

  String? value;
  int reads = 0;

  @override
  Future<String?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String token) async => value = token;

  @override
  Future<void> clear() async => value = null;
}

Dio _dioWithToken(_FakeBackend backend, _FakeTokenStore store) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.interceptors.add(ErrorInterceptor());
  dio.interceptors.add(AuthTokenInterceptor(store.read));
  dio.interceptors.add(backend);
  return dio;
}

Map<String, dynamic> _sessionJson() => <String, dynamic>{
  'token': '9Zk3m0p7qz58f3a1k2m0p7qz58f3a1k2m0p7qz58f',
  'expires_at': '2026-11-20T06:00:00Z',
  'user': <String, dynamic>{
    'user_id': 'U-9k2m0p7qz58f3a1',
    'username': 'alice',
    'display_name': null,
  },
};

Map<String, dynamic> _stateJson({
  required String workId,
  required bool collected,
  String? status,
}) => <String, dynamic>{
  'work_id': workId,
  'collected': collected,
  'status': status,
  'created_at': collected ? '2026-10-21T06:00:00Z' : null,
  'updated_at': '2026-10-21T06:00:00Z',
};

void main() {
  group('RemoteAuthDataSource', () {
    test('登录走 POST /api/auth/login，并解析出令牌与用户', () async {
      final backend = _FakeBackend({
        'POST /api/auth/login': (options) => _ok(options, _sessionJson()),
      });
      final source = RemoteAuthDataSource(_dioWith(backend));

      final session = await source.login(
        username: 'alice',
        password: 'secret123',
      );

      expect(session.token, startsWith('9Zk3'));
      expect(session.user.username, 'alice');
      expect(session.user.label, 'alice', reason: 'display_name 为 null 时回落用户名');
      expect(session.expiresAt.year, 2026);

      final request = backend.lastOf('POST', '/api/auth/login');
      expect(request.data, <String, dynamic>{
        'username': 'alice',
        'password': 'secret123',
      });
    });

    test('401 INVALID_CREDENTIALS 原样抛给上层（与 UNAUTHORIZED 区分）', () async {
      final backend = _FakeBackend({
        'POST /api/auth/login': (options) =>
            _error(options, status: 401, code: 'INVALID_CREDENTIALS'),
      });
      final source = RemoteAuthDataSource(_dioWith(backend));

      await expectLater(
        source.login(username: 'alice', password: 'wrong'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.invalidCredentials,
          ),
        ),
      );
    });

    test('me 显式带上令牌；401 UNAUTHORIZED 是会话失效', () async {
      final backend = _FakeBackend({
        'GET /api/auth/me': (options) => options.headers['Authorization'] ==
                'Bearer good-token'
            ? _ok(options, <String, dynamic>{
                'user_id': 'U-1',
                'username': 'alice',
              })
            : _error(options, status: 401, code: 'UNAUTHORIZED'),
      });
      final source = RemoteAuthDataSource(_dioWith(backend));

      final user = await source.me('good-token');
      expect(user.userId, 'U-1');

      await expectLater(
        source.me('expired-token'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.unauthorized,
          ),
        ),
      );
    });

    test('logout 带上当前令牌，204 不抛异常', () async {
      final backend = _FakeBackend({
        'POST /api/auth/logout': (options) => _ok(options, <String, dynamic>{}, status: 204),
      });
      final source = RemoteAuthDataSource(_dioWith(backend));

      await source.logout('current-token');

      final request = backend.lastOf('POST', '/api/auth/logout');
      expect(request.headers['Authorization'], 'Bearer current-token');
    });
  });

  group('RemoteCollectionDataSource', () {
    test('列表逐页取完：page_size 用满上限，两页合并', () async {
      final backend = _FakeBackend({
        'GET /api/me/collections': (options) {
          final page = options.queryParameters['page'] as int;
          return _ok(options, <String, dynamic>{
            'page': page,
            'page_size': 50,
            'total': 3,
            'total_pages': 2,
            'items': page == 1
                ? <Map<String, dynamic>>[
                    <String, dynamic>{
                      'work_id': 'W-1',
                      'work_type': 'anime',
                      'title': '航海王',
                      'cover_url': null,
                      'status': 'watching',
                      'created_at': '2026-10-01T00:00:00Z',
                      'updated_at': '2026-10-20T00:00:00Z',
                    },
                    <String, dynamic>{
                      'work_id': 'W-2',
                      'work_type': 'comic',
                      'title': '迷宫饭',
                      'status': null,
                      'created_at': '2026-10-01T00:00:00Z',
                      'updated_at': '2026-10-19T00:00:00Z',
                    },
                  ]
                : <Map<String, dynamic>>[
                    <String, dynamic>{
                      'work_id': 'W-3',
                      'work_type': 'novel',
                      'title': '黄金神威',
                      'status': null,
                      'created_at': '2026-10-01T00:00:00Z',
                      'updated_at': '2026-10-18T00:00:00Z',
                    },
                  ],
          });
        },
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      final items = await source.fetchAll();

      expect(items.map((e) => e.workId), ['W-1', 'W-2', 'W-3']);
      expect(items[1].status, isNull, reason: 'null 状态是「已收藏但未设状态」');
      expect(backend.requests, hasLength(2), reason: '两页都要取');
      expect(
        backend.requests.first.queryParameters['page_size'],
        50,
        reason: '用契约上限，不是默认值 20',
      );
    });

    test('筛选条件通过 status 传递，none 不传给服务端', () async {
      final backend = _FakeBackend({
        'GET /api/me/collections': (options) => _ok(options, <String, dynamic>{
          'page': 1,
          'page_size': 50,
          'total': 0,
          'total_pages': 0,
          'items': <Map<String, dynamic>>[],
        }),
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      await source.fetchAll(status: CollectionStatus.want);
      expect(backend.requests.last.queryParameters['status'], 'want');

      await source.fetchAll();
      expect(
        backend.requests.last.queryParameters.containsKey('status'),
        isFalse,
        reason: '省略 status 表示全部，不能发 null 出去',
      );
    });

    test('未收藏返回 200 + collected:false，不是错误', () async {
      final backend = _FakeBackend({
        'GET /api/me/collections/W-9': (options) => _ok(
          options,
          _stateJson(workId: 'W-9', collected: false),
        ),
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      final state = await source.fetchState('W-9');
      expect(state.collected, isFalse);
      expect(state.status, isNull);
    });

    test('加入收藏用 PUT（POST 会 405），省略 status 时请求体为空对象', () async {
      final backend = _FakeBackend({
        'PUT /api/me/collections/W-1': (options) => _ok(
          options,
          _stateJson(workId: 'W-1', collected: true),
        ),
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      final state = await source.add('W-1');

      expect(state.collected, isTrue);
      expect(state.status, isNull);
      expect(backend.lastOf('PUT', '/api/me/collections/W-1').data, isEmpty);
    });

    test('加入收藏可以直接带初始状态', () async {
      final backend = _FakeBackend({
        'PUT /api/me/collections/W-1': (options) => _ok(
          options,
          _stateJson(workId: 'W-1', collected: true, status: 'watching'),
        ),
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      await source.add('W-1', status: CollectionStatus.watching);
      expect(backend.lastOf('PUT', '/api/me/collections/W-1').data, {
        'status': 'watching',
      });
    });

    test('改状态用 PATCH；409 COLLECTION_REQUIRED 原样抛出', () async {
      final backend = _FakeBackend({
        'PATCH /api/me/collections/W-1': (options) =>
            _error(options, status: 409, code: 'COLLECTION_REQUIRED'),
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      await expectLater(
        source.updateStatus('W-1', CollectionStatus.watched),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.collectionRequired,
          ),
        ),
      );
      // 409 之后绝不能补一个 PUT —— 那等于静默重新收藏，C11 直接失败。
      expect(
        backend.requests.map((r) => r.method),
        ['PATCH'],
        reason: '收到 409 不重试、不改用 PUT',
      );
    });

    test('清除状态发的是显式 null，不是省略字段', () async {
      final backend = _FakeBackend({
        'PATCH /api/me/collections/W-1': (options) => _ok(
          options,
          _stateJson(workId: 'W-1', collected: true),
        ),
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      await source.updateStatus('W-1', null);
      expect(
        backend.lastOf('PATCH', '/api/me/collections/W-1').data,
        containsPair('status', null),
      );
    });

    test('取消收藏幂等：204 视为成功，不额外查一次', () async {
      final backend = _FakeBackend({
        'DELETE /api/me/collections/W-1': (options) =>
            _ok(options, <String, dynamic>{}, status: 204),
      });
      final source = RemoteCollectionDataSource(_dioWith(backend));

      await source.remove('W-1');
      expect(backend.requests.map((r) => r.method), ['DELETE']);
    });
  });

  group('AuthTokenInterceptor', () {
    Response<Map<String, dynamic>> Function(RequestOptions) okResponse() =>
        (options) => _ok(options, <String, dynamic>{'ok': true});

    test('普通请求自动带上令牌', () async {
      final backend = _FakeBackend({'GET /api/works': okResponse()});
      final dio = _dioWithToken(backend, _FakeTokenStore('tok-1'));

      await dio.get<Map<String, dynamic>>('/api/works');

      expect(
        backend.lastOf('GET', '/api/works').headers['Authorization'],
        'Bearer tok-1',
      );
    });

    test('登录与退出不带令牌：旧会话不该跟到登录请求上', () async {
      final backend = _FakeBackend({
        'POST /api/auth/login': okResponse(),
        'POST /api/auth/logout': okResponse(),
      });
      final dio = _dioWithToken(backend, _FakeTokenStore('stale-token'));

      await dio.post<Map<String, dynamic>>('/api/auth/login');
      await dio.post<Map<String, dynamic>>('/api/auth/logout');

      expect(
        backend.lastOf('POST', '/api/auth/login').headers,
        isNot(contains('Authorization')),
      );
      expect(
        backend.lastOf('POST', '/api/auth/logout').headers,
        isNot(contains('Authorization')),
      );
    });

    test('没有令牌时不发空的 Authorization 头', () async {
      final backend = _FakeBackend({'GET /api/works': okResponse()});
      final dio = _dioWithToken(backend, _FakeTokenStore());

      await dio.get<Map<String, dynamic>>('/api/works');

      expect(
        backend.lastOf('GET', '/api/works').headers,
        isNot(contains('Authorization')),
      );
    });
  });

  group('CachedTokenStore', () {
    test('首读之后走内存，不反复读系统安全存储', () async {
      final inner = _FakeTokenStore('tok-1');
      final store = CachedTokenStore(inner);

      expect(await store.read(), 'tok-1');
      expect(await store.read(), 'tok-1');
      expect(inner.reads, 1, reason: '只有第一次真正读了内层');
    });

    test('写入/清除同步更新缓存，不会读到过期值', () async {
      final store = CachedTokenStore(_FakeTokenStore('tok-1'));
      await store.read();

      await store.write('tok-2');
      expect(await store.read(), 'tok-2');

      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
