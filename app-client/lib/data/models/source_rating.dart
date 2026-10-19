import 'package:flutter/foundation.dart';

/// 契约 2.1：`main_rating` 为 `{value, scale, source}`，**缺失不是 0 分**。
/// 因此整个对象可空，而不是把 null 折算成 0。
@immutable
class SourceRating {
  const SourceRating({
    required this.value,
    required this.scale,
    required this.source,
  });

  final double value;

  /// 当前来源尺度固定 `0-10`，接口尚未保证一定返回，故留默认值。
  final String scale;

  final String source;

  /// JSON 里是 `null`、结构不对、或 value 不是数字时返回 `null`——
  /// 调用方据此**整块不渲染**评分，而不是显示 `0.0`。
  static SourceRating? tryParse(Object? json) {
    if (json is! Map) return null;

    final raw = json['value'];
    final value = switch (raw) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
    };
    if (value == null) return null;

    final scale = json['scale'];
    final source = json['source'];
    return SourceRating(
      value: value,
      scale: scale is String && scale.isNotEmpty ? scale : '0-10',
      source: source is String ? source : '',
    );
  }

  /// 0-10 尺度统一显示一位小数。
  String get display => value.toStringAsFixed(1);

  @override
  bool operator ==(Object other) =>
      other is SourceRating &&
      other.value == value &&
      other.scale == scale &&
      other.source == source;

  @override
  int get hashCode => Object.hash(value, scale, source);

  @override
  String toString() => 'SourceRating($display/$scale)';
}
