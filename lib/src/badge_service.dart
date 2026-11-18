import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App icon badge: counts pushes received since the last open, reset to
/// zero when the app returns to the foreground.
///
/// The counter is persisted in `SharedPreferences` because pushes
/// received while the app is closed are handled in a separate isolate,
/// with no state shared with the app.
class BadgeService {
  BadgeService(this._prefs, {Future<void> Function(int)? badgeUpdater})
    : _badgeUpdater = badgeUpdater ?? AppBadgePlus.updateBadge;

  static const countKey = 'flutty_notifications.badge_count';

  final SharedPreferences _prefs;
  final Future<void> Function(int) _badgeUpdater;

  Future<void> increment() async {
    // The background isolate writes to the same preferences: without a
    // reload, the current isolate's cache would hide its increments
    // (and vice versa).
    await _prefs.reload();
    await set((_prefs.getInt(countKey) ?? 0) + 1);
  }

  Future<void> set(int count) async {
    await _prefs.setInt(countKey, count);
    await _updateBadge(count);
  }

  Future<void> reset() => set(0);

  /// Best effort: some Android launchers do not support badges, and a
  /// display failure must never propagate.
  Future<void> _updateBadge(int count) async {
    try {
      await _badgeUpdater(count);
    } catch (e) {
      debugPrint('[BadgeService] updateBadge failed: $e');
    }
  }
}
