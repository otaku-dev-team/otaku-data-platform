import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/remote_config.dart';
import 'app_config_controller.dart';

/// 服务端功能开关（`GET /api/app/config` 的 `values` 键值袋）。
///
/// 契约原话就是干这个用的：「客户端启动时拉一次，用来决定公告、**功能开关**
/// 这类**不发版就能改**的行为」。这是 Flutter 里唯一能做到「不发版改行为」的通道
/// ——AOT 编译把 Dart 打进 `libapp.so`，没有代码热更新的余地。
///
/// 三条约定：
///
/// 1. **默认关**：[RemoteConfig.flag] 对缺键返回 `false`。开关的默认值必须是关，
///    否则后端从没配过就等于偷偷打开了；
/// 2. **键名加 `feature.` 前缀**，与 `app.notice` / `adult.*` 分开，避免撞名；
/// 3. **只拦最后一步**，不藏入口——入口藏了用户会以为 App 没这个功能；
///    点下去被明确拦下，才知道「还没开放」而不是「坏了」。
class FeatureFlags {
  const FeatureFlags(this._config);

  final RemoteConfig _config;

  /// 头像上传。关 = 选图与预览可用，点「保存头像」只弹说明、不写任何数据。
  bool get avatarUpload => _config.flag('feature.avatar_upload');

  /// 作品点评（打分 / 写评）。关 = 概览照常显示，但不能新增与修改。
  bool get workReview => _config.flag('feature.work_review');

  /// 资讯收藏入口。关 = 个人空间的「资讯收藏」标未开放。
  bool get articleFavorite => _config.flag('feature.article_favorite');

  /// 账号资料（昵称 / 简介）编辑。关 = 保存时只弹说明、不写数据。
  ///
  /// 口径：昵称与站点同步，站点不能改 App 里也不能改；简介同理。
  bool get accountEdit => _config.flag('feature.account_edit');
}

/// 读开关。配置还没拉到时全部为 `false`（fail-closed）。
final featureFlagsProvider = Provider<FeatureFlags>(
  (ref) => FeatureFlags(ref.watch(appConfigProvider).config),
);
