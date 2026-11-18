import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutty_notifications/src/badge_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handler FCM exécuté dans l'isolate dédié quand un push arrive app
/// fermée ou en arrière-plan.
///
/// Incrémente le badge de l'icône — sauf si le serveur fournit déjà un
/// compteur `badge_count` dans le payload. GetIt n'existe pas dans cet
/// isolate : on recrée un accès minimal aux préférences.
///
/// Enregistré automatiquement par `FluttyNotifications.init`, sauf si
/// `registerBackgroundHandler: false` : dans ce cas l'app doit appeler
/// ce handler depuis son propre handler background.
///
/// Note iOS : ne tourne pas pour un push « notification » classique
/// (sans `content-available: 1`) — le compteur iOS doit venir du
/// payload serveur (`aps.badge` / `badge_count`).
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
