import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutty_notifications/src/background_handler.dart';
import 'package:flutty_notifications/src/badge_service.dart';
import 'package:flutty_notifications/src/gateways.dart';
import 'package:flutty_notifications/src/models.dart';
import 'package:flutty_notifications/src/permission_service.dart';
import 'package:flutty_notifications/src/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persiste un token FCM auprès du backend de l'app. Renvoie `true` si
/// l'envoi a réussi ; sinon le package retentera au prochain `init`.
typedef TokenPersistCallback = Future<bool> Function(String token);

/// Dissocie un token du compte courant (déconnexion, suppression de compte).
typedef TokenRemoveCallback = Future<void> Function(String token);

/// Appelé quand l'utilisateur tape sur une notification (deep link :
/// lire `message.route`).
typedef NotificationTapCallback = void Function(PushMessage message);

/// Appelé quand un push arrive app au premier plan.
typedef ForegroundMessageCallback = void Function(PushMessage message);

/// Rapporte une erreur interne du package (logging, Crashlytics…).
/// Les notifications ne doivent jamais faire planter l'app.
typedef NotificationErrorCallback = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Réception des push notifications FCM/APNs : permission, cycle de vie du
/// token d'appareil, affichage au premier plan, routage du tap et badge.
///
/// Usage :
/// ```dart
/// final notifications = FluttyNotifications();
/// await notifications.init(
///   onTokenPersist: (token) => monBackend.registerDevice(token),
///   onNotificationTap: (message) => router.pushPath(message.route ?? '/'),
/// );
/// // Plus tard, quand le contexte le justifie :
/// await notifications.requestPermission();
/// ```
///
/// La permission n'est **pas** demandée à l'init : c'est à l'app de choisir
/// le bon moment via [requestPermission] (ou de laisser l'enregistrement se
/// faire automatiquement si elle est déjà accordée).
class FluttyNotifications {
  FluttyNotifications({
    MessagingGateway? messaging,
    LocalNotificationsGateway? localNotifications,
    NotificationPermissionService? permissionService,
    NotificationTokenStore? tokenStore,
    BadgeService? badgeService,
    Future<SharedPreferences> Function()? preferences,
    TargetPlatform? platform,
    NotificationErrorCallback? onError,
  }) : _messaging = messaging ?? FirebaseMessagingGateway(),
       _localNotifications =
           localNotifications ?? FlutterLocalNotificationsGateway(),
       _preferences = preferences ?? SharedPreferences.getInstance,
       _platform = platform ?? defaultTargetPlatform {
    _tokenStore = tokenStore;
    _badgeService = badgeService;
    _onError = onError;
    _permissionService =
        permissionService ??
        NotificationPermissionService(
          messaging: _messaging,
          preferences: _preferences,
          platform: _platform,
        );
  }

  final MessagingGateway _messaging;
  final LocalNotificationsGateway _localNotifications;
  late final NotificationPermissionService _permissionService;
  final Future<SharedPreferences> Function() _preferences;
  final TargetPlatform _platform;
  NotificationErrorCallback? _onError;

  NotificationTokenStore? _tokenStore;
  BadgeService? _badgeService;

  StreamSubscription<String>? _registrationSubscription;
  StreamSubscription<PushMessage>? _messageSubscription;
  StreamSubscription<PushMessage>? _tapSubscription;
  AppLifecycleListener? _appLifecycleListener;

  TokenPersistCallback? _onTokenPersist;
  TokenRemoveCallback? _onTokenRemove;
  final _tokenPersistInFlight = <String, Future<void>>{};
  NotificationTapCallback? _onNotificationTap;
  ForegroundMessageCallback? _onForegroundMessage;
  bool _foregroundNotifications = true;
  String _channelId = 'default';
  String _channelName = 'Notifications';
  String? _channelDescription;

