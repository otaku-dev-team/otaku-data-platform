import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/platform_info.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/collection_entry.dart';
import '../../data/models/work.dart';
import '../../data/repositories/work_repository.dart';
import '../../shared/widgets/collection_status_menu.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/desktop_shortcuts.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/offline_notice.dart';
import '../../shared/widgets/rating_badge.dart';
import '../../shared/widgets/release_year_text.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../../shared/widgets/tag_chips.dart';
import '../../shared/widgets/work_type_tag.dart';
import '../auth/auth_controller.dart';
import '../contents/contents_controller.dart';
import '../recent/recent_views_controller.dart';
import 'related_works_section.dart';
import 'work_collection_controller.dart';
import 'work_credits_section.dart';
import 'work_detail_controller.dart';

/// 作品详情。契约 6.2 / 6.3：
/// - 404 → 提示 + 返回列表，**不自动重试**；
/// - `summary` 为 null → "暂无简介"，超长时折叠；
/// - `main_rating`、`tags` 为空 → 对应区块不渲染。
///
/// 版面顺序：封面 + 标题 + 分类评分 → 别名 / 制作公司 → 简介 →
/// 制作人员 → 角色与声优 → 相关作品。
/// （收录信息那一段已下线：作品 ID / 来源 ID 是排障用的，不给用户看。）
///
/// 制作人员与角色与声优 2026-10-29 才接上（Issue #256）：后端富字段与关系四表
/// 上线前，契约里根本没有这两块，当时**不摆空位**是对的；现在数据到位才补。
/// 两块都是「有才有」——动画里约三分之二的作品没有，那是数据事实不是缺陷，
/// 所以空态是不渲染整块，而不是挂一个「暂无」。
class WorkDetailPage extends ConsumerStatefulWidget {
  const WorkDetailPage({super.key, required this.workId});

  final String workId;

