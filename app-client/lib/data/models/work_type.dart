/// 契约 2.1：`work_type` 是四值枚举。未知取值不抛异常，落到 [unknown]，
/// 这样后端将来加类型时老客户端不会白屏。
enum WorkType {
  anime('anime', '动画'),
  comic('comic', '漫画'),
  game('game', '游戏'),
  novel('novel', '小说'),
  unknown('', '其他');

  const WorkType(this.value, this.label);

  /// 与接口一致的取值，请求 `type` 参数时用它。
  final String value;

  /// 界面上显示的中文名。
  final String label;

  static WorkType fromValue(Object? raw) {
    for (final type in WorkType.values) {
      if (type != WorkType.unknown && type.value == raw) return type;
    }
    return WorkType.unknown;
  }

  /// 筛选栏用的固定顺序，不含 [unknown]。
  static const List<WorkType> selectable = [anime, comic, game, novel];
}