  /// Les push ne sont supportées que sur mobile natif.
  bool get isSupported =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  /// Configure la réception : handler background, badge, affichage au
  /// premier plan et routage du tap. N'affiche **pas** la demande de
  /// permission.
  ///
  /// Ré-entrant : un second appel remplace les abonnements précédents.
  ///
  /// [registerBackgroundHandler] : FCM n'accepte qu'un seul handler
  /// background. Une app qui a besoin du sien (sync, analytics…) passe
  /// `false` et appelle `fluttyNotificationsBackgroundHandler` depuis
  /// son propre handler pour garder le badge à jour.
  ///
  /// Chaque étape est isolée : un échec (badge, notifications locales,
  /// enregistrement) est rapporté via `onError` sans couper le reste.
  Future<void> init({
    required TokenPersistCallback onTokenPersist,
    TokenRemoveCallback? onTokenRemove,
    NotificationTapCallback? onNotificationTap,
    ForegroundMessageCallback? onForegroundMessage,
    bool foregroundNotifications = true,
    bool registerBackgroundHandler = true,
    String androidChannelId = 'default',
    String androidChannelName = 'Notifications',
    String? androidChannelDescription,
  }) async {
    if (!isSupported) return;
    dispose();

    _onTokenPersist = onTokenPersist;
    _onTokenRemove = onTokenRemove;
    _onNotificationTap = onNotificationTap;
    _onForegroundMessage = onForegroundMessage;
    _foregroundNotifications = foregroundNotifications;
    _channelId = androidChannelId;
    _channelName = androidChannelName;
    _channelDescription = androidChannelDescription;

    if (registerBackgroundHandler) {
      try {
        _messaging.setBackgroundMessageHandler(
          fluttyNotificationsBackgroundHandler,
        );
      } catch (error, stackTrace) {
        _report(error, stackTrace);
      }
    }

    try {
      final prefs = await _preferences();
      _tokenStore ??= SharedPreferencesTokenStore(prefs);
      _badgeService ??= BadgeService(prefs);

      // Branché avant le reset : un échec du reset ne doit pas priver
      // l'app du reset au resume.
      _appLifecycleListener = AppLifecycleListener(
        onResume: () {
          final reset = _badgeService?.reset();
          if (reset != null) _guarded(reset);
        },
      );

      // Les push accumulés sont vus quand l'app revient au premier plan.
      await _badgeService!.reset();
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }

    if (_foregroundNotifications) {
      try {
        await _localNotifications.initialize(
          onTap: (payload) => _dispatchTap(_localMessageFromPayload(payload)),
        );
        // iOS : pas de setForegroundNotificationPresentationOptions —
        // l'affichage natif doublonnerait avec la notification locale,
        // et l'option persisterait si on ré-init sans foreground.
      } catch (error, stackTrace) {
        _report(error, stackTrace);
      }
    }

    try {
      _messageSubscription = _messaging.onMessage.listen(_onForegroundPush);
      _tapSubscription = _messaging.onMessageOpenedApp.listen(_dispatchTap);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }

    // La permission est peut-être déjà accordée (ré-installation,
    // permission donnée hors app) : enregistrer le token sans demander.
    // Un échec de lecture du statut ne doit pas casser le reste.
    try {
      if (await _permissionService.access() == NotificationAccess.granted) {
        _subscribeRegistration();
        unawaited(_registerInstance());
      }
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }

    // Tap ayant lancé l'app depuis l'état terminé.
    unawaited(
      _messaging
          .getInitialMessage()
          .then((message) {
            if (message != null) _dispatchTap(message);
          })
          .catchError((Object error, StackTrace stackTrace) {
            _report(error, stackTrace);
            return null;
          }),
    );
  }

  /// Demande la permission système. À appeler au moment utile (jamais au
  /// premier lancement sans contexte). En cas d'accord, enregistre le
  /// token auprès du backend.
  Future<NotificationAccess> requestPermission() async {
    if (!isSupported) return NotificationAccess.blocked;
    try {
      final status = await _messaging.requestPermission();
      // Mémorise la demande : Android ne distingue plus « jamais
      // demandé » de « refus définitif » sans elle.
      await _permissionService.markPermissionRequested();
      // Android : `denied` couvre aussi le cas « notifications coupées dans
      // les réglages » (<13 ou refus définitif) — le service de permission
      // départage via shouldShowRequestRationale et le flag de demande.
      final access = _platform == TargetPlatform.android
          ? await _permissionService.access()
          : switch (status) {
              AuthorizationStatus.authorized ||
              AuthorizationStatus.provisional => NotificationAccess.granted,
              AuthorizationStatus.notDetermined => NotificationAccess.askable,
              AuthorizationStatus.denied ||
              AuthorizationStatus.deniedPermanently =>
                NotificationAccess.blocked,
            };
      if (access == NotificationAccess.granted) {
        _subscribeRegistration();
        unawaited(_registerInstance());
      }
      return access;
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return NotificationAccess.blocked;
    }
  }

  /// Statut courant de la permission notifications.
  Future<NotificationAccess> access() => _permissionService.access();

  /// Ouvre les réglages système des notifications (si [access] renvoie
  /// [NotificationAccess.blocked]).
  Future<void> openNotificationSettings() =>
      _permissionService.openNotificationSettings();

