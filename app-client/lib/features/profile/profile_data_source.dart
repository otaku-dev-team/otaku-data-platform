import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../auth/auth_controller.dart';
import 'user_profile.dart';

/// 账号资料的**唯一数据入口**。
///
/// 2026-11-07：`GET/PUT /api/me/account` 已上线（#509），本文件同时有 mock 与
/// remote 两个实现，由 [profileDataSourceProvider] 按 `AppConfig.useMock` 切换。
///
/// **路径是 `/api/me/account`，不是 `/api/me/profile`**——后者被阿宅画像占着
/// （`GET /api/me/profile` 返回口味权重）。「同一路径两种资源语义」的冲突，
/// 后端最后用换路径解决。
///
/// 头像**不在这里**：它走独立的 `/api/me/account/avatar`，见
/// `avatar_data_source.dart`——上传有自己的失败语义（2MB 上限、按魔数校验格式、
/// 1 分钟 1 次限流），塞进资料保存里会让「改昵称失败」和「头像太大」共用一个
/// 错误提示。
abstract interface class ProfileDataSource {
  Future<UserProfile> fetch();

  /// 保存资料。空串由调用方归一为 `null` 后传入；返回服务端确认后的资料。
  Future<UserProfile> update({required String? displayName, required String? bio});
}

/// 开发期实现：内存里存一份，保存后可以重进页面看到还在。
///
/// 初值用「无昵称 + 无简介」而不是编一个假昵称：界面要练的正是
/// 「没设置时回落 username」这条路径，填了假数据反而看不见。
class ProfileMockDataSource implements ProfileDataSource {
  UserProfile _current = const UserProfile();

  @override
  Future<UserProfile> fetch() async => _current;

  @override
  Future<UserProfile> update({
    required String? displayName,
    required String? bio,
  }) async {
    _current = UserProfile(displayName: displayName, bio: bio);
    return _current;
  }
}

/// 真数据源：`GET/PUT /api/me/account`（契约 `AccountProfile`）。
class ProfileRemoteDataSource implements ProfileDataSource {
  const ProfileRemoteDataSource(this._dio);

  final Dio _dio;

  static const String path = '/api/me/account';

  @override
  Future<UserProfile> fetch() async {
    final response = await _dio.get<Map<String, dynamic>>(path);
    return _fromJson(response.data);
  }

  @override
  Future<UserProfile> update({
    required String? displayName,
    required String? bio,
  }) async {
    final response = await _dio.put<Map<String, dynamic>>(
      path,
      data: <String, dynamic>{
        // 两个字段都**显式传**：契约里「省略 = 不改」，而编辑页保存的是整份表单，
        // 用户清空昵称就该真的清掉。`null` 是「清空」，不是「别动它」。
        'display_name': displayName,
        'bio': bio,
      },
    );
    return _fromJson(response.data);
  }

  static UserProfile _fromJson(Map<String, dynamic>? data) {
    if (data == null) {
      // 200 但空体 = 契约被破坏。当成功处理会让编辑页回显一份空资料、
      // 覆盖掉用户本地看到的值。
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return UserProfile(
      displayName: _text(data['display_name']),
      bio: _text(data['bio']),
      avatarUrl: _text(data['avatar_url']),
    );
  }

  /// 空串与全空格都当「没填」（契约的 `null` 语义）——
  /// 否则界面会显示一片空白，用户还以为昵称设成了空格。
  static String? _text(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// 换实现只改这一个 provider。测试用 `overrideWithValue` 注入假数据源。
final profileDataSourceProvider = Provider<ProfileDataSource>((ref) {
  if (AppConfig.useMock) return ProfileMockDataSource();
  return ProfileRemoteDataSource(ref.watch(dioProvider));
});

/// 当前资料。
final profileProvider = FutureProvider<UserProfile>((ref) async {
  // 未登录也返回空资料：页面自己显示登录引导，别在数据源里抛 401。
  ref.watch(authControllerProvider.select((state) => state.user?.userId));
  return ref.watch(profileDataSourceProvider).fetch();
  // 关掉 Riverpod 3 的自动重试：默认重试 10 次会留下 Timer，
  // 失败态变成 AsyncLoading(error:…) 一直挂在骨架屏上。
}, retry: (retryCount, error) => null);

/// 界面上的**显示名**：**只取站点昵称**。
///
/// 平台自设昵称（`PUT /api/me/account` 的 `display_name`）暂时不展示、也不让改——
/// 口径是「与站点保持一致」：站点能改，App 才跟着变。
///
/// 抽成 provider 是因为有**两处**在显示它（个人空间身份卡、桌面账号菜单），
/// 各写一遍就会出现「一处改了、另一处还是旧名字」。
///
/// 未登录时返回空串（`AuthState.user` 为 null），显示什么文案由调用方决定。
final profileDisplayNameProvider = Provider<String>((ref) {
  final account = ref.watch(
    authControllerProvider.select((state) => state.user?.label),
  );
  return account ?? '';
});
