import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import 'update_controller.dart';
import 'update_manifest.dart';

/// 弹出更新提示。
///
/// 强制更新（当前版本低于 `minSupportedVersionCode`）时不允许点遮罩关闭，
/// 也不给「以后再说 / 忽略」——否则用户永远升不上去。
Future<void> showUpdateDialog(
  BuildContext context,
  WidgetRef ref,
  UpdateManifest manifest,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: !manifest.isForced,
    builder: (_) => UpdateDialog(manifest: manifest),
  );
}

class UpdateDialog extends ConsumerWidget {
  const UpdateDialog({super.key, required this.manifest});

  final UpdateManifest manifest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(updateControllerProvider);

    return AlertDialog(
      title: Text('发现新版本 v${manifest.versionName}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前版本 v${AppConfig.versionName}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (manifest.isForced) ...[
              const SizedBox(height: 10),
              Text(
                '这个版本已停止支持，需要更新后才能继续使用。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (manifest.changelog.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('更新内容', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Text(
                    manifest.changelog,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ),
              ),
            ],
            if (state.phase == UpdatePhase.downloading) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: state.progress > 0 ? state.progress : null,
              ),
              const SizedBox(height: 6),
              Text(
                _progressText(state),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (state.phase == UpdatePhase.ready) ...[
              const SizedBox(height: 14),
              Text(
                '下载完成，点击「安装更新」按系统提示完成安装。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            if (state.phase == UpdatePhase.installing) ...[
              const SizedBox(height: 14),
              Text(
                '已打开系统安装器，请按提示完成安装。安装完成后重新打开 App 即可。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            if (state.phase == UpdatePhase.error) ...[
              const SizedBox(height: 14),
              Text(
                state.error ?? '更新失败，请重试',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: _actions(context, ref, state),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    WidgetRef ref,
    UpdateState state,
  ) {
    final controller = ref.read(updateControllerProvider.notifier);
    void close() {
      controller.reset();
      Navigator.of(context).pop();
    }

    return switch (state.phase) {
      UpdatePhase.downloading => [
        TextButton(
          onPressed: controller.cancelDownload,
          child: const Text('取消下载'),
        ),
      ],
      UpdatePhase.ready => [
        TextButton(onPressed: close, child: const Text('以后再说')),
        FilledButton(
          onPressed: () => controller.install(),
          child: const Text('安装更新'),
        ),
      ],
      UpdatePhase.installing => [
        FilledButton(onPressed: close, child: const Text('完成')),
      ],
      UpdatePhase.error => [
        TextButton(onPressed: close, child: const Text('关闭')),
        FilledButton(
          onPressed: () => controller.download(),
          child: const Text('重试'),
        ),
      ],
      _ => [
        if (!manifest.isForced) ...[
          TextButton(onPressed: close, child: const Text('以后再说')),
          TextButton(
            onPressed: () async {
              await controller.ignore();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('忽略此次更新'),
          ),
        ],
        FilledButton(
          onPressed: () => _startUpdate(context, ref),
          child: const Text('立即更新'),
        ),
      ],
    };
  }

  Future<void> _startUpdate(BuildContext context, WidgetRef ref) async {    // 桌面 / iOS 不能侧载：直接打开下载页，让系统浏览器接手。
    if (!Platform.isAndroid) {
      final launched = await launchUrl(
        Uri.parse(manifest.downloadUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!context.mounted) return;
      if (launched) {
        ref.read(updateControllerProvider.notifier).reset();
        Navigator.of(context).pop();
      }
      return;
    }
    await ref.read(updateControllerProvider.notifier).download();
  }
}

/// 下载进度文案：百分比 + 已下载/总量 + 实测速度 + 预计剩余。
///
/// 速度和剩余时间不是装饰。更新包走的是很慢的线路时，只给百分比会让
/// 用户盯着 3% 以为卡死；有速度就知道是「在走，只是慢」，也不容易反复
/// 取消重试。
String _progressText(UpdateState state) {
  final pct = state.progress > 0
      ? '${(state.progress * 100).toStringAsFixed(0)}%'
      : '正在连接…';

  final parts = <String>[];
  final total = state.totalBytes;
  if (total != null && total > 0) {
    parts.add(
      '${_formatBytes(state.receivedBytes.toDouble())}'
      ' / ${_formatBytes(total.toDouble())}',
    );
  }
  if (state.bytesPerSecond > 0) {
    parts.add('${_formatBytes(state.bytesPerSecond)}/s');
  }
  final remaining = state.remaining;
  if (remaining != null) {
    parts.add('约剩 ${_formatDuration(remaining)}');
  }

  return parts.isEmpty ? '正在下载 $pct' : '$pct  ·  ${parts.join('  ·  ')}';
}

String _formatBytes(double bytes) {
  const kb = 1024.0;
  const mb = kb * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '${bytes.toStringAsFixed(0)} B';
}

String _formatDuration(Duration d) {
  final seconds = d.inSeconds;
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '$minutes 分钟' : '$minutes 分 $rest 秒';
}
