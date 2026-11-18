import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutty_notifications/src/models.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Abstraction de `FirebaseMessaging`, pour tester sans Firebase.
abstract class MessagingGateway {
  /// Demande la permission système et renvoie son statut.
  Future<AuthorizationStatus> requestPermission();

  /// Statut courant de la permission notifications (iOS/macOS).
  Future<AuthorizationStatus> notificationSettings();

  /// Token APNs iOS — peut mettre du temps à arriver après l'install.
  Future<String?> getApnsToken();

  /// Enregistre l'instance auprès de FCM (nécessite la permission). Le
  /// jeton d'envoi (FID) est ensuite émis par [onRegistered].
  Future<void> register();

  /// Émis après [register] et à chaque renouvellement : le jeton
  /// d'envoi direct (FID) à transmettre au backend.
  Stream<String> get onRegistered;

  /// Lit le jeton courant (après [register]) — `onRegistered` n'émet
  /// rien tant que le jeton ne change pas.
  Future<String?> currentToken();

  /// Messages reçus app au premier plan.
  Stream<PushMessage> get onMessage;

  /// Tap sur une notification alors que l'app était en arrière-plan.
  Stream<PushMessage> get onMessageOpenedApp;

  /// Notification à l'origine du lancement de l'app (état terminé).
  Future<PushMessage?> getInitialMessage();

  /// Enregistre le handler exécuté dans l'isolate background.
  void setBackgroundMessageHandler(BackgroundMessageHandler handler);
}

/// Implémentation réelle adossée à `firebase_messaging`.
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
  // Pas d'alternative publique pour lire le jeton courant : register()
  // ne ré-émet pas via onRegistered si le jeton est inchangé.
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

/// Abstraction de `FlutterLocalNotificationsPlugin`, pour l'affichage des
/// notifications reçues app ouverte.
abstract class LocalNotificationsGateway {
  /// Initialise le plugin ; [onTap] reçoit le payload de la notification.
  Future<void> initialize({required void Function(String? payload) onTap});

  /// Affiche une notification locale.
  Future<void> show({
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    String? channelDescription,
    String? payload,
  });
}

/// Implémentation réelle adossée à `flutter_local_notifications`.
class FlutterLocalNotificationsGateway implements LocalNotificationsGateway {
  FlutterLocalNotificationsGateway({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  // Seedé par le temps : un compteur repartant de 0 écraserait les
  // notifications encore présentes dans le tray d'une session
  // précédente (même id).
  int _nextId = DateTime.now().millisecondsSinceEpoch ~/ 1000 % 0x7fffffff;
  bool _launchTapDispatched = false;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {
    await _plugin.initialize(
      // iOS : pas de demande de permission ici — elle resterait affichée
      // avant la demande contextuelle de l'app (requestPermission).
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
    // Tap sur une notification locale ayant lancé l'app (état terminé) :
    // il n'arrive ni par onDidReceiveNotificationResponse ni par FCM.
    // Le plugin ne consomme pas le détail : une seule distribution, sinon
    // chaque ré-init rejouerait le tap.
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
