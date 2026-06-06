// Widget tests for the Yarnia app.
//
// The app opens on the greeting screen, which shows a personalized good-night
// message and a "Begin" button. We verify that initial render here. Network and
// speech flows are intentionally not exercised (they need a live API / platform
// channels), so these tests stay fast and hermetic.

import 'package:flutter_test/flutter_test.dart';
import 'package:yarnia/main.dart';

void main() {
  testWidgets('greeting screen renders the good-night message and Begin button',
      (WidgetTester tester) async {
    await tester.pumpWidget(const YarniaApp());

    // The greeting screen fades in over ~2s; settle the animations.
    await tester.pump(const Duration(seconds: 3));

    expect(find.text('Good night, Lisa.'), findsOneWidget);
    expect(find.text('Begin'), findsOneWidget);
  });
}
