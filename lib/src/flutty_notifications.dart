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

/// Persists an FCM token to the app's backend. Returns `true` when the
/// send succeeded; otherwise the package retries on the next `init`.
typedef TokenPersistCallback = Future<bool> Function(String token);

/// Unlinks a token from the current account (sign-out, account deletion).
typedef TokenRemoveCallback = Future<void> Function(String token);

/// Called when the user taps a notification (deep link:
/// read `message.route`).
typedef NotificationTapCallback = void Function(PushMessage message);

/// Called when a push arrives while the app is in the foreground.
typedef ForegroundMessageCallback = void Function(PushMessage message);

/// Reports an internal package error (logging, Crashlytics…).
/// Notifications must never crash the app.
typedef NotificationErrorCallback = void Function(
  Object error,
  StackTrace stackTrace,
);

/// FCM/APNs push notification reception: permission, device token
/// lifecycle, foreground display, tap routing and badge.
///
/// Usage:
/// ```dart
/// final notifications = FluttyNotifications();
/// await notifications.init(
///   onTokenPersist: (token) => myBackend.registerDevice(token),
///   onNotificationTap: (message) => router.pushPath(message.route ?? '/'),
/// );
/// // Later, when context justifies it:
/// await notifications.requestPermission();
/// ```
///
/// Permission is **not** requested during init: the app picks the right
/// moment via [requestPermission] (or lets registration happen
/// automatically when it is already granted).
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

  /// Push is only supported on native mobile.
  bool get isSupported =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  /// Configures reception: background handler, badge, foreground
  /// display and tap routing. Does **not** show the permission
  /// request.
  ///
  /// Re-entrant: a second call replaces the previous subscriptions.
  ///
  /// [registerBackgroundHandler]: FCM only accepts a single background
  /// handler. An app that needs its own (sync, analytics…) passes
  /// `false` and calls `fluttyNotificationsBackgroundHandler` from its
  /// own handler to keep the badge up to date.
  ///
  /// Each step is isolated: a failure (badge, local notifications,
  /// registration) is reported via `onError` without stopping the rest.
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

      // Wired before the reset: a reset failure must not deprive
      // the app of the reset on resume.
      _appLifecycleListener = AppLifecycleListener(
        onResume: () {
          final reset = _badgeService?.reset();
          if (reset != null) _guarded(reset);
        },
      );

      // Accumulated pushes are seen when the app comes back to the foreground.
      await _badgeService!.reset();
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }

    if (_foregroundNotifications) {
      try {
        await _localNotifications.initialize(
          onTap: (payload) => _dispatchTap(_localMessageFromPayload(payload)),
        );
        // iOS: no setForegroundNotificationPresentationOptions —
        // native display would duplicate the local notification,
        // and the option would persist if we re-init without foreground.
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

    // Permission may already be granted (reinstall, permission granted
    // outside the app): register the token without asking.
    // A failure reading the status must not break the rest.
    try {
      if (await _permissionService.access() == NotificationAccess.granted) {
        _subscribeRegistration();
        unawaited(_registerInstance());
      }
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }

    // Tap that launched the app from the terminated state.
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

  /// Requests the system permission. Call it at a meaningful moment
  /// (never at first launch without context). On grant, registers the
  /// token with the backend.
  Future<NotificationAccess> requestPermission() async {
    if (!isSupported) return NotificationAccess.blocked;
    try {
      final status = await _messaging.requestPermission();
      // Remember the request: without it, Android can no longer tell
      // "never asked" apart from "permanently denied".
      await _permissionService.markPermissionRequested();
      // Android: `denied` also covers "notifications turned off in
      // settings" (<13 or permanent denial) — the permission service
      // disambiguates via shouldShowRequestRationale and the request flag.
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

  /// Current notification permission status.
  Future<NotificationAccess> access() => _permissionService.access();

  /// Opens the system notification settings (when [access] returns
  /// [NotificationAccess.blocked]).
  Future<void> openNotificationSettings() =>
      _permissionService.openNotificationSettings();

  /// Re-registers the device token with the backend — call it after a
  /// login if the app does not run [init] again. No-op when permission
  /// is not granted.
  Future<void> registerDevice() async {
    if (!isSupported) return;
    try {
      if (await _permissionService.access() == NotificationAccess.granted) {
        _subscribeRegistration();
        await _registerInstance();
        // Direct read: `onRegistered` emits nothing when the token is
        // unchanged — only the "not yet registered" case produces
        // an event.
        final token = await _messaging.currentToken();
        if (token != null) await _persistToken(token);
      }
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  /// Unlinks the current token from the account (call before the
  /// session teardown). A failure is ignored: sign-out must never be
  /// blocked by it. After a new login, call [registerDevice] (or run
  /// [init] again): `onRegistered` emits nothing while the token
  /// does not change.
  Future<void> unregisterDevice() async {
    final token = _tokenStore?.persistedToken;
    if (token == null) return;
    try {
      await _onTokenRemove?.call(token);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
    // The stored token is forgotten even if the call failed: otherwise
    // a re-login on the same device would never re-register it.
    await _tokenStore?.clear();
  }

  /// Forgets the stored token without a network call (session already
  /// invalid): the next `init` re-registers the device.
  Future<void> forgetDevice() => _tokenStore?.clear() ?? Future.value();

  void _subscribeRegistration() {
    unawaited(_registrationSubscription?.cancel());
    _registrationSubscription = _messaging.onRegistered.listen(_persistToken);
  }

  Future<void> _registerInstance() async {
    try {
      // iOS: wait for the APNs token, otherwise register() may fail.
      if (_platform == TargetPlatform.iOS && !await _waitForApnsToken()) {
        _report(StateError('APNs token never received'), StackTrace.current);
        return;
      }
      // The send token arrives via onRegistered → _persistToken.
      await _messaging.register();
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  /// Sends the token to the backend if it differs from the last
  /// successfully sent one. An in-flight send for that token is shared:
  /// `register` may emit the token via `onRegistered` while
  /// `registerDevice` is already reading it through
  /// [MessagingGateway.currentToken] — without dedup, the backend would
  /// get two requests before the store is saved.
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
          // The payload carries the full message: on tap, the
          // callback receives the same data as a native tap
          // (onMessageOpenedApp), not just the route.
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

  /// Reports errors from a detached task instead of letting them
  /// reach the app's global error handler.
  void _guarded(Future<void> future) {
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        _report(error, stackTrace);
      }),
    );
  }

  void _dispatchTap(PushMessage message) => _onNotificationTap?.call(message);

  /// Decodes a local notification payload: the message serialized in
  /// [_onForegroundPush]. Free text (older version, notification not
  /// issued by the package) is still read as a route.
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
        // Non-JSON payload → interpreted as a route below.
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

  /// Cancels the current subscriptions (called by [init]).
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
