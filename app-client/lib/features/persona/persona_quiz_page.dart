import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/models/collection_entry.dart';
import '../../data/models/work_summary.dart';
import '../../data/repositories/collection_repository.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/section_state_view.dart';
import 'persona_data_source.dart';
import 'persona_quiz_data_source.dart';

/// #505 冷启动补标：一次一部，点「看过 / 在看 / 抛弃」。
///
/// 三个按钮就是收藏的三态（`watched` / `watching` / `dropped`），答案直接写进
/// `collection`（`source=quiz`，契约 #506：盖不动用户自己的操作）。所以这里
/// **不需要新的信号表**——补完标，画像就有数据了。
///
/// 20 部是轻量版（快速出形状），100 部是完整版。题量按服务端返回的
/// `paper.size` 算，不是按请求值：候选不够时会少给，按请求值算进度条
/// 会永远差最后一格。
class PersonaQuizPage extends ConsumerStatefulWidget {
  const PersonaQuizPage({super.key});

  @override
  ConsumerState<PersonaQuizPage> createState() => _PersonaQuizPageState();
}

enum _QuizSize {
  light(20, '20 部'),
  full(100, '100 部');

  const _QuizSize(this.count, this.label);

  final int count;
  final String label;
}

class _PersonaQuizPageState extends ConsumerState<PersonaQuizPage> {
  _QuizSize _size = _QuizSize.light;
  int _seed = 0;
  int _index = 0;
  int _answered = 0;
  bool _submitting = false;

  void _restart({int? seed, _QuizSize? size}) {
    setState(() {
      if (seed != null) _seed = seed;
      if (size != null) _size = size;
      _index = 0;
      _answered = 0;
    });
  }

  Future<void> _answer(WorkSummary work, CollectionStatus status) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await ref
          .read(collectionRepositoryProvider)
          .add(work.workId, status: status);
      if (!mounted) return;
      setState(() {
        _index++;
        _answered++;
        _submitting = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // 失败不前进：这一部没记上就跳走，用户会以为记上了。
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没记上，请再试一次')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 题面本身匿名可读，但**写答案要登录**（走 /api/me/collections）。
    // 不先挡一下，用户点十几下才发现一条都没记上，比直接说清楚糟得多。
    if (!ref.watch(personalizedAudienceProvider)) {
      return DesktopNavShell(
        child: Scaffold(
          appBar: AppBar(title: const Text('补几部作品')),
          body: Center(
            child: Text(
              '登录后才能补标。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    final paper = ref.watch(
      personaQuizPaperProvider((seed: _seed, size: _size.count)),
    );

    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('补几部作品'),
          actions: [
            TextButton(
              onPressed: () => _restart(seed: _seed + 1),
              child: const Text('换一批'),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppLayout.pagePadding,
              ),
              child: SectionStateView<QuizPaper>(
                value: paper,
                onRetry: () => ref.invalidate(
                  personaQuizPaperProvider((seed: _seed, size: _size.count)),
                ),
                skeletonHeight: 360,
                emptyIcon: Icons.style_outlined,
                emptyTitle: '这批没有可选的作品',
                emptyMessage: '换一批试试，或者稍后再来。',
                isEmpty: (data) => data.works.isEmpty,
                builder: (data) => _buildBody(data),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(QuizPaper paper) {
    final done = _index >= paper.size;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Space.s3),
        _Header(
          size: _size,
          onSizeChanged: _submitting
              ? null
              : (size) => _restart(size: size),
          index: _index,
          total: paper.size,
        ),
        const SizedBox(height: Space.s3),
        Expanded(
          child: done
              ? _DoneView(
                  answered: _answered,
                  onViewPersona: () {
                    // 画像按需重算：补完标必须让页面重新拉一次，否则看到旧形状。
                    ref.invalidate(personaInsightProvider);
                    if (context.canPop()) context.pop();
                  },
                )
              : SingleChildScrollView(
                  child: _QuestionCard(
                    work: paper.works[_index],
                    submitting: _submitting,
                    onAnswer: (status) => _answer(paper.works[_index], status),
                  ),
                ),
        ),
        const SizedBox(height: Space.s2),
        Text(
          '这些答案会写进你的收藏，用来算画像。标错了随时去收藏页改。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Space.s3),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.size,
    required this.onSizeChanged,
    required this.index,
    required this.total,
  });

  final _QuizSize size;
  final ValueChanged<_QuizSize>? onSizeChanged;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_QuizSize>(
          segments: [
            for (final option in _QuizSize.values)
              ButtonSegment<_QuizSize>(value: option, label: Text(option.label)),
          ],
          selected: <_QuizSize>{size},
          onSelectionChanged: onSizeChanged == null
              ? null
              : (selection) => onSizeChanged!(selection.single),
        ),
        const SizedBox(height: Space.s2),
        Row(
          children: [
            Expanded(
              child: LinearProgressIndicator(
                // 按服务端返回的实际题量算（见类注释）。
                value: total <= 0 ? 0 : (index / total).clamp(0.0, 1.0),
                minHeight: 6,
              ),
            ),
            const SizedBox(width: Space.s2),
            Text(
              '$index / $total',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 一张题：封面 + 标题 + 年份标签 + 三个状态按钮。
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.work,
    required this.submitting,
    required this.onAnswer,
  });

  final WorkSummary work;
  final bool submitting;
  final ValueChanged<CollectionStatus> onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tags = work.tags ?? const <String>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: CoverImage(
                url: work.coverUrl,
                width: 132,
                height: 176,
                radius: Radii.md,
                placeholderLabel: work.title,
              ),
            ),
            const SizedBox(height: Space.s3),
            Text(
              work.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: Space.s1),
            Text(
              <String>[
                if (work.releaseYear != null) '${work.releaseYear}',
                work.workType.label,
                ...tags.take(3),
              ].join(' · '),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.s4),
            Text(
              '看过吗？',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.s2),
            // 三个按钮就是收藏三态；`dropped` 是「抛弃」，画像里记负权重。
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Space.s2,
              runSpacing: Space.s2,
              children: [
                _AnswerButton(
                  label: '看过',
                  icon: Icons.check_circle_outline_rounded,
                  enabled: !submitting,
                  onTap: () => onAnswer(CollectionStatus.watched),
                ),
                _AnswerButton(
                  label: '在看',
                  icon: Icons.play_circle_outline_rounded,
                  enabled: !submitting,
                  onTap: () => onAnswer(CollectionStatus.watching),
                ),
                _AnswerButton(
                  label: '抛弃',
                  icon: Icons.remove_circle_outline_rounded,
                  enabled: !submitting,
                  onTap: () => onAnswer(CollectionStatus.dropped),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerButton extends StatelessWidget {
  const _AnswerButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class _DoneView extends StatelessWidget {
  const _DoneView({required this.answered, required this.onViewPersona});

  final int answered;
  final VoidCallback onViewPersona;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: Space.s3),
          Text('这一批标完了', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.s1),
          Text(
            '记录了 $answered 部作品',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Space.s4),
          FilledButton(
            onPressed: onViewPersona,
            child: const Text('去看画像'),
          ),
        ],
      ),
    );
  }
}
