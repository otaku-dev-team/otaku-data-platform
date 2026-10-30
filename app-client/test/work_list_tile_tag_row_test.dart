import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/contents/work_list_tile.dart';
import 'package:otaku_app/shared/widgets/tag_chips.dart';

/// 列表磁贴的标签行是**固定 22px 高**的。`TagChips` 之前用 `Wrap`，窄屏下
/// 会折成第二行——第二行直接画到卡片外、压住下一条（320 宽实测标签底边
/// 比标签行低 28px，重叠下一张卡 9px）。这组测试用真实长标签钉住「只占一行」。
const _rating = SourceRating(value: 8.5, scale: '0-10', source: 'bangumi');

const _longTagWork = WorkSummary(
  workId: 'W-long',
  workType: WorkType.anime,
  title: '一个很长很长很长很长很长很长的标题用来占满两行',
  tags: ['雅克-雷米·杰瑞德', '富野悠由季', 'OVA/剧场版', '一个特别特别长的标签名称', '科幻'],
  mainRating: _rating,
  source: 'bangumi',
);

void main() {
  testWidgets('列表磁贴标签行：窄屏也只占一行，不压到下一条', (tester) async {
    // 320 是能触发原 bug 的宽度（360 下三个标签刚好塞得下）。
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    WorkListTile(work: _longTagWork),
                    SizedBox(height: 8),
                    WorkListTile(work: _longTagWork),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final tiles = find.byType(WorkListTile);
    final firstTile = tester.getRect(tiles.at(0));
    final secondTile = tester.getRect(tiles.at(1));
    final tagRow = tester.getRect(find.byType(TagChips).first);

    // 1) 第一张卡片的实际底边不能越过第二张的顶边。
    expect(
      firstTile.bottom,
      lessThanOrEqualTo(secondTile.top),
      reason: '第一张卡片的内容画到了第二张上',
    );

    // 2) 每个可见标签都必须落在标签行的高度范围内（折行就会越界）。
    var visible = 0;
    final tops = <double>[];
    for (final tag in _longTagWork.tags!) {
      final finder = find.text(tag);
      if (!tester.any(finder)) continue;
      visible++;
      final rect = tester.getRect(finder.first);
      tops.add(rect.top);
      expect(
        rect.top,
        greaterThanOrEqualTo(tagRow.top - 0.5),
        reason: '「$tag」跑到了标签行上方',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(tagRow.bottom + 0.5),
        reason: '「$tag」折到了第二行，会压住下一条卡片',
      );
    }

    // 3) 所有可见标签在同一行（顶部对齐）。
    expect(visible, greaterThan(1), reason: '这条用例必须真的渲染出多个标签');
    expect(
      tops.reduce((a, b) => a > b ? a : b) - tops.reduce((a, b) => a < b ? a : b),
      lessThan(1),
      reason: '标签不在同一行',
    );
  });
}
