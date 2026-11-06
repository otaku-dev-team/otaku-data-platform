import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 头像图片的**选择**能力。
///
/// 单独抽一层不是为了「将来可能换实现」，而是两个具体原因：
///
/// 1. **测试不能真调系统选择器**：`openFile` 走平台通道，widget 测试里调用
///    会一直挂在未完成的 Future 上，只能注入假实现来验交互；
/// 2. 选图与「存不存」无关：本页选完**不上传**（见
///    `_ProfileFormState._saveAvatar` 的说明），将来接上传时这一层不用动。
abstract interface class AvatarPicker {
  /// 让用户挑一张图片，返回本地文件路径；用户取消返回 `null`。
  ///
  /// 只返回路径而不是字节：预览交给 `FileImage` 按需解码，
  /// 调用方不必为一张还没上传的图占住内存。
  Future<String?> pickImage();
}

/// 生产实现：系统文件选择器。
///
/// **为什么不是 `image_picker`**：`image_picker` 的 `image_picker_ios` 子包
/// 在当前 pub 镜像上装不下来（归档 301 到 storage 后 pub 客户端不认），
/// 而本项目目标平台是 Android + Windows，`file_selector` 两端都能选图，
/// 且只新增 9 个依赖、零版本漂移。
///
/// 代价是**没有「拍照」**：`file_selector` 只打开文件选择器。真要拍照，
/// 得回到 `image_picker`（或自己写 platform channel）——等换掉镜像源再说。
class FileSelectorAvatarPicker implements AvatarPicker {
  const FileSelectorAvatarPicker();

  /// 只放图片类型。给太宽（比如 `*`）会让用户在文件管理器里翻半天，
  /// 也容易选到视频、文档。
  ///
  /// `extensions` 给 Windows / macOS，`mimeTypes` 给 Android——
  /// Android 的 SAF 只认 MIME，不认扩展名。
  static const XTypeGroup _images = XTypeGroup(
    label: '图片',
    extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
    mimeTypes: <String>['image/jpeg', 'image/png', 'image/webp'],
  );

  @override
  Future<String?> pickImage() async {
    final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[_images]);
    return file?.path;
  }
}

/// 换实现只改这一个 provider；测试用 `overrideWithValue` 注入假选择器。
final avatarPickerProvider = Provider<AvatarPicker>(
  (ref) => const FileSelectorAvatarPicker(),
);
