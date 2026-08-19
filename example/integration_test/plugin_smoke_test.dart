import 'package:decart_vton_example/main.dart';
import 'package:decart_vton_flutter/decart_vton_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('registers the native plugin and renders the idle camera UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TryOnApp());
    await tester.pumpAndSettle();

    expect(find.text('Start camera'), findsOneWidget);
    expect(find.byType(VtonRemoteView), findsOneWidget);

    await tester.tap(find.text('Start camera'));
    await tester.pumpAndSettle();
    expect(find.text('Developer configuration missing'), findsOneWidget);
    expect(find.textContaining('tool/run_example.sh'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
