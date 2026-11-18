# flutty_notifications

Notifications push (FCM + APNs) pour les apps Flutter : permission contextuelle, cycle de vie du token d'appareil, affichage au premier plan, routage du tap et badge d'icône.

## Usage

```dart
final notifications = FluttyNotifications();

// Au démarrage : configure la réception SANS demander la permission.
await notifications.init(
  onTokenPersist: (token) => monBackend.registerDevice(token),
  onNotificationTap: (message) => router.pushPath(message.route ?? '/'),
  onForegroundMessage: (message) => rafraichirLesCaches(),
);

// Plus tard, quand le contexte le justifie (premier partage, premier
// enfant…) — jamais au premier lancement sans explication :
final access = await notifications.requestPermission();

// Permission refusée en dur → renvoyer vers les réglages :
if (access == NotificationAccess.blocked) {
  await notifications.openNotificationSettings();
}

// À la déconnexion : dissocier l'appareil du compte.
await notifications.unregisterDevice();

// Après un nouveau login sans ré-init : ré-enregistrer l'appareil.
await notifications.registerDevice();
```

- `onTokenPersist(token)` doit renvoyer `true` si l'enregistrement a réussi — un échec est retenté au prochain `init`, et un token inchangé n'est jamais renvoyé.
- `message.route` porte la route cible du deep link (convention `data['route']` dans le payload FCM). Un tap sur une notification affichée au premier plan livre le `PushMessage` complet (titre, corps, `data`), comme un tap natif.
- Le badge de l'icône est incrémenté automatiquement pour chaque push reçu app fermée (handler background enregistré par `init`), et remis à zéro à l'ouverture **et au retour au premier plan**. Un `badge_count` dans le payload serveur force la valeur exacte.
- FCM n'accepte qu'**un seul handler background** : si l'app a besoin du sien, passer `registerBackgroundHandler: false` à `init` et appeler `fluttyNotificationsBackgroundHandler` depuis son propre handler pour garder le badge à jour.

## Configuration Android

- `AndroidManifest.xml` : ajouter la permission `POST_NOTIFICATIONS` (Android 13+).
- Icône de notification : le package utilise `@mipmap/ic_launcher` pour les notifications au premier plan — fournir une icône dédiée si besoin (voir `flutter_local_notifications`).
- Le canal par défaut est configurable via `androidChannelId` / `androidChannelName` / `androidChannelDescription` dans `init`.
- **Auto Backup** : le flag `flutty_notifications.permission_requested` vit dans `FlutterSharedPreferences.xml`, sauvegardé par défaut par Android. Après restauration (réinstallation, nouvel appareil), `access()` peut rapporter `blocked` alors que le prompt est encore affichable. Si l'app déclare `fullBackupContent`/`dataExtractionRules`, elle peut exclure ce fichier — attention, cela exclut *toutes* ses SharedPreferences. Cas voisin : révocation depuis les réglages système → `access()` reste `blocked` jusqu'au prochain `requestPermission()` (comportement assumé, le prompt ne peut pas être distingué d'un refus définitif sans le flag).

## Configuration iOS

- Clé APNs déclarée dans le projet Firebase.
- Capabilities Xcode : *Push Notifications* et *Background Modes → Remote notifications*.
- Badge : le handler background ne tourne pas sur iOS pour un push « notification » classique (sans `content-available: 1`). Le compteur iOS doit donc venir du payload serveur (`aps.badge` et/ou `badge_count`), pas de l'incrément local.

## Testabilité

`MessagingGateway`, `LocalNotificationsGateway`, `NotificationTokenStore` et `BadgeService` sont injectables : les tests passent des fakes au constructeur, aucun Firebase n'est nécessaire.
