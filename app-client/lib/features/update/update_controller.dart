import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_installer.dart';
import 'update_manifest.dart';
import 'update_service.dart';
import 'update_store.dart';

enum UpdatePhase {
  idle,
  checking,

  /// 有可用更新，等用户决定（弹窗展示中）。
  available,
  downloading,
  ready,
  installing,
  error,
}

@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.manifest,
    this.progress = 0,
    this.error,
    this.downloadedPath,
    this.receivedBytes = 0,
    this.totalBytes,
    this.bytesPerSecond = 0,
  });

  final UpdatePhase phase;
  final UpdateManifest? manifest;

  /// 0–1。`total` 未知时保持 0，UI 用不确定进度条。
  final double progress;
  final String? error;
  final String? downloadedPath;

  /// 已下载字节数 / 总字节数（服务器没给 Content-Length 时为 null）。
  final int receivedBytes;
  final int? totalBytes;

  /// 实测下载速度（字节/秒），滑动窗口估算，不是瞬时值。
  ///
  /// 存在的意义不只是好看：更新包走的可能是很慢的线路，光有百分比时
  /// 用户看到 3% 停着会以为卡死；有速度就知道「是在下，只是慢」。
  final double bytesPerSecond;

  /// 剩余时间估算；速度未知时返回 null。
  Duration? get remaining {
    final total = totalBytes;
    if (total == null || bytesPerSecond <= 0 || total <= receivedBytes) {
      return null;
    }
    return Duration(seconds: ((total - receivedBytes) / bytesPerSecond).ceil());
  }

  bool get isBusy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading;
}

class UpdateController extends Notifier<UpdateState> {
  CancelToken? _cancelToken;

  /// 速度滑动窗口的采样点。`onReceiveProgress` 触发很密（每个数据块一次），
  /// 每次都算一遍会让进度条抖得看不清，所以只在窗口过去后才更新一次。
  DateTime? _sampleAt;
  int _sampleReceived = 0;
  double _speed = 0;

  @override
  UpdateState build() => const UpdateState();

  /// 检查更新。返回可展示的清单；没有更新 / 被忽略 / 网络失败都返回 `null`。
  ///
  /// [manual] 为用户主动点「检查更新」：此时**绕过忽略标记**——他主动来问，
  /// 不该被自己上次点的「忽略」挡住。
  Future<UpdateManifest?> check({bool manual = false}) async {
    if (state.isBusy) return null;

    state = const UpdateState(phase: UpdatePhase.checking);

    final UpdateManifest? manifest;
    try {
      manifest = await ref.read(updateServiceProvider).fetchLatest();
    } on Object {
      if (!ref.mounted) return null;
      // 自动检查失败不打扰用户（启动时网络本来就可能没就绪）；
      // 手动点「检查更新」要说清是网络问题，不能谎报「已是最新」。
      state = manual
          ? const UpdateState(
              phase: UpdatePhase.error,
              error: '检查更新失败，请检查网络后重试',
            )
          : const UpdateState();
      return null;
    }
    if (!ref.mounted) return null;

    if (manifest == null || !manifest.isNewerThanCurrent) {
      state = const UpdateState();
      return null;
    }
    if (!manual && ref.read(updateIgnoreStoreProvider).isIgnored(manifest)) {
      state = const UpdateState();
      return null;
    }

    state = UpdateState(phase: UpdatePhase.available, manifest: manifest);
    return manifest;
  }

  /// 忽略这个版本：本次 App 版本内不再自动提示。
  Future<void> ignore() async {
    final manifest = state.manifest;
    if (manifest == null) return;
    await ref.read(updateIgnoreStoreProvider).ignore(manifest);
    if (!ref.mounted) return;
    state = const UpdateState();
  }

