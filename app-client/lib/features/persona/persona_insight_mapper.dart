import 'persona_view_data.dart';

/// `PersonaProfile`（`GET /api/me/profile`）→ [PersonaInsight] 的**纯函数**映射。
///
/// 单独成文件的两个理由：
///
/// 1. **可单测**：不给它包 widget，边界（缺字段、空画像、`share = null`）
///    直接用构造数据打，比走 widget 测试快两个数量级；
/// 2. 数据源与页面都不该认识契约字段名——换个字段只改这里。
///
/// ## 2026-11-09：不再自造轴（#498）
///
/// 之前客户端按 `type_weights` / `tag_weights` 自己派生六根轴（类型集中度、
/// 题材广度、口味浓度、评分态度、活跃度、近期活跃）。后端 #494 / #525 上线
/// **九维**后，两套口径同时存在就是双端漂移：同一个用户，网站看到的形状和
/// App 不一样，而且谁也不知道该信哪个。
///
/// 现在九维由服务端算好（契约 `dimensions`，键序固定、九键恒存在），
/// 客户端**只做单位换算**：0–100 → 0–1。**不要再往这里加任何公式**——
/// 公式一加，双端就又分家了。
class PersonaInsightMapper {
  const PersonaInsightMapper._();

  /// 九维的键序与中文名，与后端 `PersonaDimensions.KEYS` /
  /// `PersonaShareCodec.DIMENSION_LABELS` **逐字一致**。
  ///
  /// 这是分享参数 `d` 数组的下标顺序，也是雷达图的轴顺序——改顺序会让
  /// 老分享链接的维度错位，所以只能追加、不能重排。
  static const List<({String key, String label, String caption})> axes =
      <({String key, String label, String caption})>[
        (key: 'tag_focus', label: '题材垂直', caption: '最爱题材覆盖'),
        (key: 'exploration', label: '探索广度', caption: '题材种类'),
        (key: 'mainstream', label: '大众度', caption: '站内热度'),
        (key: 'pop_spread', label: '冷热跨度', caption: '冷门与热门'),
        (key: 'quality', label: '高分率', caption: '高分占比'),
        (key: 'era_span', label: '年代跨度', caption: '年代分布'),
        (key: 'fresh', label: '追新度', caption: '近五年'),
        (key: 'emotion', label: '情绪取向', caption: '治愈 / 致郁'),
        (key: 'completion', label: '完成度', caption: '追完比例'),
      ];

  /// 契约的中性值：数据不足的维度给 50，**绝不给 0**。
  /// 0 在雷达图上是一个凹角，看起来像「你这方面很弱」，实际是「还没数据」。
  static const double neutral = 50.0;

  /// 低于这个条数补一句解释：形状会偏中间（契约的样本门槛也是 5）。
  static const int minSampleSize = 5;

  static PersonaInsight fromProfile(Map<String, dynamic> data) {
    final sampleSize = _int(data['sample_size']);

    // `sample_size = 0` = 还没有任何行为。返回空维度让页面走空态，
    // 而不是画一个「九边全是 50」的规整多边形——那看起来像「你各方面都很平均」，
    // 实际是「我们还不认识你」。
    if (sampleSize <= 0) {
      return const PersonaInsight(
        title: '',
        review: '',
        dimensions: <PersonaDimension>[],
      );
    }

    final rawDimensions = _doubleMap(data['dimensions']);
    final dimensions = <PersonaDimension>[
      for (final axis in axes)
        PersonaDimension(
          label: axis.label,
          // 缺键按中性降级（#490 口径）；除以 100 换成展示比例。
          value: ((rawDimensions[axis.key] ?? neutral) / 100).clamp(0.0, 1.0),
          caption: axis.caption,
        ),
    ];

    return PersonaInsight(
      title: _text(data['hero_title']),
      titleCode: _optionalText(data['hero_code']),
      // 锐评与收尾都由服务端下发，客户端一个字都不改。
      review: _text(data['hero_note']),
      quip: _optionalText(data['final_quip']),
      dimensions: List<PersonaDimension>.unmodifiable(dimensions),
      topTags: List<String>.unmodifiable(_textList(data['persona_tags'], max: 5)),
      traitBlurbs: Map<String, String>.unmodifiable(
        _textMap(data['trait_blurbs']),
      ),
      rarity: _rarity(data['rarity']),
      hints: sampleSize < minSampleSize
          ? <String>[
              '只记录了 $sampleSize 条行为，雷达图会偏中间；多收几部再回来，形状会更准。',
            ]
          : const <String>[],
    );
  }

  // ── 解析小工具。契约坏了宁可降级，也不要把异常抛到页面层 ──────────────

  static String _text(Object? raw) => raw is String ? raw.trim() : '';

  static String? _optionalText(Object? raw) {
    final text = _text(raw);
    return text.isEmpty ? null : text;
  }

  static int _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  static double? _double(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  /// `dimensions` 是对象：键 → 0–100 的数。非数、非对象的项一律忽略，
  /// 由调用方按中性 50 补齐。
  static Map<String, double> _doubleMap(Object? raw) {
    if (raw is! Map) return const <String, double>{};
    final result = <String, double>{};
    raw.forEach((key, value) {
      if (key is! String) return;
      final parsed = _double(value);
      if (parsed != null) result[key] = parsed;
    });
    return result;
  }

  static List<String> _textList(Object? raw, {int? max}) {
    if (raw is! List) return const <String>[];
    final result = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      final text = item.trim();
      if (text.isEmpty) continue;
      result.add(text);
      if (max != null && result.length >= max) break;
    }
    return result;
  }

  static Map<String, String> _textMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final result = <String, String>{};
    raw.forEach((key, value) {
      if (key is! String || value is! String) return;
      if (value.trim().isEmpty) return; // 空串 = 没有文案，不占一行
      result[key] = value.trim();
    });
    return result;
  }

  static PersonaRarity? _rarity(Object? raw) {
    if (raw is! Map) return null;
    final tier = _text(raw['tier']);
    if (tier.isEmpty) return null;
    return PersonaRarity(
      tier: tier,
      label: _text(raw['label']),
      note: _optionalText(raw['note']),
      // ⚠️ `null` 原样保留：它是「未标定」，写成 0 会被显示成 0%，
      // 而 0% 在分档里是最稀有，意思完全反了。
      share: _double(raw['share']),
    );
  }
}
