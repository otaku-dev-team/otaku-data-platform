import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/theme/library_density.dart';
import '../../data/models/work_summary.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../contents/work_card.dart';
import 'studio_data_source.dart';

/// 制作公司页（#557 / #558）。
///
/// 入口是详情页「制作公司」那一行——以前是纯文本，点不动。
///
/// 口径照首站：标题 = 公司名，下面「本站收录 N 部该制作公司的作品（按评分排序）」，
/// 再下面是海报卡网格。**查不到就 404，不造空态页**：空态会让人以为
/// 「这家公司存在但一部都没有」，而实际是名字打错了或没有收录。
class StudioPageWidget extends ConsumerStatefulWidget {
  const StudioPageWidget({super.key, required this.name});

  final String name;

  @override
  ConsumerState<StudioPageWidget> createState() => _StudioPageWidgetState();
}

class _StudioPageWidgetState extends ConsumerState<StudioPageWidget> {
  static const int _pageSize = 60;

  final ScrollController _scrollController = ScrollController();

  final List<WorkSummary> _items = <WorkSummary>[];
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _notFound = false;
  ApiException? _error;

  bool get _hasMore => _items.length < _total;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    // 提前 400px 触发，和作品库同一手感。
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
      _notFound = false;
    });
    try {
      final page = await ref
          .read(studioDataSourceProvider)
          .fetch(widget.name, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notFound = error.code == ApiErrorCode.studioNotFound;
        _error = _notFound ? null : error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = const ApiException(
          code: ApiErrorCode.unknown,
          message: '暂时取不到这家公司的作品',
        );
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(studioDataSourceProvider)
          .fetch(widget.name, limit: _pageSize, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 翻页失败不清空已看内容，只停在这一页（与作品库同一口径）。
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没加载出更多，稍后再试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: Text(widget.name)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const SizedBox(height: 420, child: SkeletonGrid());
    }
    if (_notFound) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 44,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: Space.s3),
              Text('没有找到这家制作公司', style: theme.textTheme.titleSmall),
              const SizedBox(height: Space.s1),
              Text(
                '名字是精确匹配的，大小写也要一致。\n回上一页换个作品再点一次。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return ErrorState(error: _error!, onRetry: _loadFirstPage);
    }
    if (_items.isEmpty) {
      // 200 + 空数组：公司在、但当前没有可见作品（成人/下架剔除后）。
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.s6),
          child: Text(
            '这家公司暂时没有可展示的作品。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = AppLayout.gridMetrics(constraints.maxWidth);
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final extent = AppLayout.gridCellExtent(
          cardWidth: metrics.cardWidth,
          density: LibraryDensity.comfort,
          textScale: textScale,
        );

        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppLayout.pagePadding,
                  Space.s3,
                  AppLayout.pagePadding,
                  Space.s2,
                ),
                child: Text(
                  '本站收录 $_total 部该制作公司的作品（按评分排序）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppLayout.pagePadding,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: metrics.columns,
                  mainAxisExtent: extent,
                  crossAxisSpacing: AppLayout.gridGap,
                  mainAxisSpacing: AppLayout.gridGap,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => WorkCard(
                    work: _items[index],
                    density: LibraryDensity.comfort,
                    heroTag: 'studio-$index',
                  ),
                  childCount: _items.length,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s4),
                child: Center(
                  child: _loadingMore
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _hasMore ? '继续下滑加载更多' : '已经到底了',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
