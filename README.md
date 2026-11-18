# flutty_notifications

Push notifications (FCM + APNs) for Flutter apps: contextual permission, device token lifecycle, foreground display, tap routing and icon badge.

## Usage

```dart
final notifications = FluttyNotifications();

// At startup: configures reception WITHOUT asking for permission.
await notifications.init(
  onTokenPersist: (token) => myBackend.registerDevice(token),
  onNotificationTap: (message) => router.pushPath(message.route ?? '/'),
  onForegroundMessage: (message) => refreshCaches(),
);

// Later, when context justifies it (first share, first child…) —
// never at first launch without explanation:
final access = await notifications.requestPermission();

// Permanently denied → redirect to system settings:
if (access == NotificationAccess.blocked) {
  await notifications.openNotificationSettings();
}

// On sign-out: unlink the device from the account.
await notifications.unregisterDevice();

// After a new login without re-init: re-register the device.
await notifications.registerDevice();
```

- `onTokenPersist(token)` must return `true` when registration succeeded — a failure is retried on the next `init`, and an unchanged token is never resent.
- `message.route` carries the deep link target route (the `data['route']` convention in the FCM payload). A tap on a foreground notification delivers the full `PushMessage` (title, body, `data`), like a native tap.
- The icon badge is incremented automatically for each push received while the app is closed (background handler registered by `init`), and reset to zero on app open **and on resume**. A `badge_count` in the server payload forces the exact value.
- FCM only accepts **one background handler**: if the app needs its own, pass `registerBackgroundHandler: false` to `init` and call `fluttyNotificationsBackgroundHandler` from your own handler to keep the badge up to date.

## Android setup

- `AndroidManifest.xml`: add the `POST_NOTIFICATIONS` permission (Android 13+).
- Notification icon: the package uses `@mipmap/ic_launcher` for foreground notifications — provide a dedicated icon if needed (see `flutter_local_notifications`).
- The default channel can be configured via `androidChannelId` / `androidChannelName` / `androidChannelDescription` in `init`.
- **Auto Backup**: the `flutty_notifications.permission_requested` flag lives in `FlutterSharedPreferences.xml`, which Android backs up by default. After a restore (reinstall, new device), `access()` may report `blocked` even though the prompt can still be shown. If your app declares `fullBackupContent`/`dataExtractionRules`, it can exclude that file — note that this excludes *all* of its SharedPreferences. Related case: permission revoked from system settings → `access()` stays `blocked` until the next `requestPermission()` (accepted behavior — without the flag, a first-time prompt cannot be told apart from a permanent denial).

## iOS setup

- APNs key configured in the Firebase project.
- Xcode capabilities: *Push Notifications* and *Background Modes → Remote notifications*.
- Badge: the background handler does not run on iOS for a regular "notification" push (without `content-available: 1`). The iOS counter must therefore come from the server payload (`aps.badge` and/or `badge_count`), not from the local increment.

## Testability

`MessagingGateway`, `LocalNotificationsGateway`, `NotificationTokenStore` and `BadgeService` are injectable: tests pass fakes to the constructor, no Firebase is needed.
