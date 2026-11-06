import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/features/persona/persona_insight_mapper.dart';
import 'package:otaku_app/features/persona/persona_view_data.dart';

/// #375 画像映射：`PersonaProfile` → `PersonaInsight`。
///
/// 全是纯函数断言，不搭 widget。钉的是「每根轴都能说出从哪来」——
/// 公式错了雷达图只会画出一个**看不出问题的错形状**，比崩溃更难发现。
void main() {
  PersonaDimension axis(PersonaInsight insight, String label) =>
      insight.dimensions.firstWhere((d) => d.label == label);

  Map<String, dynamic> profile({
    Map<String, dynamic>? typeWeights,
    Map<String, dynamic>? tagWeights,
    double? mean = 7.5,
    int sampleSize = 40,
    int recentCount = 5,
  }) => <String, dynamic>{
    'type_weights': typeWeights ?? <String, dynamic>{'anime': 1.0, 'novel': 0.3},
    'tag_weights': tagWeights ?? <String, dynamic>{'科幻': 1.0, '群像': 0.5},
    'rating_tendency': <String, dynamic>{
      'mean': mean,
      'count': mean == null ? 0 : 12,
      'dist': List<int>.filled(10, 0),
    },
    'recent_active': List<String>.generate(recentCount, (i) => 'w-$i'),
    'sample_size': sampleSize,
    'generated_at': '2026-11-07T00:00:00Z',
  };

  test('没有任何行为：不画六边形，走空态', () {
    final insight = PersonaInsightMapper.fromProfile(profile(sampleSize: 0));

    // 「全是 0 的六边形」看起来像「你的口味是零」，比空态更糟。
    expect(insight.dimensions, isEmpty);
    expect(insight.title, isEmpty);
    expect(insight.review, isEmpty);
  });

  test('典型画像：六轴齐全，称号与锐评都能追溯到字段', () {
    final insight = PersonaInsightMapper.fromProfile(profile());

    expect(insight.dimensions.length, 6);
    expect(insight.title, '科幻派');
    expect(insight.review, contains('动画')); // type_weights 的最强项
    expect(insight.review, contains('科幻')); // tag_weights 的最强正项
    expect(insight.review, contains('均分 7.5'));
    expect(insight.topTags, <String>['科幻', '群像']);

    // 类型集中度 = 1.0 / (1.0 + 0.3)
    expect(axis(insight, '类型集中度').value, closeTo(0.769, 0.001));
    // 近期活跃 = 5 / 20
    expect(axis(insight, '近期活跃').value, closeTo(0.25, 0.001));
  });

  test('没打过分的用户：少一根轴，而不是画一根 0', () {
    final insight = PersonaInsightMapper.fromProfile(profile(mean: null));

    expect(insight.dimensions.length, 5);
    expect(
      insight.dimensions.map((d) => d.label),
      isNot(contains('评分态度')),
    );
    expect(insight.review, isNot(contains('均分')));
  });

  test('权重全零：不除零、不产生 NaN', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(
        typeWeights: <String, dynamic>{'anime': 0.0, 'novel': 0.0},
        tagWeights: <String, dynamic>{'科幻': 0.0},
      ),
    );

    expect(axis(insight, '类型集中度').value, 0);
    expect(axis(insight, '口味浓度').value, 0);
    // NaN 会让 Canvas 静默不画那根轴，看起来像「没数据」，事后极难查。
    for (final dimension in insight.dimensions) {
      expect(dimension.value.isFinite, isTrue, reason: '${dimension.label} 出现了 NaN');
    }
  });

  test('只有一个正标签：口味浓度拉满', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(tagWeights: <String, dynamic>{'科幻': 1.0}),
    );

    expect(axis(insight, '口味浓度').value, 1);
  });

  test('负权重是「不喜欢」：不当称号、不进偏好标签、不进锐评', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(tagWeights: <String, dynamic>{'后宫': -0.9, '科幻': 0.2}),
    );

    expect(insight.title, '科幻派');
    expect(insight.topTags, <String>['科幻']);
    expect(insight.review, isNot(contains('后宫')));
  });

  test('只有负标签：称号回落到类型，不拿负标签凑', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(tagWeights: <String, dynamic>{'后宫': -0.9}),
    );

    expect(insight.title, '动画观众');
    expect(insight.topTags, isEmpty);
  });

  test('行为太少：不生成称号，锐评只鼓励多看', () {
    final insight = PersonaInsightMapper.fromProfile(profile(sampleSize: 3));

    expect(insight.title, isEmpty);
    expect(insight.review, contains('看得还不够多'));
    // 有行为就照常画轴，只是不下定义。
    expect(insight.dimensions, isNotEmpty);
  });

  test('打分很严 / 很宽容都算「有态度」，两端都拉满', () {
    double attitude(double mean) =>
        axis(PersonaInsightMapper.fromProfile(profile(mean: mean)), '评分态度')
            .value;

    expect(attitude(1.0), 1);
    expect(attitude(10.0), 1);
    expect(attitude(5.5), 0); // 正好中位 = 没有倾向
  });

  test('近期活跃按契约上限 20 折算', () {
    final insight = PersonaInsightMapper.fromProfile(profile(recentCount: 20));

    expect(axis(insight, '近期活跃').value, 1);
  });

  test('字段类型不对：退化为空态，不抛异常', () {
    final insight = PersonaInsightMapper.fromProfile(<String, dynamic>{
      'type_weights': 'oops',
      'tag_weights': <String, dynamic>{'科幻': 'high'},
      'rating_tendency': 'oops',
      'recent_active': 'oops',
      'sample_size': '40',
    });

    // sample_size 解析不出 → 0 → 空态。契约坏了宁可显示空，也不要画出乱码。
    expect(insight.dimensions, isEmpty);
    expect(insight.title, isEmpty);
  });
}
