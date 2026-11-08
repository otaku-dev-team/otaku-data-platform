/// #375 / #376 的演示数据。
///
/// **只用于开发期看版式**，不是接口样本、不是契约、不入库、不进生产。
/// `USE_MOCK=true`（默认）时画像页与推荐位都用它；`USE_MOCK=false` 时两者
/// 都改走真接口（`/api/me/profile` / `/api/me/recommend`）。留着是为了
/// 不连后端也能看版式——**字段形状必须跟契约一致**，否则开发期看到的
/// 和真机不是同一套（九维、称号三件套、稀有度都要有）。
/// 作品条目是虚构的，`workId` 前缀 `shell-` 便于一眼看出来源，
/// 不会和真实 `work_id` 撞上。
library;

import '../../data/models/source_rating.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import 'persona_view_data.dart';

const PersonaInsight kShellPersonaInsight = PersonaInsight(
  title: '赛博貔貅',
  titleCode: 'PIXIU',
  review:
      '你的收藏像是把「设定集」当睡前读物：冷门、慢热、但考据密度高。'
      '比起一口气刷完，你更愿意在一部作品里多停一会儿。',
  quip: '别人追番看剧情，你追番看注释。',
  // 九维按契约键序排（tag_focus → completion），值 0–1 = 接口 0–100 / 100。
  dimensions: <PersonaDimension>[
    PersonaDimension(label: '题材垂直', value: 0.72, caption: '最爱题材覆盖'),
    PersonaDimension(label: '探索广度', value: 0.64, caption: '题材种类'),
    PersonaDimension(label: '大众度', value: 0.38, caption: '站内热度'),
    PersonaDimension(label: '冷热跨度', value: 0.71, caption: '冷门与热门'),
    PersonaDimension(label: '高分率', value: 0.83, caption: '高分占比'),
    PersonaDimension(label: '年代跨度', value: 0.56, caption: '年代分布'),
    PersonaDimension(label: '追新度', value: 0.45, caption: '近五年'),
    PersonaDimension(label: '情绪取向', value: 0.31, caption: '治愈 / 致郁'),
    PersonaDimension(label: '完成度', value: 0.68, caption: '追完比例'),
  ],
  // 前两位位置固定：[0] 题材簇、[1] 主身份，特征从 [2] 开始。
  topTags: <String>['科幻系', '番剧党', '考据癖'],
  traitBlurbs: <String, String>{
    '科幻系': '设定比剧情更让你上头，软硬都吃。',
    '番剧党': '主要还是看动画，其他类型是配菜。',
    '考据癖': '看完第一件事是去补设定集和年表。',
  },
  // #490 口径：SSR 金 / SR 蓝 / R 灰 / N 浅灰 / 未标定 ?。share 可以为 null。
  rarity: PersonaRarity(
    tier: 'SR',
    label: '不算常见',
    note: '一百个人里只有几个这么挑。',
    share: 6.4,
  ),
  // 刻意不给 tone / boundAccount：这两个值还没接口，界面要练「取不到」的展示。
);

/// 首页个性化区块的演示作品。
const List<RecommendedWork> kShellRecommendations = <RecommendedWork>[
  RecommendedWork(
    work: WorkSummary(
      workId: 'shell-001',
      workType: WorkType.anime,
      title: '银河边缘的旧书店',
      releaseYear: 2024,
      tags: <String>['科幻', '日常'],
      mainRating: SourceRating(value: 8.4, scale: '0-10', source: 'shell'),
      source: 'shell',
    ),
    reasons: <String>['你偏爱的科幻题材', '和你收藏的设定系作品相近'],
  ),
  RecommendedWork(
    work: WorkSummary(
      workId: 'shell-002',
      workType: WorkType.anime,
      title: '雨夜考据部',
      releaseYear: 2023,
      tags: <String>['悬疑', '群像'],
      mainRating: SourceRating(value: 8.1, scale: '0-10', source: 'shell'),
      source: 'shell',
    ),
    reasons: <String>['标签偏好命中：群像', '近期同类作品里评分较高'],
  ),
  RecommendedWork(
    work: WorkSummary(
      workId: 'shell-003',
      workType: WorkType.comic,
      title: '长街纪事',
      releaseYear: 2022,
      tags: <String>['架空历史'],
      mainRating: SourceRating(value: 8.7, scale: '0-10', source: 'shell'),
      source: 'shell',
    ),
    reasons: <String>['你常看的架空历史'],
  ),
  RecommendedWork(
    work: WorkSummary(
      workId: 'shell-004',
      workType: WorkType.novel,
      title: '第七封未寄出的信',
      releaseYear: 2025,
      tags: <String>['日常', '悬疑'],
      mainRating: SourceRating(value: 7.9, scale: '0-10', source: 'shell'),
      source: 'shell',
    ),
    reasons: <String>['慢热叙事，和你的追完率很搭'],
  ),
  RecommendedWork(
    work: WorkSummary(
      workId: 'shell-005',
      workType: WorkType.game,
      title: '白昼之下',
      releaseYear: 2024,
      tags: <String>['科幻', '群像'],
      mainRating: SourceRating(value: 8.2, scale: '0-10', source: 'shell'),
      source: 'shell',
    ),
    reasons: <String>['题材偏好命中', '同类作品里近期较活跃'],
  ),
];
