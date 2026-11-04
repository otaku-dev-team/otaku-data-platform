import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:otaku_app/data/datasources/device_data_source.dart';
import 'package:otaku_app/data/datasources/device_mock_data_source.dart';
import 'package:otaku_app/data/models/account_user.dart';
import 'package:otaku_app/data/models/device.dart';
import 'package:otaku_app/data/repositories/device_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/devices/device_page.dart';

/// #378 登录设备页。
///
/// 只钉「用户看得见、能操作」的部分：未登录给引导、有设备按契约展示、
/// 解绑后列表立刻少一行、空列表说清楚是空而不是加载失败。
/// 数据一律走假数据源，不碰真接口，也不依赖 Hive。
void main() {
  group('Device 解析', () {
    test('正常字段照契约读出来', () {
      final device = Device.fromJson(<String, dynamic>{
        'device_id': 'dev-1',
        'platform': 'android',
        'provider': 'fcm',
        'enabled': true,
        'created_at': '2026-11-01T09:30:00Z',
        'updated_at': '2026-11-04T22:10:00Z',
      });
      expect(device.deviceId, 'dev-1');
      expect(device.platformLabel, 'Android');
      expect(device.providerLabel, 'FCM');
      expect(device.enabled, isTrue);
      expect(device.createdAt, isNotNull);
    });

    test('缺 device_id 直接抛，不构造半条记录', () {
      expect(
        () => Device.fromJson(<String, dynamic>{'platform': 'android'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('不认识的平台原样回显，不装作知道', () {
      final device = Device.fromJson(<String, dynamic>{
        'device_id': 'dev-2',
        'platform': 'harmony',
        'provider': 'hms',
        'enabled': false,
      });
      expect(device.platformLabel, 'harmony');
      expect(device.providerLabel, 'hms');
      expect(device.enabled, isFalse);
    });

    test('时间格式异常不炸整条记录', () {
      final device = Device.fromJson(<String, dynamic>{
        'device_id': 'dev-3',
        'platform': 'ios',
        'provider': 'apns',
        'enabled': true,
        'created_at': 'not-a-date',
      });
      expect(device.createdAt, isNull);
    });
  });

  group('设备列表页', () {
    testWidgets('未登录时显示登录引导，不显示设备', (tester) async {
      await tester.pumpWidget(host(signedIn: false));
      await tester.pumpAndSettle();

      expect(find.text('登录后查看'), findsOneWidget);
      expect(find.text('解绑'), findsNothing);
    });

    testWidgets('登录后列出设备，标题带平台与通道', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.text('登录设备'), findsOneWidget);
      expect(find.text('解绑'), findsNWidgets(3));
      expect(find.text('Android'), findsNWidgets(2));
      expect(find.text('Windows'), findsOneWidget);
      // 停用的那台要有明确标记，否则用户以为它还在收推送。
      expect(find.text('已停用'), findsOneWidget);
    });

    testWidgets('解绑确认后列表立刻少一行', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(find.text('解绑').first);
      await tester.pumpAndSettle();

      expect(find.text('解绑这台设备？'), findsOneWidget);
      // 对话框里的确认按钮也叫「解绑」，此时是第 4 个可点文本。
      await tester.tap(find.widgetWithText(FilledButton, '解绑'));
      await tester.pumpAndSettle();

      expect(find.text('解绑'), findsNWidgets(2));
      expect(find.text('已解绑'), findsOneWidget);
    });

    testWidgets('没有设备时说清楚是空，不是加载失败', (tester) async {
      await tester.pumpWidget(host(source: _EmptyDeviceDataSource()));
      await tester.pumpAndSettle();

      expect(find.text('还没有登记过设备'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });
  });
}

/// 页面宿主：只覆盖数据源与登录态，其余走真实实现。
Widget host({DeviceDataSource? source, bool signedIn = true}) {
  final container = ProviderContainer(
    overrides: [
      deviceDataSourceProvider.overrideWithValue(
        source ?? MockDeviceDataSource(),
      ),
      authControllerProvider.overrideWith(
        signedIn ? _SignedInAuth.new : _SignedOutAuth.new,
      ),
    ],
  );
  final app = MaterialApp.router(
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const DevicePage()),
        GoRoute(path: '/login', builder: (_, _) => const SizedBox.shrink()),
      ],
    ),
  );
  return UncontrolledProviderScope(container: container, child: app);
}

class _SignedInAuth extends AuthController {
  @override
  AuthState build() => const AuthState(
    status: AuthStatus.signedIn,
    user: AccountUser(userId: 'U-test', username: 'alice'),
  );
}

class _SignedOutAuth extends AuthController {
  @override
  AuthState build() => const AuthState(status: AuthStatus.signedOut);
}

class _EmptyDeviceDataSource implements DeviceDataSource {
  @override
  Future<List<Device>> fetchAll() async => const <Device>[];

  @override
  Future<void> revoke(String deviceId) async {}
}
