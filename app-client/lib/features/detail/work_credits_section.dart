import 'package:flutter/material.dart';

import '../../data/models/work_character.dart';
import '../../data/models/work_staff.dart';

/// 折叠状态下露出的条数。
///
/// 一部作品最多 **288 条** Staff（平均 20.5），不折叠会把详情页撑成一堵墙，
/// 而且简介和相关推荐会被推到看不见的地方。
const int _collapsedCount = 6;

/// 详情页「制作人员」区块。契约 `Work.staff`。
///
/// 没有数据时**整块不渲染**（返回零高度占位，不留标题、不留「暂无」）：
/// 动画里约三分之二的作品没有 Staff，那是来源侧的数据事实，不是加载失败。
/// 挂一块空的「制作人员」标题，用户只会以为没加载出来。
class StaffSection extends StatelessWidget {
  const StaffSection({super.key, required this.staff});

  final List<WorkStaff>? staff;

  @override
  Widget build(BuildContext context) {
    final items = staff;
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    return _CreditBlock(
      title: '制作人员',
      rows: [for (final item in items) _StaffRow(item: item)],
    );
  }
}

/// 详情页「角色与声优」区块。契约 `Work.characters`。
///
/// 空态处理同 [StaffSection]。
class CharacterSection extends StatelessWidget {
  const CharacterSection({super.key, required this.characters});

  final List<WorkCharacter>? characters;

  @override
  Widget build(BuildContext context) {
    final items = characters;
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    return _CreditBlock(
      title: '角色与声优',
      rows: [for (final item in items) _CharacterRow(item: item)],
    );
  }
}

/// 区块骨架：标题 + 可折叠的条目列表。
///
/// 折叠状态是**局部状态**：离开页面就重置，不值得进 provider；
/// 两部作品之间也不会共用（key 随 Widget 身份走）。
class _CreditBlock extends StatefulWidget {
  const _CreditBlock({required this.title, required this.rows});

  final String title;

  /// 全部条目。折叠时只构建前 [_collapsedCount] 条——288 条 Text 一次性铺开
  /// 没意义，用户多半只是扫一眼前几行。
  final List<Widget> rows;

  @override
  State<_CreditBlock> createState() => _CreditBlockState();
}

class _CreditBlockState extends State<_CreditBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = widget.rows;
    final canCollapse = rows.length > _collapsedCount;
    final visible = _expanded || !canCollapse
        ? rows
        : rows.take(_collapsedCount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // 与首页各区块同一条 3px 品牌色立柱：正文里连续几个标题字号一样，
            // 光靠字重分不出段与段。
            Container(
              width: 3,
              height: 15,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              widget.title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${rows.length}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...visible,
        // 没超过阈值就不给按钮：一条「展开全部」后面只多两行，比没有更烦。
        if (canCollapse)
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
            label: Text(_expanded ? '收起' : '展开全部（共 ${rows.length} 条）'),
          ),
      ],
    );
  }
}

/// 「职位：人名」。`role` 为空时只显示人名（来源侧有些记录只给了人名）。
///
/// `person_id` 一律**不参与交互**：Staff 侧实测 0% 有值，人物页又在 B2 范围外，
/// 做了跳转也是跳到一个不存在的页面。
class _StaffRow extends StatelessWidget {
  const _StaffRow({required this.item});

  final WorkStaff item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final muted = base?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: item.role.isEmpty
          ? Text(item.name, style: base)
          : Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${item.role}：', style: muted),
                  TextSpan(text: item.name, style: base),
                ],
              ),
            ),
    );
  }
}

/// 「角色名 · 声优名」。
///
/// 刻意**不显示** `character_type`：实测 84% 为空（来源不分主配角），
/// 显示「未知类型」是拿没有的信息编了个说法；按类型分组更糟——
/// 会撑出一个巨大的「未知」桶。
class _CharacterRow extends StatelessWidget {
  const _CharacterRow({required this.item});

  final WorkCharacter item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final muted = base?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: item.actor.isEmpty
          ? Text(item.name, style: base)
          : Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: item.name, style: base),
                  TextSpan(text: '  ·  ${item.actor}', style: muted),
                ],
              ),
            ),
    );
  }
}

/// 详情页正文里的一行元信息（别名 / 制作公司）。
///
/// 值缺失时整行不渲染——「别名：」后面空着比不显示更可疑。
class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label：',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(text: value, style: theme.textTheme.bodySmall),
          ],
        ),
        // 最长的一行是别名列表，换行时按单词断，别把日文片假名切成两半。
        softWrap: true,
      ),
    );
  }
}
