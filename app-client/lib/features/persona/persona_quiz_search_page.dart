import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/models/collection_entry.dart';
import '../../data/models/work_summary.dart';
import '../../data/repositories/collection_repository.dart';
import '../../data/repositories/work_repository.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/desktop_nav_shell.dart';

/// #505 的另一半：**全库搜索补标**。
///
/// 预设题面只覆盖「代表性作品」；用户想标一部冷门番时，得能自己搜出来。
/// 复用作品列表的搜索（`GET /api/works?q=`，标题子串、忽略大小写），
/// 结果直接写 `PUT /api/me/collections/{id}`，和漏斗点选完全同一套口径。
///
/// 刻意**不做分页**：补标是「找到那一部就走」，不是浏览。给 20 条够用，
/// 搜不到就换个词——做无限滚动反而把「搜一部」变成「刷一屏」。
class PersonaQuizSearchPage extends ConsumerStatefulWidget {
  const PersonaQuizSearchPage({super.key});

  @override
  ConsumerState<PersonaQuizSearchPage> createState() =>
      _PersonaQuizSearchPageState();
}

class _PersonaQuizSearchPageState extends ConsumerState<PersonaQuizSearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// 请求序号：慢响应回来时如果已经搜了别的词，就丢弃它。
  int _token = 0;

  /// 已提交的搜索词（不是输入框里的实时值）。
  String _query = '';
  bool _loading = false;
  String? _error;
  List<WorkSummary> _results = const <WorkSummary>[];

  /// 本次会话里已经标过的：workId → 状态。用来在结果行上直接回显，
  /// 避免用户点完不确定有没有记上。
  final Map<String, CollectionStatus> _marked = <String, CollectionStatus>{};

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounce?.cancel();
    final text = raw.trim();
    if (text.isEmpty) {
      setState(() {
        _query = '';
        _results = const <WorkSummary>[];
        _error = null;
        _loading = false;
        _token++; // 让在途请求作废
      });
      return;
    }
    // 打字时不要每个字符都打一次接口。
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(text));
  }

  Future<void> _search(String text) async {
    final token = ++_token;
    setState(() {
      _query = text;
      _loading = true;
      _error = null;
    });
    try {
      final fetched = await ref
          .read(workRepositoryProvider)
          .fetchWorks(query: text, pageSize: 20);
      if (!mounted || token != _token) return;
      setState(() {
        _results = fetched.value.items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || token != _token) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.userMessage : '搜索失败，请重试';
      });
    }
  }

  Future<void> _mark(WorkSummary work, CollectionStatus status) async {
    try {
      await ref
          .read(collectionRepositoryProvider)
          .add(work.workId, status: status);
      if (!mounted) return;
      setState(() => _marked[work.workId] = status);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${work.title}》已记为「${status.label}」')),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没记上，请再试一次')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('搜作品补标')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppLayout.pagePadding,
                    Space.s3,
                    AppLayout.pagePadding,
                    Space.s2,
                  ),
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: _onChanged,
                    onSubmitted: (value) {
                      final text = value.trim();
                      if (text.isNotEmpty) _search(text);
                    },
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: '搜作品名，例如「银河」',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Expanded(child: _buildResults(theme)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_query.isEmpty) {
      return _Hint(
        icon: Icons.playlist_add_rounded,
        text: '搜一部作品，标成「看过 / 在看 / 抛弃」。\n答案和选择页一样写进收藏。',
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Hint(
        icon: Icons.error_outline_rounded,
        text: _error!,
        action: TextButton(
          onPressed: () => _search(_query),
          child: const Text('重试'),
        ),
      );
    }
    if (_results.isEmpty) {
      return _Hint(
        icon: Icons.search_off_rounded,
        text: '没搜到「$_query」。换个关键词试试。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: AppLayout.pagePadding,
        vertical: Space.s2,
      ),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: Space.s2),
      itemBuilder: (context, index) {
        final work = _results[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.s2),
            child: Row(
              children: [
                CoverImage(
                  url: work.coverUrl,
                  width: 44,
                  height: 60,
                  radius: Radii.sm,
                  placeholderLabel: null,
                ),
                const SizedBox(width: Space.s2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        work.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        <String>[
                          if (work.releaseYear != null) '${work.releaseYear}',
                          work.workType.label,
                          if (_marked[work.workId] != null)
                            '已记 · ${_marked[work.workId]!.label}',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _marked[work.workId] != null
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<CollectionStatus>(
                  tooltip: '标记这部作品',
                  onSelected: (status) => _mark(work, status),
                  itemBuilder: (context) => [
                    for (final status in <CollectionStatus>[
                      CollectionStatus.watched,
                      CollectionStatus.watching,
                      CollectionStatus.dropped,
                    ])
                      PopupMenuItem<CollectionStatus>(
                        value: status,
                        child: Text(status.label),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: Space.s3),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            if (action != null) ...[const SizedBox(height: Space.s2), action!],
          ],
        ),
      ),
    );
  }
}