  @override
  ConsumerState<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends ConsumerState<WorkDetailPage> {
  /// 详情 provider 的订阅。`listenManual` 不会被框架自动回收，必须自己关。
  late final ProviderSubscription<AsyncValue<Fetched<Work>>> _detailSub;

  @override
  void initState() {
    super.initState();

    // 记「最近浏览」的时机：**详情数据到手**才算看过，加载失败与 404 都不记
    // （把打不开的页面记进历史，只会让人再点一次还是打不开）。
    //
    // 用 `listenManual` 而不是 build 里的 `ref.listen`：前者可以挂在 initState，
    // 且回调发生在 provider 变化之后而不是构建期间，能安全地写另一个 provider。
    _detailSub = ref.listenManual<AsyncValue<Fetched<Work>>>(
      workDetailProvider(widget.workId),
      (previous, next) {
        final work = next.value?.value;
        if (work != null) _remember(work);
      },
    );

    // provider 不自动销毁，所以「从列表第二次点进同一部作品」不会产生值变化，
    // 上面那个订阅不会再触发。这里补记一次，否则「最近浏览」的顺序会停在
    // 第一次打开的时间上（A → B → 再回 A，A 还排在 B 后面）。
    final existing = ref.read(workDetailProvider(widget.workId)).value?.value;
    if (existing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _remember(existing);
      });
    }
  }

  @override
  void dispose() {
    _detailSub.close();
    super.dispose();
  }

  /// 记一次浏览。重复记录是幂等的（去重 + 置顶），所以补记不会产生两条。
  void _remember(Work work) =>
      ref.read(recentViewsProvider.notifier).record(work);

  /// 点详情页的标签：跳到作品库并按该标签筛。
  ///
  /// 用 `showTag` 而不是 `selectTag`：后者是「在当前条件下换个标签」，
  /// 而这里是从另一页跳过来，用户要的是「这个标签下都有什么」——上一页
  /// 留下的分类或关键词会让结果莫名只剩几条，详情页上没有任何线索能解释。
  ///
  /// 没有 router 时（单页测试）只改条件、不抛异常，与侧栏导航同一处理。
  void _openTag(String tag) {
    ref.read(contentsFilterProvider.notifier).showTag(tag);
    GoRouter.maybeOf(context)?.go(RoutePaths.contents);
  }

  @override
  Widget build(BuildContext context) {
    final fetched = ref.watch(workDetailProvider(widget.workId));
    // `Fetched` 包了一层，这里拆出来：页面正文只关心作品本身，
    // 「是不是缓存」只影响顶部那一条提示。
    final work = fetched.value;

    return DesktopShortcuts(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('作品详情'),
          actions: [
            // source_url 为 null 时**什么都不渲染**：不放置灰按钮。
            // 一个点不动的图标比没有图标更让人困惑（Issue #68 验收第 2 条）。
            //
            // 渲染前再过一次 parseSourceUrl，而不是直接用 `work.sourceUrl`：
            // 前者只保证「从 JSON 解析出来的值」安全，而 Work 也可能被测试或
            // 本地 mock 直接构造。这道闸放在出口，覆盖所有来源。
            if (Work.parseSourceUrl(work?.value.sourceUrl) case final url?)
              IconButton(
                tooltip: '在来源站查看',
                onPressed: () => _openSource(context, url),
                icon: const Icon(Icons.open_in_new_rounded),
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppLayout.detailMaxWidth,
            ),
            child: _buildBody(context, ref, fetched),
          ),
        ),
      ),
    );
  }

  /// 用系统浏览器打开来源站人读页。
  ///
  /// 不在应用内嵌 WebView：来源站是独立站点，嵌进来既没有会话也没有它的导航，
  /// 而且会把「应用返回」和「网页返回」两套手势混在一起。
  ///
  /// 打不开时**必须说出来**：桌面端没有配置浏览器关联时 `launchUrl` 返回 false，
  /// 静默失败会让用户以为按钮坏了。
  static Future<void> _openSource(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('打不开来源页，请检查系统默认浏览器')),
      );
    }
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<Fetched<Work>> fetched,
  ) {
    final work = fetched.value;
    if (fetched.isLoading && work == null) {
      return const SkeletonDetail();
    }

    if (fetched.hasError) {
      final error = ApiException.fromAny(fetched.error);
      if (error.isNotFound) {
        return ErrorState(
          error: error,
          title: '作品不存在',
          action: OutlinedButton(
            onPressed: () => _backToList(context),
            child: const Text('返回列表'),
          ),
        );
      }
      return ErrorState(
        error: error,
        onRetry: () => ref.invalidate(workDetailProvider(widget.workId)),
      );
    }

    final resolved = fetched.requireValue;
    final body = _DetailBody(work: resolved.value, onTag: _openTag);
    if (!resolved.fromCache) return body;

    // 离线回退：内容照常展示，但顶部要说明这是上次同步的。
    // 不说的话，用户会把旧数据当成最新的（铁律 3）。
    return Column(
      children: [
        OfflineNotice(
          cachedAt: resolved.cachedAt,
          onRetry: () => ref.invalidate(workDetailProvider(widget.workId)),
        ),
        Expanded(child: body),
      ],
    );
  }

  void _backToList(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RoutePaths.contents);
    }
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.work, required this.onTag});

  final Work work;

  /// 点标签时回调，一路传到 [_Headline] 里的标签行。
  final ValueChanged<String> onTag;

  @override
  Widget build(BuildContext context) {
    // 手机端：整屏宽的沉浸式头图，下面才是标签 / 收藏 / 简介。
    // 桌面端保持原来的「封面 + 标题/信息」两栏（窄窗口退化为单列）——
    // 桌面首屏更看重信息密度，不套头图。
    if (!PlatformInfo.isDesktop) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DetailHero(work: work),
            Padding(
              padding: const EdgeInsets.all(AppLayout.pagePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailInfo(work: work, onTag: onTag),
                  const SizedBox(height: 20),
                  // 收录信息（作品 ID / 来源 ID / 收录更新）不再展示：
                  // 那是溯源和排障用的，普通用户看完这部作品并不需要知道
                  // 它在库里叫什么编号。需要时从接口和日志里查。
                  RelatedWorksSection(workId: work.workId),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppLayout.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final cover = CoverImage(
                url: work.coverUrl,
                width: AppLayout.detailCoverWidth,
                height: AppLayout.detailCoverHeight,
                radius: 14,
              );

              if (constraints.maxWidth < AppLayout.twoColumnBreakpoint) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: cover),
                    const SizedBox(height: 20),
                    _Headline(work: work, onTag: onTag),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  cover,
                  const SizedBox(width: 28),
                  Expanded(child: _Headline(work: work, onTag: onTag)),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          // 相关推荐：正文之后唯一的延伸阅读。收录信息已不再展示（见手机端
          // 那段注释）。拿不到或没标签时组件自己渲染成 SizedBox.shrink()。
          RelatedWorksSection(workId: work.workId),
        ],
      ),
    );
  }
}

