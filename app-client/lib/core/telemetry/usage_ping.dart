import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../network/dio_client.dart';
import '../storage/local_prefs.dart';
import '../storage/local_prefs_provider.dart';
import 'install_id.dart';

/// 启动心跳：告诉服务端「这台安装今天开过 App」。
///
/// 服务端只存 `install_id / 版本 / 平台 / 时间`，不存 IP、不关联账号
/// （表结构见后端 `V27__client_install.sql`）。它是目前**唯一**能回答
/// 「有多少人在用」的准确口径——accesslog 按 IP 估算会被 NAT 和换网扭曲。
///
/// 三条设计约束，改之前先想清楚：
/// 1. **不阻塞启动**：挂在 post-frame 回调里发，失败静默。统计的价值再高，
///    也不该让用户多等一帧，或看到一条为统计而弹出的错误提示。
/// 2. **节流 12 小时**：一天最多两次请求。日活只关心「这天来没来」，
///    每次冷启动都发等于拿用户流量换没人看的细粒度。
/// 3. **先记时间再发请求**：反过来（先发后记）在超时场景下会变成每次启动都重试，
///    弱网用户会持续打请求。宁可丢一次心跳，也不要重试风暴。
class UsagePing {
  UsagePing(
    this._prefs,
    this._dio, {
    DateTime Function()? clock,
    String? platform,
    bool? enabled,
  }) : _clock = clock ?? DateTime.now,
       _platform = platform ?? Platform.operatingSystem,
       _enabled = enabled ?? !AppConfig.useMock;

  final LocalPrefs _prefs;
  final Dio _dio;
  final DateTime Function() _clock;
  final String _platform;

  /// 是否真的发请求。默认跟随 `AppConfig.useMock`——
  /// 生产（`USE_MOCK=false`）发送，Mock 构建与全部 widget 测试不发。
  /// 留成可注入是为了让单测能验「发了什么」，而不是只验「没发」。
  final bool _enabled;

  static const String installIdKey = 'usage.install_id';
  static const String lastPingKey = 'usage.last_ping_at';

  /// 同一安装两次心跳的最小间隔。
  static const Duration throttle = Duration(hours: 12);

  static const String _path = '/api/client/ping';

  /// 到点就发一次；不到点直接返回。
  ///
  /// 返回 `true` 表示真的发了请求（测试用；生产调用方不看返回值）。
  Future<bool> pingIfDue() async {
    // Mock 模式（含全部 widget 测试）不发：没有后端可打，
    // 只会给测试留一个真实网络请求，让 `timersPending` 之类的断言莫名失败。
    if (!_enabled) return false;

    final now = _clock();
    if (!_isDue(now)) return false;

    // 先把时间落盘：即使下面请求失败也不再重试（见类注释第 3 条）。
    await _prefs.write(lastPingKey, now.millisecondsSinceEpoch.toString());

    final installId = await _ensureInstallId();
    if (installId == null) return false;

    try {
      await _dio.post<void>(
        _path,
        data: {
          'install_id': installId,
          'app_version': AppConfig.versionName,
          'platform': _platform,
        },
      );
      return true;
    } on DioException {
      // 统计失败不影响任何功能，也不上报给用户。
      return false;
    }
  }

  /// 读本机存的 install_id，没有或坏掉就生成一个新的写回去。
  ///
  /// 「坏掉」也算没有：如果某次写入被截断（进程被杀在写盘中途），
  /// 那个值永远过不了服务端校验，留着只会年复一年地吃 400。
  Future<String?> _ensureInstallId() async {
    final stored = _prefs.read(installIdKey);
    if (InstallId.isValid(stored)) return stored;

    final generated = InstallId.generate();
    await _prefs.write(installIdKey, generated);
    // 写盘失败（只读文件系统之类）时仍然上报这次：宁可这一次的心跳在服务端
    // 变成一个「只出现过一次的新安装」，也不要因为存不下就永远不参与统计。
    return generated;
  }

  bool _isDue(DateTime now) {
    final raw = _prefs.read(lastPingKey);
    final last = int.tryParse(raw ?? '');
    if (last == null) return true;
    final lastAt = DateTime.fromMillisecondsSinceEpoch(last);
    // 时钟回拨（用户改系统时间/时区）时 last 会落在未来：按「到点」处理，
    // 否则这台设备会被永久静音——那是一种查不出来的数据缺失。
    if (now.isBefore(lastAt)) return true;
    return now.difference(lastAt) >= throttle;
  }
}

final usagePingProvider = Provider<UsagePing>((ref) {
  return UsagePing(
    ref.watch(localPrefsProvider),
    ref.watch(dioProvider),
  );
});
