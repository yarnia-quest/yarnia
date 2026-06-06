// Widget tests for the Yarnia app.
//
// The app opens on the onboarding screen, which asks for the child's name and age
// before minting a child profile (POST /child) and routing into greeting -> voice.
// We verify that initial render here. Onboarding's network call, and the greeting
// and speech flows it unlocks, are intentionally not exercised (they need a live
// API / platform channels), so these tests stay fast and hermetic.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yarnia/main.dart';

void main() {
  testWidgets('onboarding screen renders the welcome, name field, age chips and Begin',
      (WidgetTester tester) async {
    await tester.pumpWidget(const YarniaApp());
    await tester.pump();

    expect(find.text('Welcome to Yarnia'), findsOneWidget);
    expect(find.text('Who are we telling a story to tonight?'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // the name field
    expect(find.text('4'), findsOneWidget); // an age chip
    expect(find.text('Begin'), findsOneWidget);
  });
}
