import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_shell_app/main.dart';

void main() {
  testWidgets('UbuntuShellApp smoke test loads NavigationRail', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const UbuntuShellApp());
    expect(find.text('Ubuntu Shell'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    expect(find.byIcon(Icons.dashboard_rounded), findsOneWidget);
    expect(find.byIcon(Icons.history_rounded), findsOneWidget);
    expect(find.byIcon(Icons.terminal_rounded), findsWidgets);
    expect(find.byIcon(Icons.shield_rounded), findsOneWidget);
  });
}
