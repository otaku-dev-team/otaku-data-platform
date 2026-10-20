import 'dart:async';

import 'package:flutter/scheduler.dart';

/// 帧耗时统计，给阶段 3 的性能基线用。
///
/// **默认关闭**：只有 `--dart-define=OTAKU_FRAME_STATS=true` 构建时才会注册
/// `addTimingsCallback`，正常构建不付任何代价，也不往 stdout 写东西。
///
/// ```
/// flutter run -d windows --profile \
///   --dart-define=USE_MOCK=false \
///   --dart-define=OTAKU_FRAME_STATS=true
/// ```
///
/// 每 2 秒打一行，字段含义：
/// - `build`：UI 线程构建一帧的耗时（布局 + 绘制指令生成）
/// - `raster`：光栅化耗时（GPU 线程）
/// - `jank`：超过 16.7ms（60Hz 一帧预算）的帧占比
///
/// 只在 profile / debug 下有意义，release 的 FrameTiming 精度取决于平台。
abstract final class FrameStats {
  static const bool enabled = bool.fromEnvironment('OTAKU_FRAME_STATS');

  /// 微秒。每 2 秒清空一次，避免长时间运行把内存吃了。
  static final List<int> _build = <int>[];
  static final List<int> _raster = <int>[];
  static Timer? _timer;

  static void start() {
    if (!enabled) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) => dump());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _build.add(timing.buildDuration.inMicroseconds);
      _raster.add(timing.rasterDuration.inMicroseconds);
    }
  }

  /// 已发出的接口请求数。滚动基线里用它回答「滚了这么久到底翻了几页」，
  /// 比读页面上的条数可靠——条数是推断，请求数是事实。
  static int requests = 0;

  /// 由 dio 拦截器调用；未开启统计时不累加，避免白跑。
  static void noteRequest() {
    if (enabled) requests++;
  }

  static void dump() {
    if (_build.isEmpty) return;
    final count = _build.length;
    final jank = _build.where((us) => us > 16700).length;

    // ignore: avoid_print
    print(
      '[frame] n=$count '
      'build p50=${_ms(_percentile(_build, 0.50))} '
      'p95=${_ms(_percentile(_build, 0.95))} '
      'max=${_ms(_build.reduce((a, b) => a > b ? a : b))} | '
      'raster p50=${_ms(_percentile(_raster, 0.50))} '
      'p95=${_ms(_percentile(_raster, 0.95))} | '
      'jank=${(jank * 100 / count).toStringAsFixed(1)}% '
      'requests=$requests',
    );
    _build.clear();
    _raster.clear();
  }

  static String _ms(int micros) => (micros / 1000).toStringAsFixed(2);

  /// `sorted` 的调用方各自拷贝一份，样本量只有几十到几百，成本可忽略。
  static int _percentile(List<int> values, double p) {
    final sorted = [...values]..sort();
    final index = (sorted.length * p).floor().clamp(0, sorted.length - 1);
    return sorted[index];
  }
}
