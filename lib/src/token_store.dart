import 'package:shared_preferences/shared_preferences.dart';

/// Persists the last FCM token successfully sent to the backend.
///
/// The token is only stored after a successful send: a failed send is
/// retried on the next `init`, and an unchanged token is not resent.
abstract class NotificationTokenStore {
  /// Last persisted token, or `null` if no send has succeeded yet.
  String? get persistedToken;

  /// Stores [token] as the last successfully sent token.
  Future<void> save(String token);

  /// Forgets the stored token (after unregistration or an invalid
  /// session).
  Future<void> clear();
}

/// [NotificationTokenStore] backed by `SharedPreferences`.
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
