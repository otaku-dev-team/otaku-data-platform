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
  ///
  /// 九维接口给的是 0–100（50 = 中性 / 数据不足），这里除以 100。
  final double value;

  /// 轴下方的一句短说明，可空。
  final String? caption;
}

/// 称号稀有度（契约 `PersonaRarity`）。
///
/// ⚠️ `share` 为 `null` 是「校准样本未收录」，**不是 0%**：写成 0 会落进
/// 最高档 SSR，意思完全反了。所以界面显示「占比未知」而不是「0%」。
@immutable
class PersonaRarity {
  const PersonaRarity({
    required this.tier,
    required this.label,
    this.note,
    this.share,
  });

  /// `SSR` / `SR` / `R` / `N` / `?`（未标定）。
  final String tier;

  /// 等级名号，例「满地都是」。
  final String label;

  final String? note;

  /// 该称号在人群中的占比（百分比）。`null` = 未标定。
  final double? share;

  bool get isCalibrated => share != null;
}

/// 画像页要展示的全部内容。
@immutable
class PersonaInsight {
  const PersonaInsight({
    required this.title,
    required this.review,
    required this.dimensions,
    this.titleCode,
    this.quip,
    this.topTags = const <String>[],
    this.traitBlurbs = const <String, String>{},
    this.rarity,
    this.tone,
    this.boundAccount,
    this.hints = const <String>[],
  });

  /// 称号中文名（契约 `hero_title`），例「赛博貔貅」。
  final String title;

  /// 称号代号（`hero_code`），例 `PIXIU`。分享短链与埋点用，界面当小字标。
  final String? titleCode;

  /// 锐评（`hero_note`）。服务端按画像指纹轮转同一句，客户端只展示。
  ///
  /// ⚠️ 这句是**服务端规则生成**（`PersonaCopyData`），不是 LLM、也不是
  /// 客户端拼的。早期注释写成「首站是 LLM 链路」，已过时。
  final String review;

  /// 收尾冷评（`final_quip`），不带数字、同一用户稳定。
  final String? quip;

  /// 九维。顺序即雷达图的轴顺序（契约固定键序）；为空时画像页走空态。
  final List<PersonaDimension> dimensions;

  /// 人格标签（`persona_tags`）。**前两位位置固定**：`[0]` 题材簇、`[1]` 主身份，
  /// 特征从 `[2]` 开始。
  final List<String> topTags;

  /// 标签 → 一句解读（`trait_blurbs`）。键与 [topTags] 一致，空串表示没文案。
  final Map<String, String> traitBlurbs;

  /// 稀有度。`null` = 接口没给（旧版后端），界面不画徽章而不是画个假的。
  final PersonaRarity? rarity;

  /// 当前生成语气；`null` = 接口还没给，界面显示「未设置」而不是编一个默认值。
  final String? tone;

  /// 已绑定的第三方账号（Bangumi / B 站）；`null` = 未绑定或接口未给。
  /// 客户端**不能**把「取不到」当成「没绑定」，所以 UI 只显示占位说明。
  final String? boundAccount;

  /// 解释「这块为什么长这样」，渲染在雷达图下方。
  ///
  /// 九维恒存在（缺数据给 50），所以不再有「少一根轴」的解释；
  /// 现在只有一种：行为条数太少，形状会偏中间——说清楚，用户就不会
  /// 把「样本不足」理解成「我很平庸」。
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
