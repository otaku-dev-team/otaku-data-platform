/// #375 / #376 的 **UI 展示模型**，不是接口 DTO。
///
/// 这里刻意没有 `fromJson`、没有 `score`、没有 `tagWeights` / `typeWeights`
/// 这类契约字段：`docs/algorithm-design.md` §7 把「画像 JSON schema」「推荐
/// 返回结构」都列为**待三人确认**，#401 / #402 的接口还没定稿。现在照草案
/// 写一版 DTO，等于提前把未定口径钉进客户端，接口一改就要连页面一起改。
///
/// 所以边界是：
/// - 这一层只描述「屏幕上要画什么」（维度名、归一化后的比例、一句锐评、
///   已经翻译成人话的推荐理由）；
/// - 数据源层负责把「将来真正的接口响应」映射成这些对象。
/// 接口定稿后只改 `persona_data_source.dart` 里的 remote 实现与映射，
/// 页面、雷达图、卡片都不动。
library;

import 'package:flutter/foundation.dart';

import '../../data/models/work_summary.dart';

/// 雷达图的一根轴。
@immutable
class PersonaDimension {
  const PersonaDimension({
    required this.label,
    required this.value,
    this.caption,
  }) : assert(value >= 0 && value <= 1, 'value 必须是 0..1 的展示比例');

  final String label;

  /// 已归一化的展示比例。**不是接口里的原始权重**，也不参与任何打分
  /// （§6：客户端不自算打分）。
  final double value;

  /// 轴下方的一句短说明，可空。
  final String? caption;
}

/// 画像页要展示的全部内容。
@immutable
class PersonaInsight {
  const PersonaInsight({
    required this.title,
    required this.review,
    required this.dimensions,
    this.topTags = const <String>[],
    this.tone,
    this.boundAccount,
  });

  /// 称号，例如「深夜考据派」。
  final String title;

  /// 锐评文案。服务端生成（首站是 LLM 链路），客户端只展示。
  final String review;

  /// 六维。顺序即雷达图的轴顺序；为空时画像页走空态。
  final List<PersonaDimension> dimensions;

  /// 偏好标签，纯展示。
  final List<String> topTags;

  /// 当前生成语气；`null` = 接口还没给，界面显示「未设置」而不是编一个默认值。
  final String? tone;

  /// 已绑定的第三方账号（Bangumi / B 站）；`null` = 未绑定或接口未给。
  /// 客户端**不能**把「取不到」当成「没绑定」，所以 UI 只显示占位说明。
  final String? boundAccount;
}

/// 一张推荐卡要展示的内容。
@immutable
class RecommendedWork {
  const RecommendedWork({required this.work, this.reasons = const <String>[]});

  final WorkSummary work;

  /// 已经翻译好的「为什么推荐给你」。§6 允许客户端做理由标签展示，
  /// 但不允许自己拼分；规则 key → 文案的映射属于数据源层。
  final List<String> reasons;
}

/// #376 首页个性化区块的数据。
@immutable
class PersonaFeed {
  const PersonaFeed({required this.isGuest, this.items = const <RecommendedWork>[]});

  /// 游客态：不请求个性化接口，也不展示个性化榜单。
  ///
  /// #376 要求「游客回落默认榜」——首页既有的「高分作品 / 本日新番」
  /// 固定榜就是默认榜，这里不重复造第二份榜，只给一张登录引导卡。
  final bool isGuest;

  final List<RecommendedWork> items;

  bool get isEmpty => items.isEmpty;
}
