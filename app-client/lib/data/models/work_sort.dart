/// 列表排序方式。契约：`sort` 三种取值，省略等价于 [WorkSort.id]。
///
/// 三种都**降序在前**、无值作品（`null` 评分 / 年份）排最后，并以 `id` 作
/// 次级键保证分页稳定——同一查询多次返回顺序一致，翻页才不会漏条或重复。
/// 非法取值服务端返回 400，所以客户端不给自由输入，只能从这三个里选。
enum WorkSort {
  /// 入库顺序（`id ASC`）：先灌进来的先出现。
  ///
  /// 契约里省略 `sort` 等价于它，但**客户端的列表默认改成了 [year]**——
  /// 生产库里它就是「最早导入优先」，当默认会让第一屏看起来像数据很旧。
  /// 保留它是因为「想按入库时间看」仍然是个合理需求。
  id('id', '入库顺序'),

  /// 评分高 → 低，无评分排最后。
  rating('rating', '评分最高'),

  /// 年份新 → 旧，无年份排最后。
  year('year', '年份最新');

  const WorkSort(this.value, this.label);

  /// 发给服务端的查询参数值。
  final String value;

  /// 界面上的排序菜单文案。
  final String label;

  static WorkSort fromValue(String? raw) {
    return WorkSort.values.firstWhere(
      (sort) => sort.value == raw,
      orElse: () => WorkSort.id,
    );
  }
}
