import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_layout.dart';
import '../../data/models/remote_config.dart';
import '../../features/config/app_config_controller.dart';

/// 首页顶部的公告条（`app.notice` 配置驱动）。
///
/// 为什么是"首页一条"而不是弹窗：公告是背景信息，不该打断用户；
/// 弹窗留给"必须现在处理"的事（更新、登录失效）。
///
/// 没有公告时渲染 `SizedBox.shrink()`——调用方可以无条件把它放进列表，
/// 不用在页面里判一次配置。
class ConfigNoticeBar extends ConsumerWidget {
  const ConfigNoticeBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appConfigProvider);
    final notice = state.notice;
    if (!state.showNotice || notice == null) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        0,
      ),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 10, notice.dismissible ? 2 : 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.campaign_outlined,
                size: 18,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(child: _NoticeText(notice: notice)),
              if (notice.dismissible)
                IconButton(
                  tooltip: '关闭公告',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () =>
                      ref.read(appConfigProvider.notifier).dismissNotice(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeText extends StatelessWidget {
  const _NoticeText({required this.notice});

  final RemoteNotice notice;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSecondaryContainer,
      height: 1.4,
    );
    final text = Text(
      notice.text,
      style: style,
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    );
    final url = notice.url;
    if (url == null) {
      return text;
    }
    return InkWell(onTap: () => _open(context, url), child: text);
  }

  Future<void> _open(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }
    final launched = await launchUrl(uri);
    // 桌面端常常没有浏览器关联：打开失败必须说出来，否则用户以为是点了没反应
    if (!launched) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('打不开这个链接，请检查系统默认浏览器')),
      );
    }
  }
}
