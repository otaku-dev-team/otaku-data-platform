/// #375 / #376 的演示数据。
///
/// **只用于开发期看版式**，不是接口样本、不是契约、不入库、不进生产。
/// `USE_MOCK=true`（默认）与 #375 画像页仍在用它：#376 推荐位在
/// `USE_MOCK=false` 时已改走 `/api/me/recommend`（见 `persona_data_source.dart`），
/// 但画像页的展示口径未定，这份还不能删。
/// 作品条目是虚构的，`workId` 前缀 `shell-` 便于一眼看出来源，
/// 不会和真实 `work_id` 撞上。
library;

import '../../data/models/source_rating.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import 'persona_view_data.dart';

const PersonaInsight kShellPersonaInsight = PersonaInsight(
  title: '深夜考据派',
  review:
      '你的收藏像是把「设定集」当睡前读物：冷门、慢热、但考据密度高。'
      '比起一口气刷完，你更愿意在一部作品里多停一会儿。'
      '偶尔也给自己留一部轻松的，别把追番做成功课。',
  dimensions: <PersonaDimension>[
    PersonaDimension(label: '深度', value: 0.86, caption: '设定与考据'),
    PersonaDimension(label: '热度', value: 0.42, caption: '主流话题'),
    PersonaDimension(label: '广度', value: 0.71, caption: '题材跨度'),
    PersonaDimension(label: '忠诚度', value: 0.78, caption: '追完率'),
    PersonaDimension(label: '尝鲜', value: 0.55, caption: '新番占比'),
    PersonaDimension(label: '社交', value: 0.34, caption: '讨论参与'),
  ],
  topTags: <String>['科幻', '架空历史', '群像', '日常', '悬疑'],
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
