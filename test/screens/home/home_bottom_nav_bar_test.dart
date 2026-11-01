import 'package:flutter/material.dart';
import 'package:flutter_muxpod/l10n/app_localizations.dart';
import 'package:flutter_muxpod/screens/home/widgets/home_bottom_nav_bar.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildApp({
  required int currentTab,
  required void Function(int) onSelectTab,
}) {
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
  testWidgets('bottom nav shows the five tabs of the stock design', (
    tester,
  ) async {
    var selected = -1;
    await tester.pumpWidget(
      _buildApp(currentTab: 2, onSelectTab: (i) => selected = i),
    );

    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Keys'), findsOneWidget);
    expect(find.text('Notify'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // The Agent tab was removed: agents are reached from the terminal now.
    expect(find.text('Agent'), findsNothing);

    // The protruding center Dashboard button selects index 2 without a
    // label.
    await tester.tap(find.byIcon(Icons.terminal));
    expect(selected, 2);

    await tester.tap(find.text('Keys'));
    await tester.tap(find.text('Notify'));
    await tester.tap(find.text('Settings'));
    expect(selected, 4);
  });
}
