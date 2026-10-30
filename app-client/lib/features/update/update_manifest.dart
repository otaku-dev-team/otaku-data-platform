import 'package:flutter/foundation.dart';

import '../../core/config/app_config.dart';

/// 远程更新清单（`/downloads/latest.json`）。
///
/// 字段用 **versionCode（整数）** 比较新旧，不用 versionName：`1.10.0` 和
/// `1.9.0` 按字符串比会得到错误结果，而 versionCode 每次发版单调递增。
///
/// 解析刻意宽松：同时接受 camelCase 与 snake_case；`changelog` 可以是字符串
/// 也可以是字符串数组。清单是运维手写的，写错一个大小写就让全量用户收不到
/// 更新，代价比多几行兼容代码大。
@immutable
class UpdateManifest {
  const UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.downloadUrl,
    this.sha256,
    this.changelog = '',
    this.minSupportedVersionCode,
    this.publishedAt,
  });

  final int versionCode;
  final String versionName;

  /// 安装包地址，必须是 http(s)。Android 侧下载后拉起系统安装器。
  final String downloadUrl;

  /// 安装包 sha256（小写十六进制）。可选；给了就必须校验通过才允许安装。
  final String? sha256;

  /// 更新说明，一行一条。
  final String changelog;

  /// 最低可运行版本。当前 versionCode 低于它 = 强制更新（不给「以后再说」）。
  final int? minSupportedVersionCode;

  final String? publishedAt;

  bool get isNewerThanCurrent => versionCode > AppConfig.versionCode;

  bool get isForced =>
      (minSupportedVersionCode ?? 0) > AppConfig.versionCode;

  bool get hasValidDownload =>
      downloadUrl.startsWith('https://') || downloadUrl.startsWith('http://');

  /// 结构不对 / 关键字段缺失 → `null`。调用方按「没有更新」处理。
  static UpdateManifest? tryParse(Object? json) {
    if (json is! Map) return null;

    final code = _asInt(json['versionCode'] ?? json['version_code']);
    final name = _asString(json['versionName'] ?? json['version_name']);
    final url = _asString(json['downloadUrl'] ?? json['download_url']);
    if (code == null || code <= 0) return null;
    if (name == null || name.trim().isEmpty) return null;
    if (url == null || url.trim().isEmpty) return null;

    final manifest = UpdateManifest(
      versionCode: code,
      versionName: name.trim(),
      downloadUrl: url.trim(),
      sha256: _asString(json['sha256']),
      changelog: _asChangelog(json['changelog']),
      minSupportedVersionCode: _asInt(
        json['minSupportedVersionCode'] ?? json['min_supported_version_code'],
      ),
      publishedAt: _asString(json['publishedAt'] ?? json['published_at']),
    );
    return manifest.hasValidDownload ? manifest : null;
  }

  static int? _asInt(Object? raw) => switch (raw) {
    final num n => n.toInt(),
    final String s => int.tryParse(s.trim()),
    _ => null,
  };

  static String? _asString(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    return text.isEmpty ? null : text;
  }

  static String _asChangelog(Object? raw) {
    if (raw is String) return raw.trim();
    if (raw is List) {
      return raw
          .whereType<String>()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .join('\n');
    }
    return '';
  }
}
