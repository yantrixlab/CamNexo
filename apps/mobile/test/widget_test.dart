import 'package:flutter_test/flutter_test.dart';

import 'package:camnexo_mobile/main.dart';

void main() {
  testWidgets('shows the CamNexo header and connection status', (tester) async {
    await tester.pumpWidget(const CamNexoApp());
    // Let the failed plugin call complete, then rebuild.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('CamNexo'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    // No camera plugin in unit tests: the screen falls back to its retry state.
    expect(find.text('Retry'), findsOneWidget);
  });
}