  Future<bool> download() async {
    final manifest = state.manifest;
    if (manifest == null) return false;
    if (state.phase == UpdatePhase.downloading) return false;

    final path = await ref
        .read(updateInstallerProvider)
        .prepareDownloadPath(manifest.versionCode);
    // 下到 `.part`，下完才改名成正式文件。
    //
    // 这样取消 / 断网留下的半截文件天然就是「可续传的进度」：正式文件名
    // 一旦出现就意味着它是完整的。以前是直接写正式路径 + `deleteOnError`，
    // 一断就全删——20MB 的包在慢线路上重下很肉痛。
    final partPath = '$path$_partSuffix';
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _sampleAt = null;
    _sampleReceived = 0;
    _speed = 0;
    state = UpdateState(phase: UpdatePhase.downloading, manifest: manifest);

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    try {
      await _downloadResumable(
        dio: dio,
        url: manifest.downloadUrl,
        partPath: partPath,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          if (!ref.mounted) return;

          // 400ms 窗口估算瞬时速度：太短会被单块抖动带偏，太长则反应迟钝。
          final now = DateTime.now();
          final since = _sampleAt;
          if (since == null) {
            _sampleAt = now;
            _sampleReceived = received;
          } else {
            final ms = now.difference(since).inMilliseconds;
            if (ms >= 400) {
              final delta = received - _sampleReceived;
              if (delta >= 0) _speed = delta * 1000 / ms;
              _sampleAt = now;
              _sampleReceived = received;
            }
          }

          state = UpdateState(
            phase: UpdatePhase.downloading,
            manifest: manifest,
            progress: total != null && total > 0
                ? (received / total).clamp(0.0, 1.0).toDouble()
                : 0,
            receivedBytes: received,
            totalBytes: total,
            bytesPerSecond: _speed,
          );
        },
      );

      if (!ref.mounted) return false;

      // 改名到正式文件。上一次留下的同名旧包先删掉，rename 才不会失败。
      if (await File(path).exists()) await _deleteQuietly(path);
      await File(partPath).rename(path);

      final expected = manifest.sha256;
      if (expected != null && expected.isNotEmpty) {
        final ok = await _sha256Matches(path, expected);
        if (!ok) {
          await _deleteQuietly(path);
          if (!ref.mounted) return false;
          state = UpdateState(
            phase: UpdatePhase.error,
            manifest: manifest,
            error: '安装包校验失败（sha256 不匹配），请重试',
          );
          return false;
        }
      }

      if (!ref.mounted) return false;
      state = UpdateState(
        phase: UpdatePhase.ready,
        manifest: manifest,
        progress: 1,
        downloadedPath: path,
      );
      return true;
    } on Object catch (error) {
      // **不删 `.part`**：断网 / 取消留下的进度是下次续传的本钱。
      // 只有校验失败（内容已经错了）才删，那在成功分支里处理。
      if (!ref.mounted) return false;

      if (error is DioException && CancelToken.isCancel(error)) {
        state = UpdateState(phase: UpdatePhase.available, manifest: manifest);
        return false;
      }
      state = UpdateState(
        phase: UpdatePhase.error,
        manifest: manifest,
        error: '下载失败：${_shortError(error)}',
      );
      return false;
    } finally {
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  void cancelDownload() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  /// 拉起系统安装器。安装动作由系统完成，App 只负责把文件交出去。
  Future<InstallResult> install() async {
    final manifest = state.manifest;
    final path = state.downloadedPath;
    if (manifest == null || path == null) return InstallResult.failed;

    state = UpdateState(
      phase: UpdatePhase.installing,
      manifest: manifest,
      progress: 1,
      downloadedPath: path,
    );
    final result = await ref.read(updateInstallerProvider).install(path);
    if (!ref.mounted) return result;

    state = switch (result) {
      InstallResult.opened => UpdateState(
        phase: UpdatePhase.installing,
        manifest: manifest,
        progress: 1,
        downloadedPath: path,
      ),
      InstallResult.unsupported => UpdateState(
        phase: UpdatePhase.error,
        manifest: manifest,
        error: '当前平台不支持应用内安装，请手动下载安装包',
        downloadedPath: path,
      ),
      InstallResult.failed => UpdateState(
        phase: UpdatePhase.error,
        manifest: manifest,
        // 真机上最常见的原因，直接把动作写出来，别让用户猜。
        error: '无法拉起安装器：请在系统设置里允许「安装未知应用」后重试',
        downloadedPath: path,
      ),
    };
    return result;
  }

  /// 关闭弹窗 / 重新检查前复位。
  void reset() {
    _cancelToken?.cancel();
    _cancelToken = null;
    state = const UpdateState();
  }

  /// 下载中的临时后缀。正式文件名一出现就代表「完整」。
  static const String _partSuffix = '.part';

  /// 带续传的下载：`.part` 已有内容时用 `Range` 接着要。
  ///
  /// 服务器有可能忽略 `Range`（回 200 + 全量）。那时追加写会把整包接到旧
  /// 残片后面，得到「看起来下完了、sha256 却不对」的文件——比直接失败更坏。
  /// 所以检查状态码：不是 206 就作废重下一次（只重一次）。
  Future<void> _downloadResumable({
    required Dio dio,
    required String url,
    required String partPath,
    required CancelToken cancelToken,
    required void Function(int received, int? total) onProgress,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final file = File(partPath);
      final existing = await file.exists() ? await file.length() : 0;
      final options = existing > 0
          ? Options(headers: {'Range': 'bytes=$existing-'})
          : null;

      final response = await dio.download(
        url,
        partPath,
        options: options,
        cancelToken: cancelToken,
        // 失败保留文件，下次接着下。
        deleteOnError: false,
        fileAccessMode: existing > 0
            ? FileAccessMode.append
            : FileAccessMode.write,
        onReceiveProgress: (received, total) => onProgress(
          existing + received,
          total > 0 ? existing + total : null,
        ),
      );

      if (existing > 0 && response.statusCode == 200) {
        // 服务器不认 Range：上面已经追加了全量内容，整份作废重来。
        await _deleteQuietly(partPath);
        continue;
      }
      return;
    }
    throw StateError('服务器不支持断点续传');
  }

  static Future<bool> _sha256Matches(String path, String expected) async {    // 流式算，不把几百 MB 的 APK 整个读进内存。
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString().toLowerCase() == expected.trim().toLowerCase();
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // 删不掉不影响下次下载（会覆盖写）；忽略。
    }
  }

  static String _shortError(Object error) {
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout => '连接超时',
        DioExceptionType.connectionError => '网络不可用',
        DioExceptionType.badResponse =>
          '服务器返回 ${error.response?.statusCode ?? '错误'}',
        _ => error.message ?? '网络错误',
      };
    }
    return error.toString();
  }
}

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
