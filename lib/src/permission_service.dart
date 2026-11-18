import 'package:app_settings/app_settings.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutty_notifications/src/gateways.dart';
import 'package:flutty_notifications/src/models.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Notification permission status and access to system settings.
class NotificationPermissionService {
  NotificationPermissionService({
    MessagingGateway? messaging,
    Future<PermissionStatus> Function()? androidNotificationStatus,
    Future<bool> Function()? androidShouldShowRationale,
    Future<bool> Function()? androidRuntimePermission,
    Future<SharedPreferences> Function()? preferences,
    TargetPlatform? platform,
  }) : _messaging = messaging ?? FirebaseMessagingGateway(),
       _androidNotificationStatus =
           androidNotificationStatus ?? (() => Permission.notification.status),
       _androidShouldShowRationale =
           androidShouldShowRationale ??
           (() => Permission.notification.shouldShowRequestRationale),
       _androidRuntimePermission =
           androidRuntimePermission ?? _defaultAndroidRuntimePermission,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _platform = platform ?? defaultTargetPlatform;

  /// `true` on Android 13+ (API 33): the notification permission can
  /// be requested at runtime. Below that, `denied` means notifications
  /// turned off in settings — there is no prompt.
  static Future<bool> _defaultAndroidRuntimePermission() async =>
      (await DeviceInfoPlugin().androidInfo).version.sdkInt >= 33;

  /// Set by [markPermissionRequested] after a first request. On
  /// Android 13+, `denied` without rationale covers two cases — never
  /// asked (prompt still possible) and permanently denied — which this
  /// flag disambiguates.
  static const requestedKey = 'flutty_notifications.permission_requested';

  final MessagingGateway _messaging;
  final Future<PermissionStatus> Function() _androidNotificationStatus;
  final Future<bool> Function() _androidShouldShowRationale;
  final Future<bool> Function() _androidRuntimePermission;
  final Future<SharedPreferences> Function() _preferences;
  final TargetPlatform _platform;

  /// Remembers that the system prompt has been shown once.
  Future<void> markPermissionRequested() async {
    try {
      final prefs = await _preferences();
      await prefs.setBool(requestedKey, true);
    } catch (error) {
      debugPrint('[NotificationPermissionService] $error');
    }
  }

  /// `true` on platforms where push is supported (Android, iOS).
  bool get isSupported =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  /// Current status: [NotificationAccess.granted], `askable` or
  /// `blocked`.
  Future<NotificationAccess> access() async {
    if (!isSupported) return NotificationAccess.blocked;
    if (_platform == TargetPlatform.iOS) {
      return switch (await _messaging.notificationSettings()) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => NotificationAccess.granted,
        AuthorizationStatus.notDetermined => NotificationAccess.askable,
        AuthorizationStatus.denied ||
        AuthorizationStatus.deniedPermanently => NotificationAccess.blocked,
      };
    }
    final status = await _androidNotificationStatus();
    if (status == PermissionStatus.denied) {
      // Android <13: no runtime prompt, `denied` = notifications
      // turned off in settings → blocked, no matter what.
      if (!await _androidRuntimePermission()) {
        return NotificationAccess.blocked;
      }
      // 13+: the rationale is true only if a new prompt is possible
      // (non-permanent denial).
      if (await _androidShouldShowRationale()) {
        return NotificationAccess.askable;
      }
      // Without rationale: "never asked" (prompt still possible) or
      // "permanently denied" (settings). Only the last-request flag
      // tells them apart.
      final prefs = await _preferences();
      return (prefs.getBool(requestedKey) ?? false)
          ? NotificationAccess.blocked
          : NotificationAccess.askable;
    }
    return _accessFrom(status);
  }

  /// Opens the app's notification settings.
  Future<void> openNotificationSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.notification);

  NotificationAccess _accessFrom(PermissionStatus status) => switch (status) {
    PermissionStatus.granted ||
    PermissionStatus.limited ||
    PermissionStatus.provisional => NotificationAccess.granted,
    PermissionStatus.denied ||
    PermissionStatus.permanentlyDenied ||
    PermissionStatus.restricted => NotificationAccess.blocked,
  };
}
