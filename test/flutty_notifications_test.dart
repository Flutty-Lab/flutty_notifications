import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutty_notifications/flutty_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mocks.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockMessagingGateway messaging;
  late MockLocalNotificationsGateway localNotifications;
  late MockBadgeService badge;
  late MockTokenStore tokenStore;
  late FluttyNotifications notifications;
  late List<String> persistedTokens;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messaging = MockMessagingGateway();
    stubMessagingDefaults(messaging);
    localNotifications = MockLocalNotificationsGateway();
    when(() => localNotifications.initialize(onTap: any(named: 'onTap')))
        .thenAnswer((invocation) async {
          localNotifications.onTap =
              invocation.namedArguments[#onTap] as void Function(String?);
        });
    when(
      () => localNotifications.show(
        title: any(named: 'title'),
        body: any(named: 'body'),
        channelId: any(named: 'channelId'),
        channelName: any(named: 'channelName'),
        channelDescription: any(named: 'channelDescription'),
        payload: any(named: 'payload'),
      ),
    ).thenAnswer((_) async {});
    badge = MockBadgeService();
    when(badge.reset).thenAnswer((_) async {});
    tokenStore = MockTokenStore();
    persistedTokens = [];
    notifications = FluttyNotifications(
      messaging: messaging,
      localNotifications: localNotifications,
      badgeService: badge,
      tokenStore: tokenStore,
      platform: TargetPlatform.iOS,
    );
  });

  tearDown(() {
    notifications.dispose();
    messaging.registrationController.close();
    messaging.messageController.close();
    messaging.messageOpenedAppController.close();
  });

  Future<bool> persist(String token) async {
    persistedTokens.add(token);
    return true;
  }

  group('init', () {
    test('registers the background handler and resets the badge', () async {
      await notifications.init(onTokenPersist: persist);
      verify(() => messaging.setBackgroundMessageHandler(any())).called(1);
      verify(badge.reset).called(1);
    });

    test('does not request permission', () async {
      await notifications.init(onTokenPersist: persist);
      verifyNever(messaging.requestPermission);
    });

    test('registerBackgroundHandler: false → no handler registered', () async {
      await notifications.init(
        onTokenPersist: persist,
        registerBackgroundHandler: false,
      );
      verifyNever(() => messaging.setBackgroundMessageHandler(any()));
    });

    test('a local notifications failure does not stop '
        'FCM registration', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      when(() => localNotifications.initialize(onTap: any(named: 'onTap')))
          .thenThrow(Exception('broken plugin'));
      await notifications.init(onTokenPersist: persist);
      await flush();
      expect(persistedTokens, ['fcm-token']);
    });

    test(
      'registers the token without asking when permission is already granted',
      () async {
        when(messaging.notificationSettings)
            .thenAnswer((_) async => AuthorizationStatus.authorized);
        await notifications.init(onTokenPersist: persist);
        await flush();
        expect(persistedTokens, ['fcm-token']);
        verify(() => messaging.register()).called(1);
      },
    );

    test(
      'does not register the token when permission is not granted',
      () async {
        await notifications.init(onTokenPersist: persist);
        await flush();
        expect(persistedTokens, isEmpty);
        verifyNever(() => messaging.register());
      },
    );

    test('does not re-persist an already sent token', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      tokenStore.stored = 'fcm-token';
      await notifications.init(onTokenPersist: persist);
      await flush();
      expect(persistedTokens, isEmpty);
    });

    test('a failed send is not stored and will be retried', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      await notifications.init(onTokenPersist: (_) async => false);
      await flush();
      expect(tokenStore.persistedToken, isNull);
    });

    test('an FCM token change is persisted', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      await notifications.init(onTokenPersist: persist);
      await flush();
      messaging.registrationController.add('fcm-token-2');
      await flush();
      expect(persistedTokens, ['fcm-token', 'fcm-token-2']);
    });
  });

  group('requestPermission', () {
    test('granted → registers the token', () async {
      when(messaging.requestPermission)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      await notifications.init(onTokenPersist: persist);
      final access = await notifications.requestPermission();
      await flush();
      expect(access, NotificationAccess.granted);
      expect(persistedTokens, ['fcm-token']);
    });

    test('denied → no registration', () async {
      await notifications.init(onTokenPersist: persist);
      final access = await notifications.requestPermission();
      await flush();
      expect(access, NotificationAccess.blocked);
      expect(persistedTokens, isEmpty);
    });
  });

  group('messages', () {
    test('foreground message → local notification, badge reset '
        'and callback', () async {
      final received = <PushMessage>[];
      await notifications.init(
        onTokenPersist: persist,
        onForegroundMessage: received.add,
      );
      messaging.messageController.add(
        const PushMessage(
          title: 'Title',
          body: 'Body',
          data: {'route': '/dashboard', 'conversation_id': '42'},
        ),
      );
      await flush();
      // The payload carries the full message, not just the route.
      final captured = verify(
        () => localNotifications.show(
          title: 'Title',
          body: 'Body',
          channelId: any(named: 'channelId'),
          channelName: any(named: 'channelName'),
          payload: captureAny(named: 'payload'),
        ),
      ).captured;
      final decoded = jsonDecode(captured.single as String) as Map;
      expect(decoded['data'], {'route': '/dashboard', 'conversation_id': '42'});
      verify(badge.reset).called(greaterThanOrEqualTo(2));
      expect(received.single.route, '/dashboard');
    });

    test('tap from background → callback with the route', () async {
      PushMessage? tapped;
      await notifications.init(
        onTokenPersist: persist,
        onNotificationTap: (m) => tapped = m,
      );
      messaging.messageOpenedAppController.add(
        const PushMessage(data: {'route': '/families/1'}),
      );
      await flush();
      expect(tapped?.route, '/families/1');
    });

    test(
      'tap on local notification → callback with the full message',
      () async {
        PushMessage? tapped;
        await notifications.init(
          onTokenPersist: persist,
          onNotificationTap: (m) => tapped = m,
        );
        localNotifications.onTap?.call(
          jsonEncode({
            'title': 'Title',
            'body': 'Body',
            'data': {'route': '/child', 'conversation_id': '42'},
          }),
        );
        await flush();
        expect(tapped?.title, 'Title');
        expect(tapped?.body, 'Body');
        expect(tapped?.route, '/child');
        expect(tapped?.data['conversation_id'], '42');
      },
    );

    test('free-text local payload → read as a route', () async {
      PushMessage? tapped;
      await notifications.init(
        onTokenPersist: persist,
        onNotificationTap: (m) => tapped = m,
      );
      localNotifications.onTap?.call('/child');
      await flush();
      expect(tapped?.route, '/child');
    });

    test('app launched by a notification → callback', () async {
      PushMessage? tapped;
      when(
        messaging.getInitialMessage,
      ).thenAnswer((_) async => const PushMessage(data: {'route': '/quests'}));
      await notifications.init(
        onTokenPersist: persist,
        onNotificationTap: (m) => tapped = m,
      );
      await flush();
      expect(tapped?.route, '/quests');
    });
  });

  group('registerDevice', () {
    test('re-registers the token after unregisterDevice (re-login)', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      await notifications.init(onTokenPersist: persist);
      await flush();
      await notifications.unregisterDevice();
      persistedTokens.clear();
      await notifications.registerDevice();
      await flush();
      // The token comes back via currentToken(), not via a re-emission.
      expect(persistedTokens, contains('fcm-token'));
      expect(tokenStore.persistedToken, 'fcm-token');
    });

    test('without permission → no registration', () async {
      await notifications.init(onTokenPersist: persist);
      await notifications.registerDevice();
      await flush();
      expect(persistedTokens, isEmpty);
      verifyNever(() => messaging.register());
    });

    test('does not duplicate the send when register() emits the token '
        'during the direct read', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      // Slow send: the race window between the stream emission and
      // the direct read must produce a single request.
      await notifications.init(
        onTokenPersist: (token) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          persistedTokens.add(token);
          return true;
        },
      );
      await flush();
      await notifications.unregisterDevice();
      persistedTokens.clear();
      // register() emits 'fcm-token' via onRegistered while
      // registerDevice reads it via currentToken(): a single send.
      await notifications.registerDevice();
      await flush();
      expect(persistedTokens, ['fcm-token']);
    });
  });

  group('unregisterDevice', () {
    test('calls the remove callback and forgets the token', () async {
      final removed = <String>[];
      tokenStore.stored = 'fcm-token';
      await notifications.init(
        onTokenPersist: persist,
        onTokenRemove: (t) async => removed.add(t),
      );
      await notifications.unregisterDevice();
      expect(removed, ['fcm-token']);
      expect(tokenStore.persistedToken, isNull);
    });

    test('forgets the token even when removal fails', () async {
      tokenStore.stored = 'fcm-token';
      await notifications.init(
        onTokenPersist: persist,
        onTokenRemove: (_) async => throw Exception('network'),
      );
      await notifications.unregisterDevice();
      expect(tokenStore.persistedToken, isNull);
    });
  });

  test('unsupported platform → init does nothing', () async {
    notifications = FluttyNotifications(
      messaging: messaging,
      localNotifications: localNotifications,
      platform: TargetPlatform.linux,
    );
    await notifications.init(onTokenPersist: persist);
    verifyNever(() => messaging.setBackgroundMessageHandler(any()));
  });
}