/// 标题区：标题 / 类型 / 评分 / 标签 / 简介。
class _Headline extends StatelessWidget {
  const _Headline({required this.work, required this.onTag});

  final Work work;

  final ValueChanged<String> onTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          work.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            WorkTypeTag(type: work.workType),
            ReleaseYearText(year: work.releaseYear),
            RatingBadge(rating: work.mainRating),
            if (work.mainRating != null)
              Text(
                // 契约里的尺度是 `0-10`，站点写的是「满分 10 分」——取上界即可。
                '满分 ${work.mainRating!.scale.split('-').last} 分',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _DetailInfo(work: work, onTag: onTag),
      ],
    );
  }
}

/// 标签 / 收藏 / 简介。
///
/// 手机端放在头图下方，桌面端放在标题与元信息下方——两种形态共用这一份，
/// 否则「收藏按钮」和「简介」会在两端各写一遍、逐渐长歪。
class _DetailInfo extends StatelessWidget {
  const _DetailInfo({required this.work, required this.onTag});

  final Work work;

  final ValueChanged<String> onTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = work.tags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tags != null) ...[
          // 标签可点：列表卡片上的标签早就能这么用（#107），同一批标签在
          // 详情页却是死文字——同一个东西两处行为不一致，用户会以为详情页坏了。
          TagChips(tags: tags, maxVisible: 10, onTag: onTag),
          const SizedBox(height: 16),
        ],
        _CollectBar(work: work),
        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 16),
        // 别名 / 制作公司：两个都是"有才有"的元信息，缺失时整行不出现。
        //
        // 别名 2026-10-29 起已是干净的字符串数组（Issue #273 把空壳 `{\n}`
        // 洗成了 `[]`），所以这里直接 join，不用再防一整段带花括号的文本。
        if (work.aliases case final aliases? when aliases.isNotEmpty)
          MetaLine(label: '又名', value: aliases.join(' / ')),
        if (work.studios case final studios? when studios.isNotEmpty)
          MetaLine(label: '制作公司', value: studios.join(' × ')),
        Text(
          '简介',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _SummaryBlock(text: work.summary),
        // 制作人员 / 角色与声优：有数据才渲染（组件内部判空），
        // 间距跟着渲染一起出现，避免空区块前后留下两段说不清的空白。
        // 单部最多 288 条，折叠由组件内部处理。
        if (work.staff case final staff? when staff.isNotEmpty) ...[
          const SizedBox(height: 20),
          StaffSection(staff: staff),
        ],
        if (work.characters case final characters? when characters.isNotEmpty) ...[
          const SizedBox(height: 20),
          CharacterSection(characters: characters),
        ],
      ],
    );
  }
}

/// 手机端沉浸式头图：封面铺满、底部压暗，海报 + 标题 + 元信息浮在上面。
///
/// 只用于手机端（桌面端仍是「封面 + 标题」的常规两栏）。标题最多三行，
/// 长标题不会把海报挤出屏幕；无封面时 `CoverImage` 的占位 + 压暗层
/// 仍然保证白字可读。
class _DetailHero extends StatelessWidget {
  const _DetailHero({required this.work});

  final Work work;

  static const double _height = 300;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstChar = work.title.characters.isEmpty
        ? null
        : work.title.characters.first;
    final rating = work.mainRating;
    final meta = [
      work.workType.label,
      if (work.releaseYear != null) '${work.releaseYear}',
      if (rating != null) '★ ${rating.value.toStringAsFixed(1)}',
    ].join(' · ');

