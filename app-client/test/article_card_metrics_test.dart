import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/features/article/article_card.dart';

/// 资讯卡的两处细节：头条要跟大字号一起长，缩略图要压解码尺寸并走磁盘缓存。
/// 这两条都不是「看起来对不对」，而是「换个字号 / 冷启动会不会坏」。
void main() {
  Future<void> pumpFeatured(
    WidgetTester tester, {
    required double textScale,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(
          body: ArticleCard(
            article: ArticleSummary(
              articleId: 'A-1',
              title: '一条足够长的头条标题，用来验证大字号下两行标题与元信息不会顶出固定高度',
              category: '动画',
              sourceName: 'Mock 新闻',
              publishedAt: '2026-11-02T10:00:00Z',
              sourceUrl: 'https://example.com/a',
            ),
            featured: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('头条在大字号下按比例放大，文字不溢出', (tester) async {
    await pumpFeatured(tester, textScale: 1);
    final normal = tester.getSize(find.byType(ArticleCard)).height;

    await pumpFeatured(tester, textScale: 1.6);
    final large = tester.getSize(find.byType(ArticleCard)).height;

    expect(large, greaterThan(normal));
    // 溢出在测试里表现为 exception（黄黑条纹那套），这里必须为空。
    expect(tester.takeException(), isNull);
  });

  testWidgets('缩略图走磁盘缓存，并按显示尺寸解码', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: ArticleCard(
            article: ArticleSummary(
              articleId: 'A-2',
              title: '带封面的资讯',
              coverUrl: 'https://example.com/cover.jpg',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.memCacheWidth, isNotNull);
    expect(image.memCacheWidth! > 0, isTrue);
    expect(image.maxWidthDiskCache, image.memCacheWidth);
  });
}
