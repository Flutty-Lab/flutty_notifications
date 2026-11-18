import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutty_notifications/src/badge_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FCM handler executed in the dedicated isolate when a push arrives
/// while the app is closed or in the background.
///
/// Increments the icon badge — unless the server already provides a
/// `badge_count` in the payload. GetIt does not exist in this isolate:
/// we rebuild a minimal access to the preferences.
///
/// Registered automatically by `FluttyNotifications.init`, unless
/// `registerBackgroundHandler: false` is passed — in that case the app
/// must call this handler from its own background handler.
///
/// iOS note: does not run for a regular "notification" push (without
/// `content-available: 1`) — the iOS counter must come from the server
/// payload (`aps.badge` / `badge_count`).
@pragma('vm:entry-point')
Future<void> fluttyNotificationsBackgroundHandler(RemoteMessage message) async {
  final prefs = await SharedPreferences.getInstance();
  final badge = BadgeService(prefs);
  final serverCount = int.tryParse('${message.data['badge_count'] ?? ''}');
  if (serverCount != null) {
    await badge.set(serverCount);
  } else {
    await badge.increment();
  }
}
