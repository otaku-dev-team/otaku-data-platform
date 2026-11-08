import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/features/persona/persona_insight_mapper.dart';
import 'package:otaku_app/features/persona/persona_view_data.dart';

/// #375 / #498 画像映射：`PersonaProfile` → `PersonaInsight`。
///
/// 全是纯函数断言，不搭 widget。**这里钉的是「客户端不再自造轴」**：
/// 九维的值必须与接口一模一样（只除以 100），任何一根轴出现公式，
/// 两端之间就又分家了。
void main() {
  PersonaDimension axis(PersonaInsight insight, String label) =>
      insight.dimensions.firstWhere((d) => d.label == label);

  Map<String, dynamic> profile({
    Map<String, dynamic>? dimensions,
    int sampleSize = 40,
    String heroTitle = '赛博貔貅',
    String heroCode = 'PIXIU',
    String heroNote = '别人追番看剧情，你追番看注释。',
    String quip = '你的收藏比简历还整齐。',
    List<String>? tags,
    Map<String, String>? blurbs,
    Map<String, dynamic>? rarity,
  }) => <String, dynamic>{
    'type_weights': <String, dynamic>{'anime': 1.0},
    'tag_weights': <String, dynamic>{'科幻': 1.0},
    'rating_tendency': <String, dynamic>{
      'mean': 7.5,
      'count': 12,
      'dist': List<int>.filled(10, 0),
    },
    'recent_active': <String>['w-1'],
    'sample_size': sampleSize,
    'dimensions':
        dimensions ??
        <String, dynamic>{
          'tag_focus': 72,
          'exploration': 64,
          'mainstream': 38,
          'pop_spread': 71,
          'quality': 83,
          'era_span': 56,
          'fresh': 45,
          'emotion': 31,
          'completion': 68,
        },
    'persona_tags': tags ?? <String>['科幻系', '番剧党', '考据癖'],
    'trait_blurbs':
        blurbs ??
        <String, String>{
          '科幻系': '设定比剧情更让你上头。',
          '番剧党': '主要还是看动画。',
          '考据癖': '看完去补设定集。',
        },
    'hero_title': heroTitle,
    'hero_code': heroCode,
    'hero_note': heroNote,
    'final_quip': quip,
    'rarity':
        rarity ??
        <String, dynamic>{
          'tier': 'SR',
          'label': '不算常见',
          'note': '一百个人里只有几个这么挑。',
          'share': 6.4,
        },
    'generated_at': '2026-11-09T00:00:00Z',
  };

  test('没有任何行为：不画九边形，走空态', () {
    final insight = PersonaInsightMapper.fromProfile(profile(sampleSize: 0));

    // 「九边全是 50」看起来像「你各方面都很平均」，比空态更糟。
    expect(insight.dimensions, isEmpty);
    expect(insight.title, isEmpty);
    expect(insight.review, isEmpty);
  });

  test('九维齐全：顺序固定，值 = 接口 0–100 / 100', () {
    final insight = PersonaInsightMapper.fromProfile(profile());

    expect(insight.dimensions, hasLength(9));
    expect(
      insight.dimensions.map((d) => d.label).toList(),
      <String>[
        '题材垂直',
        '探索广度',
        '大众度',
        '冷热跨度',
        '高分率',
        '年代跨度',
        '追新度',
        '情绪取向',
        '完成度',
      ],
    );
    // 逐值比对：任何「端上再算一遍」的改动都会在这里露馅。
    expect(axis(insight, '题材垂直').value, closeTo(0.72, 1e-9));
    expect(axis(insight, '大众度').value, closeTo(0.38, 1e-9));
    expect(axis(insight, '完成度').value, closeTo(0.68, 1e-9));
  });

  test('轴序与契约键序一致（分享参数按下标对应，不能重排）', () {
    expect(
      PersonaInsightMapper.axes.map((a) => a.key).toList(),
      <String>[
        'tag_focus',
        'exploration',
        'mainstream',
        'pop_spread',
        'quality',
        'era_span',
        'fresh',
        'emotion',
        'completion',
      ],
    );
  });

  test('缺一维：按中性 50（=0.5）降级，不能画成 0', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(
        dimensions: <String, dynamic>{
          'tag_focus': 72,
          // 其余八个全缺
        },
      ),
    );

    expect(insight.dimensions, hasLength(9));
    expect(axis(insight, '题材垂直').value, closeTo(0.72, 1e-9));
    // 0 会是雷达图上的一个凹角，看起来像「你这方面很弱」。
    expect(axis(insight, '完成度').value, closeTo(0.5, 1e-9));
  });

  test('值越界 / 类型不对：夹到 0..1，不产生 NaN', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(
        dimensions: <String, dynamic>{
          'tag_focus': 130,
          'exploration': -20,
          'mainstream': '38', // 字符串数字照解析
          'quality': 'oops', // 解析不了 → 中性
        },
      ),
    );

    expect(axis(insight, '题材垂直').value, 1.0);
    expect(axis(insight, '探索广度').value, 0.0);
    expect(axis(insight, '大众度').value, closeTo(0.38, 1e-9));
    expect(axis(insight, '高分率').value, closeTo(0.5, 1e-9));
    for (final dimension in insight.dimensions) {
      expect(dimension.value.isFinite, isTrue, reason: '${dimension.label} 出现了 NaN');
    }
  });

  test('称号三件套 + 稀有度原样透传', () {
    final insight = PersonaInsightMapper.fromProfile(profile());

    expect(insight.title, '赛博貔貅');
    expect(insight.titleCode, 'PIXIU');
    expect(insight.review, contains('看注释'));
    expect(insight.quip, '你的收藏比简历还整齐。');
    expect(insight.rarity?.tier, 'SR');
    expect(insight.rarity?.label, '不算常见');
    expect(insight.rarity?.share, 6.4);
  });

  test('稀有度 share=null 保留 null——写成 0% 会变成最稀有', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(
        rarity: <String, dynamic>{
          'tier': '?',
          'label': '未标定',
          'share': null,
        },
      ),
    );

    expect(insight.rarity?.tier, '?');
    expect(insight.rarity?.share, isNull);
    expect(insight.rarity?.isCalibrated, isFalse);
  });

  test('稀有度缺失：不画徽章，不编一个默认档', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(rarity: <String, dynamic>{}),
    );
    expect(insight.rarity, isNull);
  });

  test('标签与解读：最多 5 个、空串剔除、键一一对应', () {
    final insight = PersonaInsightMapper.fromProfile(
      profile(
        tags: <String>['科幻系', '番剧党', '考据癖', '冷门', '慢热', '第六个', '  '],
        blurbs: <String, String>{
          '科幻系': '设定党',
          '番剧党': '  ',
          '考据癖': '补年表',
        },
      ),
    );

    expect(insight.topTags, hasLength(5));
    expect(insight.topTags, isNot(contains('第六个')));
    // 空串 = 没有文案，不占一行（页面按它决定是否画解读）。
    expect(insight.traitBlurbs.containsKey('番剧党'), isFalse);
    expect(insight.traitBlurbs['科幻系'], '设定党');
  });

  test('样本不足 5 条：解释形状为什么靠中间；够 5 条就不解释', () {
    final few = PersonaInsightMapper.fromProfile(profile(sampleSize: 3));
    expect(few.hints, hasLength(1));
    expect(few.hints.single, contains('3 条'));
    // 有行为照常画轴，只是补一句说明。
    expect(few.dimensions, hasLength(9));

    expect(PersonaInsightMapper.fromProfile(profile()).hints, isEmpty);
  });

  test('字段类型全错：降级但不崩', () {
    final insight = PersonaInsightMapper.fromProfile(<String, dynamic>{
      'dimensions': 'oops',
      'persona_tags': 'oops',
      'trait_blurbs': <String>['oops'],
      'rarity': 'oops',
      'hero_title': 42,
      'sample_size': '40',
    });

    // sample_size 能解析 → 有画像；其余字段降级，九维按中性补满。
    expect(insight.dimensions, hasLength(9));
    expect(insight.dimensions.every((d) => d.value == 0.5), isTrue);
    expect(insight.title, isEmpty);
    expect(insight.topTags, isEmpty);
    expect(insight.rarity, isNull);
  });
}
