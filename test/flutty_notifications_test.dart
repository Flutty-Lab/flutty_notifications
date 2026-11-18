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
    test('enregistre le handler background et remet le badge à zéro', () async {
      await notifications.init(onTokenPersist: persist);
      verify(() => messaging.setBackgroundMessageHandler(any())).called(1);
      verify(badge.reset).called(1);
    });

    test('ne demande pas la permission', () async {
      await notifications.init(onTokenPersist: persist);
      verifyNever(messaging.requestPermission);
    });

    test(
      'registerBackgroundHandler: false → aucun handler enregistré',
      () async {
        await notifications.init(
          onTokenPersist: persist,
          registerBackgroundHandler: false,
        );
        verifyNever(() => messaging.setBackgroundMessageHandler(any()));
      },
    );

    test('un échec des notifications locales ne coupe pas '
        'l\'enregistrement FCM', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      when(() => localNotifications.initialize(onTap: any(named: 'onTap')))
          .thenThrow(Exception('plugin cassé'));
      await notifications.init(onTokenPersist: persist);
      await flush();
      expect(persistedTokens, ['fcm-token']);
    });

    test(
      'enregistre le token sans demande si la permission est déjà accordée',
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
      'n\'enregistre pas le token si la permission n\'est pas accordée',
      () async {
        await notifications.init(onTokenPersist: persist);
        await flush();
        expect(persistedTokens, isEmpty);
        verifyNever(() => messaging.register());
      },
    );

    test('ne re-persiste pas un token déjà envoyé', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      tokenStore.stored = 'fcm-token';
      await notifications.init(onTokenPersist: persist);
      await flush();
      expect(persistedTokens, isEmpty);
    });

    test('un envoi en échec n\'est pas mémorisé et sera retenté', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      await notifications.init(onTokenPersist: (_) async => false);
      await flush();
      expect(tokenStore.persistedToken, isNull);
    });

    test('un changement de token FCM est persisté', () async {
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
    test('accord → enregistre le token', () async {
      when(messaging.requestPermission)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      await notifications.init(onTokenPersist: persist);
      final access = await notifications.requestPermission();
      await flush();
      expect(access, NotificationAccess.granted);
      expect(persistedTokens, ['fcm-token']);
    });

    test('refus → aucun enregistrement', () async {
      await notifications.init(onTokenPersist: persist);
      final access = await notifications.requestPermission();
      await flush();
      expect(access, NotificationAccess.blocked);
      expect(persistedTokens, isEmpty);
    });
  });

  group('messages', () {
    test('message au premier plan → notification locale, badge remis à zéro '
        'et callback', () async {
      final received = <PushMessage>[];
      await notifications.init(
        onTokenPersist: persist,
        onForegroundMessage: received.add,
      );
      messaging.messageController.add(
        const PushMessage(
          title: 'Titre',
          body: 'Corps',
          data: {'route': '/dashboard', 'conversation_id': '42'},
        ),
      );
      await flush();
      // Le payload transporte le message complet, pas seulement la route.
      final captured = verify(
        () => localNotifications.show(
          title: 'Titre',
          body: 'Corps',
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

    test('tap depuis l\'arrière-plan → callback avec la route', () async {
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
      'tap sur notification locale → callback avec le message complet',
      () async {
        PushMessage? tapped;
        await notifications.init(
          onTokenPersist: persist,
          onNotificationTap: (m) => tapped = m,
        );
        localNotifications.onTap?.call(
          jsonEncode({
            'title': 'Titre',
            'body': 'Corps',
            'data': {'route': '/child', 'conversation_id': '42'},
          }),
        );
        await flush();
        expect(tapped?.title, 'Titre');
        expect(tapped?.body, 'Corps');
        expect(tapped?.route, '/child');
        expect(tapped?.data['conversation_id'], '42');
      },
    );

    test('payload local texte libre → lu comme une route', () async {
      PushMessage? tapped;
      await notifications.init(
        onTokenPersist: persist,
        onNotificationTap: (m) => tapped = m,
      );
      localNotifications.onTap?.call('/child');
      await flush();
      expect(tapped?.route, '/child');
    });

    test('app lancée par une notification → callback', () async {
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
    test('ré-enregistre le token après unregisterDevice (re-login)', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      await notifications.init(onTokenPersist: persist);
      await flush();
      await notifications.unregisterDevice();
      persistedTokens.clear();
      await notifications.registerDevice();
      await flush();
      // Le jeton revient via currentToken(), pas via une ré-émission.
      expect(persistedTokens, contains('fcm-token'));
      expect(tokenStore.persistedToken, 'fcm-token');
    });

    test('sans permission → aucun enregistrement', () async {
      await notifications.init(onTokenPersist: persist);
      await notifications.registerDevice();
      await flush();
      expect(persistedTokens, isEmpty);
      verifyNever(() => messaging.register());
    });

    test('ne duplique pas l\'envoi quand register() émet le jeton '
        'pendant la lecture directe', () async {
      when(messaging.notificationSettings)
          .thenAnswer((_) async => AuthorizationStatus.authorized);
      // Envoi lent : la fenêtre de course entre l'émission du stream et
      // la lecture directe doit produire une seule requête.
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
      // register() émet 'fcm-token' via onRegistered pendant que
      // registerDevice le lit via currentToken() : un seul envoi.
      await notifications.registerDevice();
      await flush();
      expect(persistedTokens, ['fcm-token']);
    });
  });

  group('unregisterDevice', () {
    test('appelle le callback de retrait et oublie le token', () async {
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

    test('oublie le token même si le retrait échoue', () async {
      tokenStore.stored = 'fcm-token';
      await notifications.init(
        onTokenPersist: persist,
        onTokenRemove: (_) async => throw Exception('réseau'),
      );
      await notifications.unregisterDevice();
      expect(tokenStore.persistedToken, isNull);
    });
  });

  test('plateforme non supportée → init ne fait rien', () async {
    notifications = FluttyNotifications(
      messaging: messaging,
      localNotifications: localNotifications,
      platform: TargetPlatform.linux,
    );
    await notifications.init(onTokenPersist: persist);
    verifyNever(() => messaging.setBackgroundMessageHandler(any()));
  });
}
