import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import 'user_profile.dart';

/// 账号资料的**唯一数据入口**。
///
/// 目前只有 mock 实现：`PUT /api/me/profile` 与 `User.avatar_url` 还在
/// pyxz0 那边待确认（#378 拍板的第一层契约），schema 未定稿。
/// 这里不写 URL、不写 DTO、不猜字段名——**真数据联调等接口**。
///
/// 接接口时的改动清单（其它文件不用动）：
/// 1. 新增 `ProfileRemoteDataSource implements ProfileDataSource`，
///    在里面按定稿契约做 `PUT /api/me/profile` 与 JSON → [UserProfile] 映射；
///    读取可复用 `/api/auth/me` 的 `display_name`（bio 若契约没回传，就只回显昵称）；
/// 2. 在 [profileDataSourceProvider] 里按 `AppConfig.useMock` 切换；
/// 3. 删掉 mock 实现，把 [profileProvider] 的依赖换成 remote。
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

/// 换实现只改这一个 provider。测试用 `overrideWithValue` 注入假数据源。
final profileDataSourceProvider = Provider<ProfileDataSource>(
  (ref) => ProfileMockDataSource(),
);

/// 当前资料。
final profileProvider = FutureProvider<UserProfile>((ref) async {
  // 未登录也返回空资料：页面自己显示登录引导，别在数据源里抛 401。
  ref.watch(authControllerProvider.select((state) => state.user?.userId));
  return ref.watch(profileDataSourceProvider).fetch();
  // 关掉 Riverpod 3 的自动重试：默认重试 10 次会留下 Timer，
  // 失败态变成 AsyncLoading(error:…) 一直挂在骨架屏上。
}, retry: (retryCount, error) => null);

/// 界面上的**显示名**：平台昵称优先，没有则回落账号的 label。
///
/// 抽成 provider 是因为有**两处**在显示它——个人空间身份卡、桌面账号菜单。
/// 各写一遍就会出现「一处改了、另一处还是旧名字」：身份卡之前就是这样，
/// 它只读 `AuthState.user`，于是编辑页保存成功、回到个人空间名字没变。
///
/// 未登录时返回空串（`AuthState.user` 为 null），显示什么文案由调用方决定
/// ——「未登录」和「正在读取账号…」是页面语义，不该塞进数据层。
final profileDisplayNameProvider = Provider<String>((ref) {
  final nickname = ref.watch(profileProvider).value?.displayName?.trim();
  if (nickname != null && nickname.isNotEmpty) return nickname;
  final account = ref.watch(
    authControllerProvider.select((state) => state.user?.label),
  );
  return account ?? '';
});
