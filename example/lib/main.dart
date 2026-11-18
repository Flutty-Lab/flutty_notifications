import 'package:flutter/material.dart';
import 'package:flutty_notifications/flutty_notifications.dart';

void main() {
  runApp(const FluttyNotificationsExample());
}

class FluttyNotificationsExample extends StatelessWidget {
  const FluttyNotificationsExample({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Flutty Notifications Example',
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _notifications = FluttyNotifications(
    onError: (error, stack) => debugPrint('[notifications] $error'),
  );

  NotificationAccess _access = NotificationAccess.askable;
  String _lastEvent = '—';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _notifications.init(
      // Remplacer par l'écriture réelle (ex. Cloud Function ou Firestore).
      onTokenPersist: (token) async {
        _log('token persisté: ${token.substring(0, 12)}…');
        return true;
      },
      onTokenRemove: (token) async {
        _log('token retiré');
      },
      onNotificationTap: (message) => _log('tap → ${message.route}'),
      onForegroundMessage: (message) => _log('push: ${message.title}'),
    );
    await _refreshAccess();
  }

  Future<void> _refreshAccess() async {
    final access = await _notifications.access();
    setState(() => _access = access);
  }

  void _log(String event) {
    setState(() => _lastEvent = event);
    debugPrint('[example] $event');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutty_notifications')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Permission : ${_access.name}'),
            const SizedBox(height: 8),
            Text('Dernier événement : $_lastEvent'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                final access = await _notifications.requestPermission();
                setState(() => _access = access);
              },
              child: const Text('Demander la permission'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                await _notifications.openNotificationSettings();
              },
              child: const Text('Ouvrir les réglages système'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _notifications.dispose();
    super.dispose();
  }
}