  /// Ré-enregistre le token de l'appareil auprès du backend — à appeler
  /// après un login si l'app ne relance pas [init]. Sans effet si la
  /// permission n'est pas accordée.
  Future<void> registerDevice() async {
    if (!isSupported) return;
    try {
      if (await _permissionService.access() == NotificationAccess.granted) {
        _subscribeRegistration();
        await _registerInstance();
        // Lecture directe : `onRegistered` ne ré-émet rien si le jeton
        // est inchangé — seul le cas « pas encore enregistré » produit
        // un événement.
        final token = await _messaging.currentToken();
        if (token != null) await _persistToken(token);
      }
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  /// Dissocie le token courant du compte (à appeler avant la purge de la
  /// session). Un échec est ignoré : la déconnexion ne doit jamais en être
  /// bloquée. Après un nouveau login, appeler [registerDevice] (ou
  /// relancer [init]) : `onRegistered` n'émet rien tant que le token
  /// ne change pas.
  Future<void> unregisterDevice() async {
    final token = _tokenStore?.persistedToken;
    if (token == null) return;
    try {
      await _onTokenRemove?.call(token);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
    // Le token mémorisé est oublié même si l'appel a échoué : sinon un
    // re-login sur le même appareil ne ré-enregistrerait jamais le device.
    await _tokenStore?.clear();
  }

  /// Oublie le token mémorisé sans appel réseau (session déjà invalide) :
  /// le prochain `init` ré-enregistrera le device.
  Future<void> forgetDevice() => _tokenStore?.clear() ?? Future.value();

  void _subscribeRegistration() {
    unawaited(_registrationSubscription?.cancel());
    _registrationSubscription = _messaging.onRegistered.listen(_persistToken);
  }

  Future<void> _registerInstance() async {
    try {
      // iOS : attend le token APNs, sinon register() peut échouer.
      if (_platform == TargetPlatform.iOS && !await _waitForApnsToken()) {
        _report(StateError('APNs token never received'), StackTrace.current);
        return;
      }
      // Le jeton d'envoi arrive via onRegistered → _persistToken.
      await _messaging.register();
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  /// Envoie le token au backend s'il diffère du dernier envoyé avec succès.
  /// Un envoi en cours pour ce jeton est partagé : `register` peut émettre
  /// le jeton via `onRegistered` pendant que `registerDevice` le lit déjà
  /// via [MessagingGateway.currentToken] — sans dédup, le backend reçoit
  /// deux requêtes avant que le store ne soit sauvegardé.
  Future<void> _persistToken(String token) {
    final inFlight = _tokenPersistInFlight[token];
    if (inFlight != null) return inFlight;
    if (_tokenStore?.persistedToken == token) return Future<void>.value();
    final persist = () async {
      try {
        final persisted = await _onTokenPersist?.call(token) ?? false;
        if (persisted) await _tokenStore?.save(token);
      } catch (error, stackTrace) {
        _report(error, stackTrace);
      }
    }();
    _tokenPersistInFlight[token] = persist;
    return persist.whenComplete(() => _tokenPersistInFlight.remove(token));
  }

  void _onForegroundPush(PushMessage message) {
    if (_foregroundNotifications &&
        (message.title != null || message.body != null)) {
      _guarded(
        _localNotifications.show(
          title: message.title ?? '',
          body: message.body ?? '',
          channelId: _channelId,
          channelName: _channelName,
          channelDescription: _channelDescription,
          // Le payload transporte le message complet : au tap, le
          // callback reçoit les mêmes données que pour un tap natif
          // (onMessageOpenedApp), pas seulement la route.
          payload: jsonEncode({
            'title': message.title,
            'body': message.body,
            'data': message.data,
          }),
        ),
      );
    }
    final badgeReset = _badgeService?.reset();
    if (badgeReset != null) _guarded(badgeReset);
    _onForegroundMessage?.call(message);
  }

  /// Rapporte les erreurs d'un traitement détaché au lieu de les laisser
  /// remonter au handler d'erreurs globales de l'app.
  void _guarded(Future<void> future) {
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        _report(error, stackTrace);
      }),
    );
  }

  void _dispatchTap(PushMessage message) => _onNotificationTap?.call(message);

  /// Décode le payload d'une notification locale : le message sérialisé
  /// dans [_onForegroundPush]. Un texte libre (ancienne version, notif
  /// non émise par le package) reste lu comme une route.
  PushMessage _localMessageFromPayload(String? payload) {
    if (payload != null) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map) {
          return PushMessage(
            title: decoded['title'] as String?,
            body: decoded['body'] as String?,
            data: Map<String, dynamic>.from(
              decoded['data'] as Map? ?? const {},
            ),
          );
        }
      } on FormatException {
        // Payload non-JSON → interprété comme une route ci-dessous.
      }
    }
    return PushMessage(data: {'route': payload});
  }

  Future<bool> _waitForApnsToken() async {
    for (var attempt = 0; attempt < 30; attempt++) {
      if (await _messaging.getApnsToken() != null) return true;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  void _report(Object error, StackTrace stackTrace) {
    final onError = _onError;
    if (onError != null) {
      onError(error, stackTrace);
    } else {
      debugPrint('[FluttyNotifications] $error\n$stackTrace');
    }
  }

  /// Annule les abonnements en cours (appelé par [init]).
  void dispose() {
    unawaited(_registrationSubscription?.cancel());
    unawaited(_messageSubscription?.cancel());
    unawaited(_tapSubscription?.cancel());
    _appLifecycleListener?.dispose();
    _registrationSubscription = null;
    _messageSubscription = null;
    _tapSubscription = null;
    _appLifecycleListener = null;
  }
}
