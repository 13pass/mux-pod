import 'package:flutter/material.dart';
import 'package:flutter_muxpod/l10n/app_localizations.dart';
import 'package:flutter_muxpod/screens/home/widgets/home_bottom_nav_bar.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildApp({required int currentTab, required void Function(int) onSelectTab}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: const SizedBox.shrink(),
      bottomNavigationBar: HomeBottomNavBar(
        currentTab: currentTab,
        onSelectTab: onSelectTab,
      ),
    ),
  );
}

void main() {
  testWidgets('bottom nav shows six entries including Agent (index 5)',
      (tester) async {
    var selected = -1;
    await tester.pumpWidget(_buildApp(currentTab: 2, onSelectTab: (i) => selected = i));

    // All six labels are rendered, evenly, with no overlay button
    // stealing taps (en locale default in tests).
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Keys'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Notify'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.byKey(const Key('home_nav_agent')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home_nav_agent')));
    expect(selected, 5);
    await tester.tap(find.text('Dashboard'));
    expect(selected, 2);
  });

  testWidgets('tapping Servers/Keys/Notify/Settings selects their indices',
      (tester) async {
    final selected = <int>[];
    await tester.pumpWidget(_buildApp(currentTab: 0, onSelectTab: selected.add));
    await tester.tap(find.text('Keys'));
    await tester.tap(find.text('Notify'));
    await tester.tap(find.text('Settings'));
    expect(selected, [1, 3, 4]);
  });
}
