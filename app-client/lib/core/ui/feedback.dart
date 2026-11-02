import 'package:flutter/services.dart';

/// 触感反馈的统一入口。
///
/// 名字不叫 `Feedback`：`package:flutter/material.dart` 已经导出了一个
/// `Feedback` widget（用于 `Feedback.forTap` 这类无障碍反馈），同名会撞成
/// ambiguous_import。
///
/// 为什么收成一个文件而不是到处 `HapticFeedback.xxx()`：
/// 这类调用散开之后没人记得哪一档用在什么场景，最后变成"有的地方重、有的地方轻"。
/// 这里只留两档，语义按**用户意图**分，不按 API 名分：
///
/// - [tap]：**选中类**——切主导航、选分类、切星期。轻到几乎只有"咔"一下。
/// - [done]：**完成类**——收藏成功、取消收藏、标记状态。比 tap 实一点，
///   表示"这件事真的发生了"。
///
/// 失败不震：震一下会让人以为操作生效了，而下一步看到的是错误提示。
///
/// 桌面端不需要处理：`HapticFeedback` 在 Windows / macOS 上是空实现，
/// 不会抛也不会响。
abstract final class Haptics {
  const Haptics._();

  /// 选中类反馈（切 tab、选筛选项）。
  static Future<void> tap() => HapticFeedback.selectionClick();

  /// 完成类反馈（收藏 / 取消收藏 / 改状态成功）。
  static Future<void> done() => HapticFeedback.lightImpact();
}