    return SizedBox(
      height: _height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CoverImage(
            url: work.coverUrl,
            width: double.infinity,
            height: double.infinity,
            radius: 0,
            placeholderLabel: firstChar,
            // 整屏背景用深色渐变占位，斜纹只在下面那张小海报上用。
            placeholderStyle: CoverPlaceholderStyle.hero,
          ),
          // 底部压暗：白字在浅色封面上也能读。
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x000B1620), Color(0xF20B1620)],
                stops: [0.2, 1],
              ),
            ),
          ),
          Positioned(
            left: AppLayout.pagePadding,
            right: AppLayout.pagePadding,
            bottom: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppLayout.innerRadius),
                  child: CoverImage(
                    url: work.coverUrl,
                    width: 86,
                    height: 129,
                    radius: 0,
                    placeholderLabel: firstChar,
                    source: work.source,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        work.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        meta,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 收藏区：收藏按钮 + 观看状态。
///
/// 这是详情页唯一的写入口，四种形态各有明确出口，不留「点了没反应」的按钮：
/// - 未登录 → 「登录后收藏」，登录成功回到这里**直接把这部作品收进去**
///   （用户的意图就是收藏，不该登录完再点一次）；
/// - 状态未就绪 → 与按钮同高的占位，不跳动；
/// - 查询失败 → 说明失败 + 重试，不假装「没收藏」（C7）；
/// - 已收藏 → 按钮变「已收藏」，旁边出现状态选择器。
class _CollectBar extends ConsumerStatefulWidget {
  const _CollectBar({required this.work});

  final Work work;

  @override
  ConsumerState<_CollectBar> createState() => _CollectBarState();
}

class _CollectBarState extends ConsumerState<_CollectBar> {
  bool _busy = false;

  Future<void> _run(
    Future<ApiException?> Function() action, {
    String? successMessage,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await action();
    if (!mounted) return;
    setState(() => _busy = false);

    final message = error?.userMessage ?? successMessage;
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggle({required bool collected}) {
    return _run(
      () => ref
          .read(workCollectionProvider(widget.work.workId).notifier)
          .toggle(widget.work),
      successMessage: collected ? '已取消收藏' : '已加入收藏',
    );
  }

  Future<void> _signInThenCollect() async {
    await context.push(RoutePaths.login);
    if (!mounted) return;
    // 用户按「先不登录」回来时什么都不做，界面这时已经变回可点的「收藏」。
    if (!ref.read(authControllerProvider).isSignedIn) return;

    await _run(
      () => ref
          .read(workCollectionProvider(widget.work.workId).notifier)
          .collect(widget.work),
      successMessage: '已加入收藏',
    );
  }

  Future<void> _setStatus(CollectionStatus? status) {
    return _run(
      () => ref
          .read(workCollectionProvider(widget.work.workId).notifier)
          .setStatus(status),
      successMessage: status == null ? '已清除观看状态' : '已标记为「${status.label}」',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 未登录时也订阅：那时 build 直接返回「未收藏」、不发请求，
    // 订阅是为了登录回来后这块状态自己就位，不用等用户再点一次。
    final remote = ref.watch(workCollectionProvider(widget.work.workId));
    final auth = ref.watch(authControllerProvider);

    if (auth.status == AuthStatus.checking) return const _CollectPlaceholder();

    if (!auth.isSignedIn) {
      return Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _signInThenCollect,
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('登录后收藏'),
          ),
          Text(
            '收藏会同步到手机和桌面',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final collection = remote.value;

    if (collection == null) {
      if (!remote.hasError) return const _CollectPlaceholder();
      // 状态查不到时不能显示成「未收藏」：那会诱导用户再收一次。
      return Row(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '收藏状态获取失败',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () =>
                ref.invalidate(workCollectionProvider(widget.work.workId)),
            child: const Text('重试'),
          ),
        ],
      );
    }

    final collected = collection.collected;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: collected ? '取消收藏' : '加入收藏',
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _toggle(collected: collected),
            icon: Icon(
              collected
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_add_outlined,
              size: 18,
            ),
            label: Text(collected ? '已收藏' : '收藏'),
          ),
        ),
        if (collected)
          CollectionStatusMenu(
            status: collection.status,
            enabled: !_busy,
            onSelected: _setStatus,
          ),
      ],
    );
  }
}

/// 与收藏按钮同高的占位：状态未就绪时先占住位置，
/// 避免按钮出现时把下面的标签区推下去。
class _CollectPlaceholder extends StatelessWidget {
  const _CollectPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 40,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}


/// 简介。`null` → "暂无简介"；超长 → 折叠 8 行，可展开。
class _SummaryBlock extends StatefulWidget {
  const _SummaryBlock({required this.text});

  final String? text;

  @override
  State<_SummaryBlock> createState() => _SummaryBlockState();
}

class _SummaryBlockState extends State<_SummaryBlock> {
  static const int _collapsedLines = 8;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.text;

    if (text == null || text.isEmpty) {
      return Text(
        '暂无简介',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final style = theme.textTheme.bodyMedium?.copyWith(height: 1.75);

    return LayoutBuilder(
      builder: (context, constraints) {
        // 先量一遍：撑不满 8 行就不显示"展开"，避免短简介下面挂个没用的按钮。
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: _collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final canExpand = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: style,
              maxLines: _expanded ? null : _collapsedLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (canExpand)
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: Text(_expanded ? '收起' : '展开全文'),
              ),
          ],
        );
      },
    );
  }
}
