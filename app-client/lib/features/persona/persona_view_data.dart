/// #375 / #376 的 **UI 展示模型**，不是接口 DTO。
///
/// 这一层只描述「屏幕上要画什么」（维度名、归一化后的比例、一句锐评、
/// 已经翻译成人话的推荐理由）。2026-11-06 上线的 `/api/me/recommend`（#402）
/// 返回的是 `cold_start` / `score` / `reasons[{type, value, weight}]`，
/// 由 `persona_data_source.dart` 的远程实现映射到这里，页面不认识契约字段。
///
/// 客户端不自算打分（§6）：`score` 只是本次结果内的相对分，UI 不展示、
/// 也不拿它跨请求比较。
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
    this.hints = const <String>[],
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

  /// 解释「为什么这里少一块」，渲染在雷达图下方。
  ///
  /// 目前只有一种：还没打过分 → 少了「评分态度」那根轴。**静默少一根是最差的
  /// 处理**——用户只会觉得雷达图怪怪的，不知道打分之后会多出来。明说一句，
  /// 「缺」就变成了「可预期的下一步」。
  final List<String> hints;
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
  const PersonaFeed({
    required this.isGuest,
    this.items = const <RecommendedWork>[],
    this.coldStart = false,
  });

  /// 游客态：不请求个性化接口，也不展示个性化榜单。
  ///
  /// #376 要求「游客回落默认榜」——首页既有的「高分作品 / 本日新番」
  /// 固定榜就是默认榜，这里不重复造第二份榜，只给一张登录引导卡。
  final bool isGuest;

  final List<RecommendedWork> items;

  /// 契约 `RecommendationPage.cold_start`：画像为空，本次返回的是**全站高分榜**
  /// （`score` 恒 0、`reasons` 为空）。UI 必须把「为你推荐」换成「热门推荐」，
  /// 不能把公共榜单说成是给用户算出来的。
  final bool coldStart;

  bool get isEmpty => items.isEmpty;
}
