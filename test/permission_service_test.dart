import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutty_notifications/flutty_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockMessagingGateway messaging;

  NotificationPermissionService service({
    TargetPlatform platform = TargetPlatform.android,
    Future<PermissionStatus> Function()? androidStatus,
    Future<bool> Function()? androidRationale,
    Future<bool> Function()? androidRuntimePermission,
    Future<SharedPreferences> Function()? preferences,
  }) {
    return NotificationPermissionService(
      messaging: messaging,
      androidNotificationStatus: androidStatus,
      androidShouldShowRationale: androidRationale,
      androidRuntimePermission:
          androidRuntimePermission ?? () async => true, // Android 13+
      preferences: preferences,
      platform: platform,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messaging = MockMessagingGateway();
    stubMessagingDefaults(messaging);
  });

  group('iOS', () {
    test('authorized → granted', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      expect(
        await service(platform: TargetPlatform.iOS).access(),
        NotificationAccess.granted,
      );
    });

    test('provisional → granted', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.provisional);
      expect(
        await service(platform: TargetPlatform.iOS).access(),
        NotificationAccess.granted,
      );
    });

    test('notDetermined → askable', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.notDetermined);
      expect(
        await service(platform: TargetPlatform.iOS).access(),
        NotificationAccess.askable,
      );
    });

    test('denied → blocked', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.denied);
      expect(
        await service(platform: TargetPlatform.iOS).access(),
        NotificationAccess.blocked,
      );
    });
  });

  group('Android', () {
    test('granted → granted', () async {
      expect(
        await service(androidStatus: () async => PermissionStatus.granted)
            .access(),
        NotificationAccess.granted,
      );
    });

    test('denied with rationale (13+, re-askable) → askable', () async {
      expect(
        await service(
          androidStatus: () async => PermissionStatus.denied,
          androidRationale: () async => true,
        ).access(),
        NotificationAccess.askable,
      );
    });

    test('denied without rationale, never asked (13+) → askable', () async {
      expect(
        await service(
          androidStatus: () async => PermissionStatus.denied,
          androidRationale: () async => false,
        ).access(),
        NotificationAccess.askable,
      );
    });

    test('denied without rationale after a request (permanent denial '
        'or <13) → blocked', () async {
      SharedPreferences.setMockInitialValues({
        NotificationPermissionService.requestedKey: true,
      });
      expect(
        await service(
          androidStatus: () async => PermissionStatus.denied,
          androidRationale: () async => false,
        ).access(),
        NotificationAccess.blocked,
      );
    });

    test('denied on Android <13 (no prompt possible) → blocked', () async {
      expect(
        await service(
          androidStatus: () async => PermissionStatus.denied,
          androidRationale: () async => false,
          androidRuntimePermission: () async => false,
        ).access(),
        NotificationAccess.blocked,
      );
    });

    test('markPermissionRequested sets the flag', () async {
      await service().markPermissionRequested();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(NotificationPermissionService.requestedKey), isTrue);
    });

    test('permanentlyDenied → blocked', () async {
      expect(
        await service(
          androidStatus: () async => PermissionStatus.permanentlyDenied,
        ).access(),
        NotificationAccess.blocked,
      );
    });
  });

  test('unsupported platform → blocked', () async {
    expect(
      await service(platform: TargetPlatform.linux).access(),
      NotificationAccess.blocked,
    );
  });
}
