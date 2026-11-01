/// 作品库网格的显示密度。
///
/// 为什么是三档而不是「网格 / 列表」两档：列表一行只放得下一部，找作品时
/// 一屏 5–6 部；纯封面一屏能放 12 部左右，扫封面找人快得多。
/// 中间那档给「想多看几部、但仍要知道叫什么」的场景。
///
/// 列数不写死在这里：默认按宽度自适应（`AppLayout.gridMetrics`），
/// 用户可以在设置里覆盖。
enum LibraryDensity {
  /// 封面 + 两行标题 + 元信息行 + 标签行（默认，与站点卡片一致）。
  comfort(
    label: '舒适',
    description: '封面 + 标题、类型、评分、标签',
    bodyHeight: 112,
    narrowMinWidth: 150,
    wideMinWidth: 190,
  ),

  /// 封面 + 一行标题。去掉元信息与标签行，一屏多看两三部。
  compact(
    label: '紧凑',
    description: '封面 + 一行标题',
    bodyHeight: 40,
    narrowMinWidth: 118,
    wideMinWidth: 150,
  ),

  /// 只有封面，不显示任何文字。扫图找人最快，一屏能放 12 部左右。
  coversOnly(
    label: '仅封面',
    description: '只有封面，不显示文字',
    bodyHeight: 0,
    narrowMinWidth: 92,
    wideMinWidth: 120,
  );

  const LibraryDensity({
    required this.label,
    required this.description,
    required this.bodyHeight,
    required this.narrowMinWidth,
    required this.wideMinWidth,
  });

  /// 设置页上的名字。
  final String label;

  /// 设置页上的一句话说明。
  final String description;

  /// 封面下方文字区的高度（逻辑像素，**未乘**字号缩放）。
  ///
  /// 网格用固定 `mainAxisExtent`，这里必须给死，否则长短标题会让行高不齐。
  /// [coversOnly] 是 0：整张卡就是封面本身。
  final double bodyHeight;

  /// 窄屏（可用宽度 < 600）下单卡最小宽度，决定自适应列数。
  final double narrowMinWidth;

  /// 宽屏下单卡最小宽度。
  final double wideMinWidth;

  /// 按可用宽度取对应的最小卡宽。
  double minCardWidth(double availableWidth) =>
      availableWidth < 600 ? narrowMinWidth : wideMinWidth;

  /// 从存进 `LocalPrefs` 的字符串还原；认不出就用默认值。
  ///
  /// 不抛异常：设置项是设备级的，坏一个值不该让整个列表打不开。
  static LibraryDensity fromKey(String? key) {
    for (final value in values) {
      if (value.name == key) return value;
    }
    return LibraryDensity.comfort;
  }
}
