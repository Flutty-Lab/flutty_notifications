import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutty_notifications/src/models.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Abstraction of `FirebaseMessaging`, to allow testing without
/// Firebase.
abstract class MessagingGateway {
  /// Requests the system permission and returns its status.
  Future<AuthorizationStatus> requestPermission();

  /// Current notification permission status (iOS/macOS).
  Future<AuthorizationStatus> notificationSettings();

  /// iOS APNs token — can take a while to arrive after install.
  Future<String?> getApnsToken();

  /// Registers the instance with FCM (requires permission). The send
  /// token (FID) is then emitted by [onRegistered].
  Future<void> register();

  /// Emitted after [register] and on each renewal: the direct send
  /// token (FID) to forward to the backend.
  Stream<String> get onRegistered;

  /// Reads the current token (after [register]) — `onRegistered` emits
  /// nothing while the token does not change.
  Future<String?> currentToken();

  /// Messages received while the app is in the foreground.
  Stream<PushMessage> get onMessage;

  /// Tap on a notification while the app was in the background.
  Stream<PushMessage> get onMessageOpenedApp;

  /// Notification that launched the app (terminated state).
  Future<PushMessage?> getInitialMessage();

  /// Registers the handler executed in the background isolate.
  void setBackgroundMessageHandler(BackgroundMessageHandler handler);
}

/// Real implementation backed by `firebase_messaging`.
class FirebaseMessagingGateway implements MessagingGateway {
  FirebaseMessagingGateway({FirebaseMessaging? messaging})
    : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  static PushMessage _toPushMessage(RemoteMessage message) => PushMessage(
    title: message.notification?.title,
    body: message.notification?.body,
    data: Map<String, dynamic>.from(message.data),
  );

  @override
  Future<AuthorizationStatus> requestPermission() async =>
      (await _messaging.requestPermission()).authorizationStatus;

  @override
  Future<AuthorizationStatus> notificationSettings() async =>
      (await _messaging.getNotificationSettings()).authorizationStatus;

  @override
  Future<String?> getApnsToken() => _messaging.getAPNSToken();

  @override
  Future<void> register() => _messaging.register();

  @override
  Stream<String> get onRegistered => _messaging.onRegistered;

  @override
  // No public alternative to read the current token: register() does
  // not re-emit via onRegistered when the token is unchanged.
  // ignore: deprecated_member_use
  Future<String?> currentToken() => _messaging.getToken();

  @override
  Stream<PushMessage> get onMessage =>
      FirebaseMessaging.onMessage.map(_toPushMessage);

  @override
  Stream<PushMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map(_toPushMessage);

  @override
  Future<PushMessage?> getInitialMessage() async =>
      _toPushMessageOrNull(await _messaging.getInitialMessage());

  static PushMessage? _toPushMessageOrNull(RemoteMessage? message) =>
      message == null ? null : _toPushMessage(message);

  @override
  void setBackgroundMessageHandler(BackgroundMessageHandler handler) =>
      FirebaseMessaging.onBackgroundMessage(handler);
}

/// Abstraction of `FlutterLocalNotificationsPlugin`, for displaying
/// notifications received while the app is open.
abstract class LocalNotificationsGateway {
  /// Initializes the plugin; [onTap] receives the notification
  /// payload.
  Future<void> initialize({required void Function(String? payload) onTap});

  /// Shows a local notification.
  Future<void> show({
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    String? channelDescription,
    String? payload,
  });
}

/// Real implementation backed by `flutter_local_notifications`.
class FlutterLocalNotificationsGateway implements LocalNotificationsGateway {
  FlutterLocalNotificationsGateway({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  // Seeded by time: a counter restarting from 0 would overwrite the
  // notifications still present in the tray from a previous session
  // (same id).
  int _nextId = DateTime.now().millisecondsSinceEpoch ~/ 1000 % 0x7fffffff;
  bool _launchTapDispatched = false;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {
    await _plugin.initialize(
      // iOS: no permission request here — it would stay on screen
      // before the app's contextual request (requestPermission).
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) => onTap(response.payload),
    );
    // Tap on a local notification that launched the app (terminated
    // state): it arrives neither via onDidReceiveNotificationResponse
    // nor via FCM. The plugin does not consume the detail: dispatch it
    // only once, otherwise every re-init would replay the tap.
    if (!_launchTapDispatched) {
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp ?? false) {
        _launchTapDispatched = true;
        onTap(launchDetails?.notificationResponse?.payload);
      }
    }
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    String? channelDescription,
    String? payload,
  }) {
    return _plugin.show(
      id: _nextId++,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: payload,
    );
  }
}
