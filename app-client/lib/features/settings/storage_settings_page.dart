import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/work_cache.dart';
import 'settings_controller.dart';
import 'settings_widgets.dart';

/// 离线缓存：用量、说明、清除。
class StorageSettingsPage extends ConsumerWidget {
  const StorageSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const SettingsSubPage(
      title: '离线缓存',
      // 同上：卡片自带的「已缓存内容」已经说明了这一屏是什么。
      children: [_CacheCard(), SizedBox(height: 12), _ImageCacheCard()],
    );
  }
}

/// 缓存用量的一句话描述。主设置页的入口行也用它，所以是公开函数。
String describeCacheUsage(AsyncValue<CacheUsage> usage) {
  return switch (usage) {
    AsyncData(:final value) when value.entries == 0 => '暂无缓存',
    AsyncData(:final value) => '${value.entries} 条 · 约 ${formatCacheBytes(value.bytes)}',
    AsyncError() => '统计失败',
    _ => '统计中…',
  };
}

/// 主设置页入口行的**合计**描述：JSON 缓存 + 图片缓存。
///
/// 只报 JSON 那一份会跟系统设置里的「应用占用」差出几十 MB——用户以为没清干净，
/// 其实是封面没算进来。两边都还没算完时说「统计中」；只要有一份好了就先报已知的部分，
/// 不因为图片还在数就把整行卡住。
String describeTotalCacheUsage(
  AsyncValue<CacheUsage> data,
  AsyncValue<ImageCacheUsage> images,
) {
  final cached = data.value;
  final covers = images.value;
  if (cached == null && covers == null) {
    return data.hasError && images.hasError ? '统计失败' : '统计中…';
  }

  final entries = cached?.entries ?? 0;
  final bytes = (cached?.bytes ?? 0) + (covers?.bytes ?? 0);
  if (entries == 0 && bytes == 0) return '暂无缓存';
  return '$entries 条 · 约 ${formatCacheBytes(bytes)}';
}

/// 1024 进制。设置页写「约」，因为 [CacheUsage.bytes] 本身就是估算。
String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

class _CacheCard extends ConsumerWidget {
  const _CacheCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final usage = ref.watch(cacheUsageProvider);
    final data = usage.value;
    // 统计失败时不假装是 0：那会让用户以为「本来就没有缓存」。
    // 按钮保持可点——清一次本来就是安全的。
    final canClear = usage.isLoading || data == null || data.entries > 0;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已缓存内容', style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      describeCacheUsage(usage),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: canClear ? () => _confirmClear(context, ref) : null,
                child: const Text('清除'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '断网时列表与详情会回退到这些缓存，并在顶部标注上次同步时间。'
            '清除后需要联网才能重新查看，收藏与浏览历史不受影响。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除离线缓存？'),
        content: const Text('清除后断网时将看不到已缓存的作品，联网后会重新缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await clearWorkCache(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已清除离线缓存')));
  }
}

/// 一句话描述图片缓存用量。与 [describeCacheUsage] 分开写：
/// 这里数的是「文件」，那边数的是「条」，混用会让两个数字看起来矛盾。
String describeImageCacheUsage(AsyncValue<ImageCacheUsage> usage) {
  return switch (usage) {
    AsyncData(:final value) when value.isEmpty => '暂无图片缓存',
    AsyncData(:final value) =>
      '${value.files} 个文件 · 约 ${formatCacheBytes(value.bytes)}',
    AsyncError() => '统计失败',
    _ => '统计中…',
  };
}

/// 图片缓存：封面占的磁盘。
///
/// 单独一张卡而不是并进「离线缓存」：两者清除后的后果不同——
/// 清离线缓存会让人断网时看不了详情，清图片缓存只是下次要重新下载封面。
/// 混成一条会让用户不敢点。
///
/// 这一张也是**为了把账算全**：主设置页那一行只显示 JSON 的体积（几十 KB），
/// 用户在系统设置里看到的却是几十 MB，差的就是这块。
class _ImageCacheCard extends ConsumerWidget {
  const _ImageCacheCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final usage = ref.watch(imageCacheUsageProvider);
    final data = usage.value;
    final canClear = usage.isLoading || data == null || !data.isEmpty;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('图片缓存', style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      describeImageCacheUsage(usage),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: canClear ? () => _confirmClear(context, ref) : null,
                child: const Text('清除'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '封面与插图。最多保留 200 个文件、30 天后自动过期，清掉只是下次要重新下载，'
            '不影响收藏、浏览历史与离线缓存。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除图片缓存？'),
        content: const Text('下次打开列表会重新下载封面，流量会多花一点。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await clearImageCache(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已清除图片缓存')));
  }
}
