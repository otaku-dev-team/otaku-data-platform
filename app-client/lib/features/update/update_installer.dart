import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// 安装结果。
enum InstallResult {
  /// 系统安装器已拉起（用户还要在系统界面点「安装」）。
  opened,

  /// 拉不起来：多半是没给「安装未知应用」权限。
  failed,

  /// 当前平台不支持侧载（Windows / iOS）。
  unsupported,
}

/// 「下载到哪」与「怎么拉起安装器」抽成接口，测试里换成假实现，
/// 不让平台通道（path_provider / open_filex）进 widget 测试。
abstract interface class UpdateInstaller {
  Future<String> prepareDownloadPath(int versionCode);

  Future<InstallResult> install(String filePath);
}

class PlatformUpdateInstaller implements UpdateInstaller {
  const PlatformUpdateInstaller();

  @override
  Future<String> prepareDownloadPath(int versionCode) async {
    // 临时目录：安装完成后系统会自己清理；不放到用户可见的 Download
    // 目录，避免每次更新都留一个几百 MB 的 APK。
    final dir = await getTemporaryDirectory();
    return '${dir.path}${Platform.pathSeparator}otaku-$versionCode.apk';
  }

  @override
  Future<InstallResult> install(String filePath) async {
    // 只有 Android 能侧载。Windows 走浏览器下载，iOS 只能 App Store。
    if (!Platform.isAndroid) return InstallResult.unsupported;
    try {
      final result = await OpenFilex.open(
        filePath,
        type: 'application/vnd.android.package-archive',
      );
      return result.type == ResultType.done
          ? InstallResult.opened
          : InstallResult.failed;
    } on Object {
      return InstallResult.failed;
    }
  }
}

final updateInstallerProvider = Provider<UpdateInstaller>((ref) {
  return const PlatformUpdateInstaller();
});
