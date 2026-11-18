import 'package:app_settings/app_settings.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutty_notifications/src/gateways.dart';
import 'package:flutty_notifications/src/models.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Statut de la permission notifications et accès aux réglages système.
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

  /// `true` sur Android 13+ (API 33) : la permission notifications est
  /// demandable à l'exécution. En dessous, `denied` signifie notifications
  /// coupées dans les réglages — il n'existe aucun prompt.
  static Future<bool> _defaultAndroidRuntimePermission() async =>
      (await DeviceInfoPlugin().androidInfo).version.sdkInt >= 33;

  /// Posé par [markPermissionRequested] après une première demande. Sur
  /// Android 13+, `denied` sans rationale couvre deux cas — jamais
  /// demandé (prompt encore possible) et refus définitif — que ce flag
  /// départage.
  static const requestedKey = 'flutty_notifications.permission_requested';

  final MessagingGateway _messaging;
  final Future<PermissionStatus> Function() _androidNotificationStatus;
  final Future<bool> Function() _androidShouldShowRationale;
  final Future<bool> Function() _androidRuntimePermission;
  final Future<SharedPreferences> Function() _preferences;
  final TargetPlatform _platform;

  /// Mémorise que la demande système a été affichée une fois.
  Future<void> markPermissionRequested() async {
    try {
      final prefs = await _preferences();
      await prefs.setBool(requestedKey, true);
    } catch (error) {
      debugPrint('[NotificationPermissionService] $error');
    }
  }

  /// `true` sur les plateformes où les push sont supportées (Android, iOS).
  bool get isSupported =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  /// Statut courant : [NotificationAccess.granted], `askable` ou `blocked`.
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
      // Android <13 : aucun prompt runtime, `denied` = notifications
      // coupées dans les réglages → blocked, quoi qu'il arrive.
      if (!await _androidRuntimePermission()) {
        return NotificationAccess.blocked;
      }
      // 13+ : la rationale est vraie seulement si un nouveau prompt est
      // possible (refus non définitif).
      if (await _androidShouldShowRationale()) {
        return NotificationAccess.askable;
      }
      // Sans rationale : « jamais demandé » (prompt encore possible) ou
      // « refus définitif » (réglages). Seul le flag de la dernière
      // demande les distingue.
      final prefs = await _preferences();
      return (prefs.getBool(requestedKey) ?? false)
          ? NotificationAccess.blocked
          : NotificationAccess.askable;
    }
    return _accessFrom(status);
  }

  /// Ouvre les réglages système des notifications de l'app.
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
