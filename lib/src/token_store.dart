import 'package:shared_preferences/shared_preferences.dart';

/// Persiste le dernier token FCM envoyé avec succès au backend.
///
/// Le token n'est mémorisé qu'après un envoi réussi : un envoi en échec est
/// retenté au prochain `init`, et un token inchangé n'est pas renvoyé.
abstract class NotificationTokenStore {
  /// Dernier token persisté, ou `null` si aucun envoi n'a encore réussi.
  String? get persistedToken;

  /// Mémorise [token] comme dernier token envoyé avec succès.
  Future<void> save(String token);

  /// Oublie le token mémorisé (après désenregistrement ou session invalide).
  Future<void> clear();
}

/// [NotificationTokenStore] adossé à `SharedPreferences`.
class SharedPreferencesTokenStore implements NotificationTokenStore {
  SharedPreferencesTokenStore(this._prefs);

  static const _key = 'flutty_notifications.last_token';

  final SharedPreferences _prefs;

  @override
  String? get persistedToken => _prefs.getString(_key);

  @override
  Future<void> save(String token) => _prefs.setString(_key, token);

  @override
  Future<void> clear() => _prefs.remove(_key);
}
