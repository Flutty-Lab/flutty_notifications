import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutty_notifications/flutty_notifications.dart';
import 'package:mocktail/mocktail.dart';

class MockMessagingGateway extends Mock implements MessagingGateway {
  // Broadcast like the real FCM streams: they accept several
  // successive subscriptions (init, registerDevice after re-login…).
  final registrationController = StreamController<String>.broadcast();
  final messageController = StreamController<PushMessage>.broadcast();
  final messageOpenedAppController = StreamController<PushMessage>.broadcast();

  @override
  Stream<String> get onRegistered => registrationController.stream;

  @override
  Stream<PushMessage> get onMessage => messageController.stream;

  @override
  Stream<PushMessage> get onMessageOpenedApp =>
      messageOpenedAppController.stream;
}

class MockLocalNotificationsGateway extends Mock
    implements LocalNotificationsGateway {
  void Function(String? payload)? onTap;
}

class MockBadgeService extends Mock implements BadgeService {}

class MockTokenStore extends Mock implements NotificationTokenStore {
  String? stored;

  @override
  String? get persistedToken => stored;

  @override
  Future<void> save(String token) async => stored = token;

  @override
  Future<void> clear() async => stored = null;
}

void stubMessagingDefaults(MockMessagingGateway messaging) {
  when(messaging.notificationSettings)
      .thenAnswer((_) async => AuthorizationStatus.notDetermined);
  when(messaging.requestPermission)
      .thenAnswer((_) async => AuthorizationStatus.denied);
  // register() triggers the token emission via onRegistered, like FCM.
  when(() => messaging.register()).thenAnswer((_) async {
    messaging.registrationController.add('fcm-token');
  });
  when(messaging.getApnsToken).thenAnswer((_) async => 'apns-token');
  when(messaging.currentToken).thenAnswer((_) async => 'fcm-token');
  when(messaging.getInitialMessage).thenAnswer((_) async => null);
  when(() => messaging.setBackgroundMessageHandler(any())).thenAnswer((_) {});
}
