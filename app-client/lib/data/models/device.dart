import 'package:flutter/foundation.dart';

/// 已登记的设备（推送令牌）。
///
/// 契约见 `docs/openapi.yaml` 的 `Device`，**不含 `token`**：那是凭据，
/// 客户端本来就有，回显只增加泄露面。所以这里也没有。
@immutable
class Device {
  const Device({
    required this.deviceId,
    required this.platform,
    required this.provider,
    required this.enabled,
    this.createdAt,
    this.updatedAt,
  });

  /// 客户端生成的安装级标识，同账号下唯一（服务端以 `(user_id, device_id)` 为键）。
  final String deviceId;

  /// `android` / `windows` / `ios`。
  ///
  /// 这里**存原样字符串而不是枚举**：后端将来加新平台时，老版本客户端不该
  /// 因为解析失败把整页设备都吞掉——不认识的平台按「未知设备」展示即可。
  final String platform;

  /// `fcm` / `apns`。理由同上，用字符串。
  final String provider;

  /// 服务端是否认为这台设备还收推送。
  final bool enabled;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Device.fromJson(Map<String, dynamic> json) {
    final deviceId = json['device_id'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw const FormatException('device_id 缺失或为空');
    }
    return Device(
      deviceId: deviceId,
      platform: json['platform'] is String ? json['platform'] as String : '',
      provider: json['provider'] is String ? json['provider'] as String : '',
      // 缺 `enabled` 时按「启用」处理：把它当停用会让用户误以为推送坏了。
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
    );
  }

  /// 时间解析失败给 `null`，不抛异常：一条设备的时间格式异常，
  /// 不该让整张设备列表变成错误页（铁律 3 的另一面——拿不到就先不显示）。
  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  /// 平台的中文展示名。认不出的平台原样回显，不装作知道。
  String get platformLabel => switch (platform) {
    'android' => 'Android',
    'windows' => 'Windows',
    'ios' => 'iOS',
    _ => platform.isEmpty ? '未知平台' : platform,
  };

  /// 推送通道的展示名。
  String get providerLabel => switch (provider) {
    'fcm' => 'FCM',
    'apns' => 'APNs',
    _ => provider.isEmpty ? '未知通道' : provider,
  };

  @override
  bool operator ==(Object other) =>
      other is Device &&
      other.deviceId == deviceId &&
      other.platform == platform &&
      other.provider == provider &&
      other.enabled == enabled &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(deviceId, platform, provider, enabled, createdAt, updatedAt);

  @override
  String toString() => 'Device($deviceId, $platform)';
}
