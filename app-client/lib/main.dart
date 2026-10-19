import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // window_manager 只有桌面端有实现，Android 上调用会报插件缺失。
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await _setupDesktopWindow();
  }

  runApp(const ProviderScope(child: OtakuApp()));
}

Future<void> _setupDesktopWindow() async {
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(1120, 800),
    minimumSize: Size(720, 560),
    center: true,
    title: 'Otaku',
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
