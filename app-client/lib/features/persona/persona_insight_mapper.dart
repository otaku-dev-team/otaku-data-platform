import 'dart:math' as math;

import '../../data/models/work_type.dart';
import 'persona_view_data.dart';

/// `PersonaProfile`（`GET /api/me/profile`）→ [PersonaInsight] 的**纯函数**映射。
///
/// 单独成文件的两个理由：
///
/// 1. **可单测**：不给它包 widget，边界（全零权重、只有一个标签、`mean = null`）
///    直接用构造数据打，比走 widget 测试快两个数量级；
/// 2. 数据源与页面都不该认识这套公式——换轴名只改这里。
///
/// 轴的选择与公式见 `docs/persona-mapping-proposal.md` §3A。核心原则：
/// **每根轴都能说出它来自哪个字段**。算不出来的轴宁可不画（少一根），
/// 也不填一个编的数字——雷达图的价值就在「一眼看出形状」，假轴会毁掉它。
///
/// 三条边界必须显式处理，否则 `NaN` 会被画成「这根轴没有数据」（`Canvas` 对
/// `NaN` 是静默跳过，事后极难查）：`Σ|type_w| = 0`、正标签数 ≤ 1、`mean = null`。
class PersonaInsightMapper {
  const PersonaInsightMapper._();

  /// 低于这个行为条数就不生成称号与锐评：看了 3 部就给人下定义很冒犯。
  static const int minSampleSize = 5;

  /// 标签「算数」的门槛。低于它的权重多半是噪点。
  static const double tagThreshold = 0.15;

  /// 题材广度按「12 个算数标签 = 满分」折算。
  static const int breadthFullMark = 12;

  /// 活跃度按 300 条行为封顶（对数刻度，前 100 条涨得最快）。
  static const int activityFullMark = 300;

  /// 近期活跃按契约上限 20 条折算。
  static const int recentFullMark = 20;

  static PersonaInsight fromProfile(Map<String, dynamic> data) {
    final typeWeights = _weights(data['type_weights']);
    final tagWeights = _weights(data['tag_weights']);
    final sampleSize = _int(data['sample_size']);
    final ratingMean = _mean(data['rating_tendency']);
    final recentCount = _list(data['recent_active']).length;

    // 只有正权重才算「喜欢」。负值是低分作品带出来的证据，
    // 既不能进偏好标签，更不能当称号（「后宫派」这种会直接冒犯人）。
    final positives = <String, double>{
      for (final entry in tagWeights.entries)
        if (entry.value > 0) entry.key: entry.value,
    };

    // `sample_size = 0` = 还没有任何行为。返回空维度让页面走空态，
    // 而不是画一个「全是 0」的六边形——那看起来像「你的口味是零」。
    if (sampleSize <= 0) {
      return const PersonaInsight(
        title: '',
        review: '',
        dimensions: <PersonaDimension>[],
      );
    }

    final activeTagCount = _activeTagCount(tagWeights);
    final dimensions = <PersonaDimension>[
      PersonaDimension(
        label: '类型集中度',
        value: _typeConcentration(typeWeights),
        caption: '只看一两类',
      ),
      PersonaDimension(
        label: '题材广度',
        value: (activeTagCount / breadthFullMark).clamp(0.0, 1.0),
        caption: '题材跨度',
      ),
      PersonaDimension(
        label: '口味浓度',
        value: _tagConcentration(positives),
        caption: '偏好集中度',
      ),
      // 一条分都没打过时 `mean` 是 null —— 少一根轴，比画一根 0 好。
      if (ratingMean != null)
        PersonaDimension(
          label: '评分态度',
          value: _ratingAttitude(ratingMean),
          caption: '离中位多远',
        ),
      PersonaDimension(
        label: '活跃度',
        value: _activity(sampleSize),
        caption: '记录数量',
      ),
      PersonaDimension(
        label: '近期活跃',
        value: (recentCount / recentFullMark).clamp(0.0, 1.0),
        caption: '近 30 天',
      ),
    ];

    return PersonaInsight(
      title: _title(typeWeights, positives, sampleSize),
      review: _review(
        typeWeights: typeWeights,
        positives: positives,
        activeTagCount: activeTagCount,
        ratingMean: ratingMean,
        sampleSize: sampleSize,
      ),
      dimensions: List<PersonaDimension>.unmodifiable(dimensions),
      topTags: List<String>.unmodifiable(_sortedPositive(positives).take(8)),
      // 少一根轴必须解释。不解释的话，用户看到五边形只会觉得「怪」，
      // 不知道「打个分就会长出来」——而打分恰恰是 App 目前唯一缺的输入（#488）。
      hints: ratingMean == null
          ? const <String>[
              '还没有打分记录，所以少一根「评分态度」——给作品打个分它就会出现。',
            ]
          : const <String>[],
    );
  }

  // ---------------------------------------------------------------- 各轴公式

  /// 最强类型占「总偏好强度」的比例。只有一个类型有权重时是 1。
  static double _typeConcentration(Map<String, double> typeWeights) {
    if (typeWeights.isEmpty) return 0;
    var maxAbs = 0.0;
    var sumAbs = 0.0;
    for (final value in typeWeights.values) {
      final abs = value.abs();
      if (abs > maxAbs) maxAbs = abs;
      sumAbs += abs;
    }
    if (sumAbs <= 0) return 0; // 全零：没有类型偏好，不是「完全集中」
    return (maxAbs / sumAbs).clamp(0.0, 1.0);
  }

