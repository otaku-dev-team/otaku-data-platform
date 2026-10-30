import 'dart:math';

/// 安装级匿名标识（UUID v4）。
///
/// 用途只有一个：让服务端能把「同一台设备的多次启动」认成同一台，
/// 从而算出装机量与日活（`POST /api/client/ping`，契约见 `docs/openapi.yaml`）。
///
/// **刻意不做的事**（这几条是隐私边界，不是实现细节）：
/// - 不取 IMEI / OAID / AndroidID / MAC / 序列号——那类标识跨应用可关联，
///   一旦采集，「匿名统计」立刻变成个人信息处理，合规成本与风险都不值；
/// - 不与账号关联。登录与否都上报同一个 install_id，服务端也不知道它属于谁；
/// - 不随设备特征变化。纯随机，两台一模一样的手机也会得到两个不同的 id。
///
/// 重装 App 会生成新的 id（存的是应用私有目录），所以这个口径叫「安装量」而不是「设备量」。
abstract final class InstallId {
  const InstallId._();

  /// 生成一个 UUID v4。
  ///
  /// [random] 只给测试用：注入固定种子的 `Random` 才能断言输出形状。
  /// 生产路径必须走 `Random.secure()`——用普通 `Random()` 的伪随机序列
  /// 在同一时刻启动的两台设备上有可能撞车（种子取时钟）。
  static String generate([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));

    // 版本位 0100（v4）、变体位 10xx（RFC 4122）。少了这两步，
    // 服务端正则会拒（后端要求严格的 UUID v4 形状）。
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  /// 形状校验（小写 8-4-4-4-12）。
  ///
  /// 存在的理由不是「防呆」：服务端已经会拒非法值，那边只校验形状就够了。
  /// 这里校验的是**本机存的那份值**——用户手动改过偏好、或某次写入被截断，
  /// 读出来是个坏值。此时应当重新生成，而不是年复一年地上报同一个 400。
  static bool isValid(String? value) {
    if (value == null || value.length != 36) return false;
    return RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(value);
  }
}
