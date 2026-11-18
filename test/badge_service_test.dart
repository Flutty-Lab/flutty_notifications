import 'package:flutty_notifications/flutty_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late List<int> updates;
  late BadgeService badge;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    updates = [];
    badge = BadgeService(
      prefs,
      badgeUpdater: (count) async {
        updates.add(count);
      },
    );
  });

  test('increment starts from zero', () async {
    await badge.increment();
    expect(updates, [1]);
    expect(prefs.getInt(BadgeService.countKey), 1);
  });

  test('increment persists the counter across two instances', () async {
    await badge.increment();
    await badge.increment();
    final other = BadgeService(prefs, badgeUpdater: (_) async {});
    await other.increment();
    expect(prefs.getInt(BadgeService.countKey), 3);
  });

  test('set writes the exact value', () async {
    await badge.set(7);
    expect(updates, [7]);
    expect(prefs.getInt(BadgeService.countKey), 7);
  });

  test('reset sets back to zero', () async {
    await badge.set(3);
    await badge.reset();
    expect(updates, [3, 0]);
    expect(prefs.getInt(BadgeService.countKey), 0);
  });

  test('a native badge failure is not propagated', () async {
    badge = BadgeService(
      prefs,
      badgeUpdater: (_) async => throw Exception('launcher'),
    );
    await expectLater(badge.increment(), completes);
  });
}