  /// 归一化熵的补：正权重越集中在少数标签，浓度越高。
  static double _tagConcentration(Map<String, double> positives) {
    if (positives.isEmpty) return 0;
    if (positives.length == 1) return 1; // 只有一个标签：最集中
    var total = 0.0;
    for (final value in positives.values) {
      total += value;
    }
    if (total <= 0) return 0;
    var entropy = 0.0;
    for (final value in positives.values) {
      final p = value / total;
      if (p > 0) entropy -= p * math.log(p);
    }
    final maxEntropy = math.log(positives.length.toDouble());
    if (maxEntropy <= 0) return 1;
    return (1 - entropy / maxEntropy).clamp(0.0, 1.0);
  }

  /// 离评分中位（5.5）越远，说明打分越有倾向——不管偏严还是偏宽容。
  /// 用绝对值而不是有符号值，否则「很严」和「很宽容」会被画成 0 和 1 两端，
  /// 看起来像两种完全不同的东西，其实都是「有态度」。
  static double _ratingAttitude(double mean) =>
      ((mean - 5.5).abs() / 4.5).clamp(0.0, 1.0);

  static double _activity(int sampleSize) {
    if (sampleSize <= 0) return 0;
    return (math.log(1 + sampleSize) / math.log(1 + activityFullMark)).clamp(
      0.0,
      1.0,
    );
  }

  // ------------------------------------------------------------------ 文案

  static String _title(
    Map<String, double> typeWeights,
    Map<String, double> positives,
    int sampleSize,
  ) {
    if (sampleSize < minSampleSize) return '';
    final tag = _strongestPositive(positives);
    if (tag != null) return '$tag派';
    final type = _strongestPositive(typeWeights);
    if (type != null) {
      final workType = WorkType.fromValue(type);
      if (workType != WorkType.unknown) return '${workType.label}观众';
    }
    return '';
  }

  /// 三段式规则文案：口味 / 广度 / 态度。
  ///
  /// 措辞刻意用「看起来」「偏爱」而不是「你是」——规则生成的句子一旦像断言，
  /// 用户会觉得被贴标签。
  static String _review({
    required Map<String, double> typeWeights,
    required Map<String, double> positives,
    required int activeTagCount,
    required double? ratingMean,
    required int sampleSize,
  }) {
    if (sampleSize < minSampleSize) {
      return '看得还不够多。收藏、浏览、打分都会算进来——多留几条记录，'
          '这里会长出只属于你的描述。';
    }

    final sentences = <String>[];

    String? typeLabel;
    final type = _strongestPositive(typeWeights);
    if (type != null) {
      final workType = WorkType.fromValue(type);
      if (workType != WorkType.unknown) typeLabel = workType.label;
    }
    final tag = _strongestPositive(positives);

    if (typeLabel != null && tag != null) {
      sentences.add('你看起来以$typeLabel为主，偏爱「$tag」这类题材');
    } else if (typeLabel != null) {
      sentences.add('你看起来以$typeLabel为主');
    } else if (tag != null) {
      sentences.add('你偏爱「$tag」这类题材');
    }

    if (activeTagCount >= 8) {
      sentences.add('题材跨度很广，很少把自己关在一种类型里');
    } else if (activeTagCount >= 4) {
      sentences.add('题材跨度中等，有偏好也愿意试别的');
    } else {
      sentences.add('题材偏窄，喜欢在一个方向上深挖');
    }

    if (ratingMean != null) {
      final mean = ratingMean.toStringAsFixed(1);
      if (ratingMean < 6.5) {
        sentences.add('打分偏严，均分 $mean');
      } else if (ratingMean <= 7.9) {
        sentences.add('打分中肯，均分 $mean');
      } else {
        sentences.add('打分比较宽容，均分 $mean');
      }
    }

    if (sentences.isEmpty) {
      return '你的口味还在形成中，再多留些记录会更准。';
    }
    return '${sentences.join('。')}。';
  }

  // ------------------------------------------------------------------ 解析

  static Map<String, double> _weights(Object? raw) {
    if (raw is! Map) return const <String, double>{};
    final result = <String, double>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is String && key.isNotEmpty && value is num) {
        result[key] = value.toDouble();
      }
    }
    return result;
  }

  static int _int(Object? raw) => raw is num ? raw.toInt() : 0;

  static List<Object?> _list(Object? raw) =>
      raw is List ? raw : const <Object?>[];

  /// `rating_tendency.mean` 可空——`count = 0` 时契约明确不给 0.0。
  static double? _mean(Object? raw) {
    if (raw is! Map) return null;
    final mean = raw['mean'];
    return mean is num ? mean.toDouble() : null;
  }

  static int _activeTagCount(Map<String, double> tagWeights) =>
      tagWeights.values.where((v) => v.abs() >= tagThreshold).length;

  static List<String> _sortedPositive(Map<String, double> positives) {
    final entries = positives.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => e.key).toList();
  }

  static String? _strongestPositive(Map<String, double> weights) {
    String? best;
    var bestValue = 0.0;
    for (final entry in weights.entries) {
      if (entry.value > bestValue) {
        bestValue = entry.value;
        best = entry.key;
      }
    }
    return best;
  }
}
