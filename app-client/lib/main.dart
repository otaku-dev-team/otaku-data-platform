import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/diagnostics/frame_stats.dart';
import 'core/storage/collection_cache_provider.dart';
import 'core/storage/recent_views_provider.dart';
import 'core/storage/work_cache_provider.dart';
import 'core/theme/app_layout.dart';

/// 窗口尺寸的本地存储键。只存尺寸，不存位置——见 [_readSavedWindowSize]。
const String _windowWidthKey = 'window.width';
const String _windowHeightKey = 'window.height';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // window_manager 只有桌面端有实现，Android 上调用会报插件缺失。
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await _setupDesktopWindow();
  }

  // 离线缓存。必须在 runApp 之前打开：缓存盒是异步开的，
  // 放到 runApp 之后会出现「首屏还没读缓存，缓存才刚准备好」的竞态。
  //
  // 打不开不算致命错误——已降级为内存缓存，App 照常启动。
  await WorkCacheHolder.instance.initialize();
  // 收藏缓存单独一个盒：退出登录时要清它，但作品缓存是公共数据可以留着。
  await CollectionCacheHolder.instance.initialize();
  // 浏览历史同样单独一个盒，但它**不在退出登录时清**：
  // 它是纯本机数据，清了就再也拿不回来（详见 RecentViewsStore 的注释）。
  await RecentViewsHolder.instance.initialize();

  // 只在 OTAKU_FRAME_STATS=true 时生效，正常构建是空操作。
  FrameStats.start();

  runApp(const ProviderScope(child: OtakuApp()));
}

Future<void> _setupDesktopWindow() async {
  await windowManager.ensureInitialized();

  final savedSize = await _readSavedWindowSize();

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: savedSize ?? const Size(1120, 800),
      // 最小 900×600（flutter-lead-plan §6）。再窄下去，列表的双列网格会退化，
      // 详情页的 720 双栏断点也会失效，两端差异清单里的布局要求就落不住。
      minimumSize: const Size(
        AppLayout.minWindowWidth,
        AppLayout.minWindowHeight,
      ),
      center: true,
      title: 'Otaku',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  windowManager.addListener(_WindowSizePersister());
}

/// 只恢复尺寸，不恢复位置。
///
/// 位置看起来更贴心，但多显示器拔掉一条线之后，上次的位置可能落在已经不存在
/// 的屏幕上——窗口启动后「不见了」，只能靠任务栏找回来。尺寸没有这个问题，
/// 而用户真正关心的是「上次拉多大」。
Future<Size?> _readSavedWindowSize() async {
  final prefs = await SharedPreferences.getInstance();
  final width = prefs.getDouble(_windowWidthKey);
  final height = prefs.getDouble(_windowHeightKey);
  if (width == null || height == null) return null;
  if (width < AppLayout.minWindowWidth ||
      height < AppLayout.minWindowHeight) {
    return null;
  }
  return Size(width, height);
}

/// 窗口尺寸变化时落盘。
///
/// 拖动边框会让 `onWindowResize` 每秒触发几十次，每次都写盘没有意义，
/// 停手 400ms 之后写一次。进程被强杀时最多丢最后一次调整，可以接受。
class _WindowSizePersister with WindowListener {
  Timer? _debounce;

  @override
  void onWindowResize() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    final size = await windowManager.getSize();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_windowWidthKey, size.width);
    await prefs.setDouble(_windowHeightKey, size.height);
  }
}
