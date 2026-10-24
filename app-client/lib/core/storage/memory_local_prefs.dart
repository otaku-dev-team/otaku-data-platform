import 'local_prefs.dart';

/// 内存版本机偏好。
///
/// 两个用途：Hive 打开失败时的降级（偏好丢了只是回到默认值），
/// 以及测试里替换真实实现——与 `InMemoryWorkCache` 同一个理由。
class InMemoryLocalPrefs implements LocalPrefs {
  InMemoryLocalPrefs([Map<String, String>? initial])
    : _values = {...?initial};

  final Map<String, String> _values;

  @override
  String? read(String key) => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}
