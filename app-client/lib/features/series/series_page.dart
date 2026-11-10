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
import 'series_data_source.dart';

/// 系列页（#557 / #568 P2）。入口是详情页「系列作品」区的标题 / 「查看全部」。
///
/// 口径照首站，但修掉它的一个 bug：首站头部写「共 `len(contents)` 部作品」，
/// 而 `contents` 已被 `limit=60` 截断，超过 60 部的系列数字就是错的。
/// 我们用服务端单独给的 `total`。
///
/// `name` 可能为 null（作品先到、系列行后到）：退化成「系列」二字，
/// **不拿 key 顶替**——那是来源站内部 id，对用户没有意义。
class SeriesPageWidget extends ConsumerStatefulWidget {
  const SeriesPageWidget({super.key, required this.seriesKey});

  /// 系列键，不透明字符串。
  ///
  /// 字段名不能叫 `key`：那会与 Flutter `Widget.key` 撞成非法覆盖。
  final String seriesKey;

  @override
  ConsumerState<SeriesPageWidget> createState() => _SeriesPageWidgetState();
}

class _SeriesPageWidgetState extends ConsumerState<SeriesPageWidget> {
  static const int _pageSize = 60;

  final ScrollController _scrollController = ScrollController();

  final List<WorkSummary> _items = <WorkSummary>[];
  String? _name;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _notFound = false;
  ApiException? _error;

  bool get _hasMore => _items.length < _total;

  String get _title => _name ?? '系列';

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
          .read(seriesDataSourceProvider)
          .fetchPage(widget.seriesKey, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _name = page.name;
        _total = page.total;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      // 线上 404 信封是 SERIES_NOT_FOUND；服务端没按信封返回时按状态码兜底。
      final notFound =
          error.code == ApiErrorCode.seriesNotFound || error.statusCode == 404;
      setState(() {
        _loading = false;
        _notFound = notFound;
        _error = notFound ? null : error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = const ApiException(
          code: ApiErrorCode.unknown,
          message: '暂时取不到这个系列的作品',
        );
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(seriesDataSourceProvider)
          .fetchPage(widget.seriesKey, limit: _pageSize, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _name = page.name ?? _name;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 翻页失败不清空已看内容，只停在这一页（与公司页同一口径）。
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
        appBar: AppBar(title: Text(_title)),
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
              Text('没有找到这个系列', style: theme.textTheme.titleSmall),
              const SizedBox(height: Space.s1),
              Text(
                '可能是这个系列还没有收录作品。\n回上一页换个作品再点一次。',
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.s6),
          child: Text(
            '这个系列暂时没有可展示的作品。',
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
                  '本站收录 $_total 部该系列的作品（按评分排序）',
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
                    heroTag: 'series-$index',
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
