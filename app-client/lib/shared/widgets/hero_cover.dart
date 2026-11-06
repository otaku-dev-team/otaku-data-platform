import 'package:flutter/material.dart';

/// 给封面套一层 [Hero]，让「点卡片 → 详情」有图像跟随。
///
/// 为什么标签要由调用方传、并且**每屏唯一**：Flutter 要求同一个 `Navigator`
/// 子树里 Hero 标签不重复，重复会直接抛
/// 「There are multiple heroes that share the same tag」。
/// 而首页会出现同一部作品同时挂在两条轨道上的情况（高分榜与今日档期可能重叠），
/// 所以标签不能只按 `work_id` 取——调用方用「轨道名 + 下标」拼一个屏内唯一的 tag，
/// 再把它原样带到详情路由上（`?hero=`），两端才配得对。
///
/// [tag] 为 null 时原样返回 [child]：深链接进来、或这个位置不适合做转场时，
/// 加个死标签只会让用户看到一次莫名其妙的飞入。
class HeroCover extends StatelessWidget {
  const HeroCover({super.key, required this.tag, required this.child});

  final String? tag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tag = this.tag;
    if (tag == null || tag.isEmpty) return child;
    // 不自定义 flightShuttle：默认的尺寸/位置插值已经够顺，
    // 自己套一层淡入反而会让"图片跟随"变成"图片重画一次"。
    return Hero(tag: tag, child: child);
  }
}
