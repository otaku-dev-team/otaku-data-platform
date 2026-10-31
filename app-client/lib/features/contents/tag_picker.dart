import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/tag_filter.dart';
import '../../data/models/tag_vocabulary.dart';
import '../../data/models/work_type.dart';
import 'tag_vocabulary_provider.dart';

/// 打开标签面板，返回用户确认后的标签列表；取消返回 `null`。
///
/// 用对话框而不是常驻侧栏：标签面板是「偶尔进来挑一次」的动作，
/// 常驻会占掉列表宽度，而列表宽度是这一页最值钱的东西。
Future<List<String>?> showTagPicker(
  BuildContext context, {
  required List<String> selected,
  WorkType? type,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => TagPickerDialog(initial: selected, type: type),
  );
}

class TagPickerDialog extends ConsumerStatefulWidget {
  const TagPickerDialog({super.key, required this.initial, this.type});

  final List<String> initial;

  /// 当前筛的作品类型。传了就只显示该类型的标签——点了必然有结果的标签，
  /// 比「全量词表里一半点了是 0 条」有用得多。
  final WorkType? type;

  @override
  ConsumerState<TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends ConsumerState<TagPickerDialog> {
  /// 热门区显示多少个。20 个正好两三行，再多就又是「一墙 chip」。
  static const int _hotTagCount = 20;

  /// 「全部标签」每次多显示多少个。
  ///
  /// 不一次铺开两千个：`FilterChip` 是完整的状态化 widget，两千个一起建
  /// 会让打开面板卡一下。分页加，每页 240 个，对点选没有影响。
  static const int _restPageSize = 240;

  late List<String> _selected = List<String>.of(widget.initial);
  final TextEditingController _search = TextEditingController();
  String _keyword = '';

  /// 「全部标签」当前展开到第几个。默认先给一页，剩下的按钮按需加。
  int _visibleRest = _restPageSize;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _atLimit => _selected.length >= maxFilterTags;

  void _toggle(String name) {
    setState(() {
      if (!_selected.remove(name)) {
        if (_atLimit) return;
        _selected.add(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vocabulary = ref.watch(tagVocabularyProvider(widget.type));

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      title: Row(
        children: [
          const Text('选择标签'),
          const SizedBox(width: 10),
          Text(
            '已选 ${_selected.length}/$maxFilterTags',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _atLimit
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (widget.type != null) ...[
            const SizedBox(width: 8),
            Text(
              '仅「${widget.type!.label}」',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: '刷新词表',
            onPressed: () =>
                ref.invalidate(tagVocabularyProvider(widget.type)),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '在词表里找标签',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (value) => setState(() => _keyword = value.trim()),
            ),
            const SizedBox(height: 10),
            if (_atLimit)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '最多同时选 $maxFilterTags 个标签（标签之间是「并且」关系，选多了会没有结果）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Expanded(
              child: switch (vocabulary) {
                AsyncData(:final value) => _buildList(value),
                AsyncError(:final error) => _buildError(error),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _selected.isEmpty
              ? null
              : () => setState(() => _selected = <String>[]),
          child: const Text('清空'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(List<String>.of(_selected)),
          child: const Text('应用'),
        ),
      ],
    );
  }

  Widget _buildList(TagVocabulary vocabulary) {
    final keyword = _keyword.toLowerCase();
    final items = keyword.isEmpty
        ? vocabulary.items
        : vocabulary.items
              .where((item) => item.name.toLowerCase().contains(keyword))
              .toList(growable: false);

    if (items.isEmpty) {
      return Center(
        child: Text(
          keyword.isEmpty ? '这个词表是空的' : '词表里没有包含「$_keyword」的标签',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // 搜索时不分组：用户已经在缩小范围了，再套一层「热门 / 全部」只是
    // 让他多点一次。直接给命中的全部。
    if (keyword.isNotEmpty) {
      return SingleChildScrollView(child: _cloud(items));
    }

    // 按作品数降序。词表本身是服务端顺序，不可依赖。
    final sorted = [...items]..sort((a, b) => b.count.compareTo(a.count));
    final hot = sorted.take(_hotTagCount).toList(growable: false);
    final rest = sorted.skip(_hotTagCount).toList(growable: false);

    // 已选置顶：标签藏在两千个 chip 里时，用户想知道「我选了什么」得先滚
    // 到底部，选满了想删掉一个尤其难。词表里没有的（历史筛选遗留）也要显示，
    // 否则他永远删不掉那个标签。
    final selected = [
      for (final name in _selected)
        items.firstWhere(
          (item) => item.name == name,
          orElse: () => TagCount(name: name, count: 0),
        ),
    ];

    return ListView(
      children: [
        if (selected.isNotEmpty) ...[
          _sectionTitle('已选（${selected.length}/$maxFilterTags）'),
          _cloud(selected),
          const SizedBox(height: 14),
        ],
        _sectionTitle('热门'),
        _cloud(hot),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionTitle('全部标签（${sorted.length}）'),
          _cloud(rest.take(_visibleRest).toList(growable: false)),
          if (_visibleRest < rest.length)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: () => setState(() => _visibleRest += _restPageSize),
                  child: Text(
                    '再看 $_restPageSize 个（还剩 ${rest.length - _visibleRest}）',
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _sectionTitle(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: AppTheme.brandInk(context),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _cloud(List<TagCount> items) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          FilterChip(
            label: Text('${item.name} · ${item.count}'),
            selected: _selected.contains(item.name),
            // 到上限后，未选中的 chip 禁掉：让用户点一下没反应比点完再被吞掉好。
            onSelected: _atLimit && !_selected.contains(item.name)
                ? null
                : (_) => _toggle(item.name),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Widget _buildError(Object error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('词表加载失败：$error', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                ref.invalidate(tagVocabularyProvider(widget.type)),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
