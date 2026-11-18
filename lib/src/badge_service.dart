import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Badge de l'icône de l'app : compte les push reçus depuis la dernière
/// ouverture, remis à zéro au retour au premier plan.
///
/// Le compteur est persisté dans `SharedPreferences` car les push reçus
/// app fermée sont traités dans un isolate séparé, sans état partagé avec
/// l'app.
class BadgeService {
  BadgeService(this._prefs, {Future<void> Function(int)? badgeUpdater})
    : _badgeUpdater = badgeUpdater ?? AppBadgePlus.updateBadge;

  static const countKey = 'flutty_notifications.badge_count';

  final SharedPreferences _prefs;
  final Future<void> Function(int) _badgeUpdater;

  Future<void> increment() async {
    // L'isolate background écrit dans les mêmes préférences : sans
    // reload, le cache de l'isolate courant masque ses incréments
    // (et réciproquement).
    await _prefs.reload();
    await set((_prefs.getInt(countKey) ?? 0) + 1);
  }

  Future<void> set(int count) async {
    await _prefs.setInt(countKey, count);
    await _updateBadge(count);
  }

  Future<void> reset() => set(0);

  /// Best effort : certains launchers Android ne supportent pas le badge,
  /// et un échec d'affichage ne doit jamais remonter plus haut.
  Future<void> _updateBadge(int count) async {
    try {
      await _badgeUpdater(count);
    } catch (e) {
      debugPrint('[BadgeService] updateBadge failed: $e');
    }
  }
}
