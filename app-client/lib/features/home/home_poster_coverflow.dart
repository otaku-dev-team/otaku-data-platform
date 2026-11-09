import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/models/work_summary.dart';
import '../../shared/widgets/cover_image.dart';
import 'home_poster_data_source.dart';

/// 首页 hero 海报 Coverflow（#562）。
///
/// 一屏可见 5 张（C 位 + 左右各 2），最多 12 条，左右可切。
///
/// **切换是纯前端状态**：不写库、不回传、不请求服务端。所有访客看到同一份
/// 名单，但各切各的——这是首站明确的分层，不要在端上「记住上次看到第几张」。
///
/// 三条边界（都是「看起来像 bug」的那种）：
/// 1. **不足 12 条就少几张**，不循环补位、不拿占位图凑满；
/// 2. **0 条直接隐藏整块**——hero 位上一块空白比没有 hero 更难看；
/// 3. **顺序照接口返回**，不重排、不随机。
class HomePosterCoverflow extends ConsumerStatefulWidget {
  const HomePosterCoverflow({super.key});

  @override
  ConsumerState<HomePosterCoverflow> createState() =>
      _HomePosterCoverflowState();
}

class _HomePosterCoverflowState extends ConsumerState<HomePosterCoverflow> {
  /// 一屏 5 张：1 / 5。
  static const double _viewportFraction = 0.2;

  final PageController _controller = PageController(
    viewportFraction: _viewportFraction,
  );
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final posters = ref.watch(homePostersProvider).value;
    // 加载中 / 失败 / 空数组都不占位：hero 是装饰位，不能把首屏顶下去。
    if (posters == null || posters.isEmpty) return const SizedBox.shrink();

    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return SizedBox(
      height: 190 * textScale.clamp(1.0, 1.4),
      child: PageView.builder(
        controller: _controller,
        itemCount: posters.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          final work = posters[index];
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final page = _controller.hasClients &&
                      _controller.position.hasContentDimensions
                  ? _controller.page ?? _index.toDouble()
                  : _index.toDouble();
              final delta = (page - index).abs().clamp(0.0, 2.0);
              // C 位满尺寸，两侧缩小并变淡；不做 3D 旋转，窄屏上会糊。
              final scale = 1 - 0.14 * delta;
              final opacity = (1 - 0.28 * delta).clamp(0.35, 1.0);
              return Transform.scale(
                scale: scale,
                child: Opacity(opacity: opacity, child: child),
              );
            },
            child: _PosterCard(
              work: work,
              onTap: () {
                if (index == _index) {
                  context.push(RoutePaths.workDetail(work.workId));
                } else {
                  // 点侧边那张只把它转到中间，不直接跳详情——
                  // 想看细节的人会再点一次，避免误触。
                  _controller.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                  );
                }
              },
            ),
          );
        },
      ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.work, required this.onTap});

  final WorkSummary work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: Radii.circularMd(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CoverImage(
                url: work.coverUrl,
                width: double.infinity,
                height: double.infinity,
                radius: 0,
                placeholderLabel: work.title,
              ),
              // 底部渐变保证白字可读；不靠阴影，浅色封面上阴影不够。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x00000000), Color(0xB3000000)],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        work.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (work.mainRating != null)
                        Text(
                          work.mainRating!.value.toStringAsFixed(1),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
