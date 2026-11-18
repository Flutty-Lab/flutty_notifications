import 'package:flutty_notifications/flutty_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferencesTokenStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = SharedPreferencesTokenStore(await SharedPreferences.getInstance());
  });

  test('persistedToken est null au départ', () {
    expect(store.persistedToken, isNull);
  });

  test('save puis lecture', () async {
    await store.save('token-1');
    expect(store.persistedToken, 'token-1');
  });

  test('clear oublie le token', () async {
    await store.save('token-1');
    await store.clear();
    expect(store.persistedToken, isNull);
  });
}
