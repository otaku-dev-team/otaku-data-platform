import 'package:flutter/foundation.dart';

/// 服务端下发的运行期配置（`GET /api/app/config`）。
///
/// 存在意义：以前「改个公告 / 调个开关」都得发版装包，一个文案改动要等用户升级。
/// 现在这类东西进配置，客户端启动拉一次、落本地缓存，下次打开就用新的。
///
/// 契约：`values` 是任意 JSON 的键值袋，**客户端只认自己认识的键**——
/// 后端加新键不需要客户端跟着发版，这是这一层唯一的价值，别写成强类型映射。
/// [version] 是后端给的配置版本（毫秒时间戳），用来判断本地缓存还能不能直接用。
@immutable
class RemoteConfig {
  const RemoteConfig({required this.version, required this.values});

  final int version;
  final Map<String, dynamic> values;

  /// 没拿到过配置时的空壳：所有 getter 都返回"没配"，调用方不需要判空。
  static const RemoteConfig empty = RemoteConfig(
    version: 0,
    values: <String, dynamic>{},
  );

  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    final rawValues = json['values'];
    return RemoteConfig(
      version: json['version'] is int ? json['version'] as int : 0,
      values: rawValues is Map<String, dynamic>
          ? rawValues
          : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'values': values,
  };

  /// 首页公告。`app.notice` 缺键 / 形状不对 / `enabled=false` 都返回 null。
  RemoteNotice? get notice => RemoteNotice.fromJson(values['app.notice']);
}

/// 首页顶部公告条。
///
/// [dismissible] 为 true 时用户可以关掉，且**关掉的是这个版本**——
/// 运营改了文案（版本变了）之后会重新出现，不会因为用户关过一次就再也看不到。
@immutable
class RemoteNotice {
  const RemoteNotice({
    required this.enabled,
    required this.text,
    this.url,
    this.dismissible = true,
  });

  final bool enabled;
  final String text;
  final String? url;
  final bool dismissible;

  static RemoteNotice? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) {
      return null;
    }
    final url = raw['url'];
    return RemoteNotice(
      enabled: raw['enabled'] == true,
      text: text,
      url: url is String && url.isNotEmpty ? url : null,
      dismissible: raw['dismissible'] != false,
    );
  }
}
