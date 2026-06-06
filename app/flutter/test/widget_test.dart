// Widget tests for the Yarnia app.
//
// On launch the app reads the remembered child off-device: a stored child skips
// straight to the greeting ("logged in"), none routes to onboarding. With no stored
// child (the default here) we land on onboarding. Onboarding's network call, and the
// greeting/speech flows it unlocks, are intentionally not exercised (they need a live
// API / platform channels), so these tests stay fast and hermetic.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yarnia/main.dart';
import 'package:yarnia/services/child_store.dart';

void main() {
  testWidgets('with no remembered child, the app opens on onboarding',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({}); // no stored child
    await tester.pumpWidget(const YarniaApp());
    // Let _restoreChild resolve (async prefs read) and rebuild. Starfield animates
    // forever, so we pump fixed frames rather than pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Welcome to Yarnia'), findsOneWidget);
    expect(find.text('Who are we telling a story to tonight?'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // the name field
    expect(find.text('4'), findsOneWidget); // an age chip
    expect(find.text('Begin'), findsOneWidget);
  });

  test('child_store remembers, reloads, and forgets the child', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await loadStoredChild(), isNull);

    await saveStoredChild('child-123', 'Mira');
    final loaded = await loadStoredChild();
    expect(loaded?.childId, 'child-123');
    expect(loaded?.name, 'Mira');

    await clearStoredChild();
    expect(await loadStoredChild(), isNull);
  });
}
