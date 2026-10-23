import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_prefs_provider.dart';

/// 「追番提醒」开关。
///
/// **默认关**：通知要占用户的通知栏，不告而来是打扰。用户主动打开时才申请
/// 系统权限（Android 13+）。
///
/// **设备级，不按账号分桶**：排程本来就跟着这台设备的当前账号重算，换账号后
/// 下次刷新会整体替换；按账号存反而会出现「登录了才记得自己开过」。
class ReminderEnabledController extends Notifier<bool> {
  static const String prefsKey = 'reminder_enabled';

  @override
  bool build() {
    // 只有明确写过 'true' 才算开。读不出来、写得坏、从没写过，一律关——
    // 通知是「要用户点头」的功能，默认值不能靠猜。
    return ref.watch(localPrefsProvider).read(prefsKey) == 'true';
  }

  Future<void> setEnabled(bool enabled) async {
    if (state == enabled) return;
    state = enabled;
    await ref
        .read(localPrefsProvider)
        .write(prefsKey, enabled ? 'true' : 'false');
  }
}

final reminderEnabledProvider =
    NotifierProvider<ReminderEnabledController, bool>(
      ReminderEnabledController.new,
    );
