import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_collection_cache.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/data/datasources/collection_data_source.dart';
import 'package:otaku_app/data/datasources/schedule_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/models/schedule.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/repositories/schedule_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/reminders/reminder_service.dart';

import 'support/fake_reminder_scheduler.dart';
import 'support/test_overrides.dart';

/// 2026-10-24 是周六。
final DateTime _fixedNow = DateTime(2026, 10, 24, 8);

class _FakeScheduleSource implements ScheduleDataSource {
  _FakeScheduleSource(this.page);

  SchedulePageData? page;
  Object? failure;
  int calls = 0;

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    calls++;
    final error = failure;
    if (error != null) throw error;
    return page!;
  }
}

class _FakeCollectionSource implements CollectionDataSource {
  _FakeCollectionSource(this.items);

  List<CollectionEntry> items;
  Object? failure;

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async {
    final error = failure;
    if (error != null) throw error;
    return items;
  }

  @override
  Future<CollectionState> fetchState(String workId) async =>
      CollectionState(workId: workId, collected: false);

  @override
  Future<CollectionState> add(
    String workId, {
    CollectionStatus? status,
  }) async => CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async => CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<void> remove(String workId) async {}
}

CollectionEntry _entry(String id, CollectionStatus status) => CollectionEntry(
  workId: id,
  workType: WorkType.anime,
  title: '番 $id',
  status: status,
);

SchedulePageData _schedule() => SchedulePageData(
  season: '202604',
  seasons: const ['202604'],
  groups: [
    ScheduleGroup(
      weekday: 6,
      label: '周六',
      items: const [
        ScheduleEntry(scheduleId: 'S-1', title: '周六的番', workId: 'W-1'),
      ],
    ),
  ],
);

void main() {
  late _FakeScheduleSource scheduleSource;
  late _FakeCollectionSource collectionSource;
  late FakeReminderScheduler scheduler;

  setUp(() {
    scheduleSource = _FakeScheduleSource(_schedule());
    collectionSource = _FakeCollectionSource([
      _entry('W-1', CollectionStatus.watching),
    ]);
    scheduler = FakeReminderScheduler();
  });

  ProviderContainer createContainer({
    bool enabled = true,
    String? token = signedInToken,
  }) {
    final container = ProviderContainer(
      overrides: [
        ...authOverrides(token: token),
        localPrefsProvider.overrideWithValue(
          InMemoryLocalPrefs(enabled ? {'reminder_enabled': 'true'} : null),
        ),
        scheduleDataSourceProvider.overrideWithValue(scheduleSource),
        collectionDataSourceProvider.overrideWithValue(collectionSource),
        collectionRepositoryProvider.overrideWithValue(
          CollectionRepository(
            collectionSource,
            cache: InMemoryCollectionCache(),
          ),
        ),
        reminderSchedulerProvider.overrideWithValue(scheduler),
        // 固定时钟：排程结果跟日期强相关，不固定就没法断言。
        reminderServiceProvider.overrideWith(
          (ref) => ReminderService(ref, clock: () => _fixedNow),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settleAuth(ProviderContainer container) async {
    container.read(authControllerProvider);
    for (var i = 0; i < 50; i++) {
      if (container.read(authControllerProvider).status !=
          AuthStatus.checking) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  group('ReminderService', () {
    test('提醒关着时不拉数据，并把已排的清掉', () async {
      final container = createContainer(enabled: false);
      await settleAuth(container);

      await container.read(reminderServiceProvider).refresh();

      expect(scheduler.cancelCalls, 1);
      expect(scheduler.replaceCalls, 0);
      expect(scheduleSource.calls, 0, reason: '关着还去拉档期就是白花一次请求');
    });

    test('未登录时清空——不留上一个账号排的提醒', () async {
      final container = createContainer(token: null);
      await settleAuth(container);

      await container.read(reminderServiceProvider).refresh();

      expect(scheduler.cancelCalls, 1);
      expect(scheduler.replaceCalls, 0);
    });

    test('开着且有「在看」→ 按档期排未来两周', () async {
      final container = createContainer();
      await settleAuth(container);

      await container.read(reminderServiceProvider).refresh();

      expect(scheduler.replaceCalls, 1);
      expect(scheduler.slots.map((slot) => slot.date), [
        DateTime(2026, 10, 24),
        DateTime(2026, 10, 31),
      ]);
      expect(scheduler.slots.first.count, 1);
    });

    test('档期拉不到时保留已排的——不能替数据说「最近没更新」', () async {
      final container = createContainer();
      await settleAuth(container);
      scheduleSource.failure = const ApiException(
        code: ApiErrorCode.network,
        message: '网络不可达',
      );

      await container.read(reminderServiceProvider).refresh();

      expect(scheduler.replaceCalls, 0);
      expect(scheduler.cancelCalls, 0);
    });

    test('收藏拉不到时同样保留已排的', () async {
      final container = createContainer();
      await settleAuth(container);
      collectionSource.failure = const ApiException(
        code: ApiErrorCode.network,
        message: '网络不可达',
      );

      await container.read(reminderServiceProvider).refresh();

      expect(scheduler.replaceCalls, 0);
      expect(scheduler.cancelCalls, 0);
    });

    test('只有「想看 / 看过」时不提醒', () async {
      collectionSource.items = [
        _entry('W-1', CollectionStatus.want),
        _entry('W-2', CollectionStatus.watched),
      ];
      final container = createContainer();
      await settleAuth(container);

      await container.read(reminderServiceProvider).refresh();

      expect(scheduler.replaceCalls, 1);
      expect(scheduler.slots, isEmpty);
    });
  });
}
