/// Statut d'accès aux notifications de l'appareil.
enum NotificationAccess {
  /// Les notifications sont autorisées.
  granted,

  /// La permission n'a jamais été demandée : on peut afficher la demande
  /// système.
  askable,

  /// Refusé (définitivement) : il faut renvoyer l'utilisateur vers les
  /// réglages système.
  blocked,
}

/// Message push normalisé, indépendant de `firebase_messaging`.
class PushMessage {
  const PushMessage({this.title, this.body, required this.data});

  /// Titre de la notification, si le message en porte un.
  final String? title;

  /// Corps de la notification, si le message en porte un.
  final String? body;

  /// Données arbitraires du message (`RemoteMessage.data`).
  final Map<String, dynamic> data;

  /// Route cible pour le deep link, convention `data['route']`.
  String? get route => data['route'] as String?;
}
