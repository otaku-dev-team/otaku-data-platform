import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_prefs.dart';
import '../../core/storage/local_prefs_provider.dart';
import '../auth/auth_controller.dart';

/// 搜索历史。纯本机、按账号分桶、最多 [maxEntries] 条。
///
/// 三个刻意的取舍：
///
/// 1. **只在「明确提交」时记**：回车 / 键盘上的搜索键、或点一条历史 chip。
///    输入框是边打字边搜（300ms 防抖），如果把防抖触发的查询也记下来，
///    历史会被「进」「进击」「进击的」三连撑满——那不是用户搜过什么，
///    那是打字过程。宁可少记，也不要记成噪音。
/// 2. **按账号分桶**（未登录走 `guest`）。与浏览历史同一条规则：搜索词会
///    暴露这台机器上的人在找什么。
/// 3. **去重不区分大小写，命中就置顶**。搜过 `nhk` 再搜 `NHK`，
///    历史里只留最后那一次，位置在最前。
class SearchHistoryController extends Notifier<List<String>> {
  /// 最多记几条。搜索框下面是一排 chips，超过 8 条会折成三四行，
  /// 把筛选栏推得看不见——历史是提示，不该挤占主内容。
  static const int maxEntries = 8;

  /// 未登录时的桶名。与 `RecentViewsController.guestOwner` 同一个值。
  static const String guestOwner = 'guest';

  static const String _keyPrefix = 'recent_query:';

  @override
  List<String> build() {
    // watch 账号：登录 / 退出 / 换号时自动换桶。
    final raw = ref.watch(localPrefsProvider).read(_keyOf(_ownerOf(ref)));
    return raw == null ? const <String>[] : StringListCodec.decode(raw);
  }

  static String _ownerOf(Ref ref) =>
      ref.watch(authControllerProvider.select((state) => state.user?.userId)) ??
      guestOwner;

  static String _keyOf(String ownerKey) => '$_keyPrefix$ownerKey';

  /// 记一条。空白串直接忽略（搜索框里只敲了空格不该进历史）。
  void record(String query) {
    final text = query.trim();
    if (text.isEmpty) return;

    final next = <String>[
      text,
      for (final item in state)
        if (item.toLowerCase() != text.toLowerCase()) item,
    ];
    if (next.length > maxEntries) next.removeRange(maxEntries, next.length);
    _commit(next);
  }

  /// 删掉一条。界面上 chips 的 × 用它。
  void remove(String query) {
    final text = query.trim();
    final next = [
      for (final item in state)
        if (item.toLowerCase() != text.toLowerCase()) item,
    ];
    if (next.length == state.length) return;
    _commit(next);
  }

  /// 清空当前账号的历史。
  void clear() => _commit(const <String>[]);

  void _commit(List<String> next) {
    final items = List<String>.unmodifiable(next);
    state = items;

    final owner = ref.read(
      authControllerProvider.select((state) => state.user?.userId),
    );
    // 落盘不 await：内存里已是最终状态，输入框不用等磁盘。
    unawaited(
      ref
          .read(localPrefsProvider)
          .write(_keyOf(owner ?? guestOwner), StringListCodec.encode(items)),
    );
  }
}

final searchHistoryProvider =
    NotifierProvider<SearchHistoryController, List<String>>(
      SearchHistoryController.new,
    );
