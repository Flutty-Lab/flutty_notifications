/// Access status of the device's notifications.
enum NotificationAccess {
  /// Notifications are allowed.
  granted,

  /// Permission has never been requested: the system prompt can be
  /// shown.
  askable,

  /// Denied (permanently): the user must be redirected to the system
  /// settings.
  blocked,
}

/// Normalized push message, independent of `firebase_messaging`.
class PushMessage {
  const PushMessage({this.title, this.body, required this.data});

  /// Notification title, if the message carries one.
  final String? title;

  /// Notification body, if the message carries one.
  final String? body;

  /// Arbitrary message data (`RemoteMessage.data`).
  final Map<String, dynamic> data;

  /// Deep link target route, the `data['route']` convention.
  String? get route => data['route'] as String?;
}
