import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  late List<String> _selected = List<String>.of(widget.initial);
  final TextEditingController _search = TextEditingController();
  String _keyword = '';

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

    return SingleChildScrollView(
      child: Wrap(
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
      ),
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
