import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/collection_entry.dart';

/// 观看状态选择器。
///
/// `null`（清除状态）与三个枚举值并列，因为「收藏但不设状态」是合法状态，
/// 不能只能通过删除收藏来表达。
///
/// 收藏页的卡片和详情页的收藏区共用这一个组件：两处改状态走的是同一个
/// `PATCH`，界面若各写一套，迟早出现「这边能清除状态、那边不能」的分裂。
class CollectionStatusMenu extends StatelessWidget {
  const CollectionStatusMenu({
    super.key,
    required this.status,
    required this.onSelected,
    this.enabled = true,
    this.emptyLabel = '未设状态',
  });

  final CollectionStatus? status;
  final ValueChanged<CollectionStatus?> onSelected;

  /// 写请求进行中时置 false，防重复提交。
  final bool enabled;

  /// 未设状态时的文案。收藏页与详情页对同一件事的叫法必须一致，
  /// 这里给默认值只是方便将来换词。
  final String emptyLabel;

  static const String _clearStatusValue = '__none__';

  @override
  Widget build(BuildContext context) {
    final label = status?.label ?? emptyLabel;

    return PopupMenuButton<String>(
      tooltip: '修改观看状态',
      enabled: enabled,
      // 不能用 `value: null` 表示「清除状态」：PopupMenuButton 把 null
      // 当成「用户点了外面取消」，onSelected 根本不会触发。用哨兵字符串。
      onSelected: (value) => onSelected(
        value == _clearStatusValue ? null : CollectionStatus.parse(value),
      ),
      itemBuilder: (context) => [
        for (final option in CollectionStatus.values)
          PopupMenuItem<String>(value: option.value, child: Text(option.label)),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: _clearStatusValue,
          child: Text('清除状态'),
        ),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        // 收藏卡是窄容器：大字号下（真机 font_scale 2.0 实测）M3 默认的
        // labelPadding 会把 label 挤到一行一个字、再被固定高度裁掉。
        // 收紧内边距 + 单行省略，最坏情况显示「未设…」而不是残字。
        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        avatar: Icon(
          status == null ? Icons.help_outline : Icons.playlist_add_check,
          size: 16,
          color: AppTheme.brandInk(context),
        ),
      ),
    );
  }
}
