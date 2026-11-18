# AGENTS.md - flutty_notifications

Flutter package (`pub.dev: flutty_notifications`) for FCM/APNs push notifications: contextual permission, device token lifecycle, foreground display, tap routing, app badge. Lives in the `flutty_core` workspace. Extracted and generalized from Appels Pro.

## Big picture

- `lib/src/flutty_notifications.dart` — facade `FluttyNotifications`: `init()` wires everything **without asking permission** (contextual ask is `requestPermission()`), registers the background handler (skippable via `registerBackgroundHandler: false` when the app owns one — it must then call `fluttyNotificationsBackgroundHandler` itself), resets the badge at init and on resume, registers the token only if permission is already granted. `registerDevice()` re-registers after a re-login without re-init.
- `lib/src/gateways.dart` — `MessagingGateway` (FirebaseMessaging) and `LocalNotificationsGateway` (flutter_local_notifications) abstractions; the concrete classes are the only files touching plugin APIs — inject fakes in tests.
- `lib/src/background_handler.dart` — top-level `vm:entry-point` FCM background handler: increments the badge via SharedPreferences (GetIt/DI does not exist in that isolate).
- `lib/src/badge_service.dart` — icon badge counter persisted in SharedPreferences (shared with the background isolate); native update is best-effort.
- `lib/src/permission_service.dart` — `NotificationAccess` = granted / askable / blocked; iOS reads `getNotificationSettings`, Android reads `permission_handler`; `openNotificationSettings` for the blocked case.
- `lib/src/token_store.dart` — persists the last successfully sent token: no resend on unchanged token, retry on next `init` after a failed send.

## Conventions agents should follow

- Never request permission inside `init()` — the app chooses the moment via `requestPermission()` (epic PM-E5 decision).
- Deep link convention: `data['route']` in the FCM payload → `PushMessage.route` → `onNotificationTap`.
- Every internal failure is reported through `onError` (or `debugPrint`) and never rethrown — push must never break the app.
- `unregisterDevice()` forgets the stored token even if the backend call failed; `forgetDevice()` is for already-invalid sessions.
- New platform-touching code goes behind a gateway interface, never as a direct plugin call in `FluttyNotifications`.
- Tests use the mocks in `test/mocks.dart` (mocktail) — no Firebase needed.
