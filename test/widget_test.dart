import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:document_editor/src/app.dart';

void main() {
  Widget buildApp() => const DocumentEditorApp();

  testWidgets('wide screen shows both panes side-by-side', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());

    expect(find.text('No document open'), findsOneWidget);
    expect(find.text('Agent Chat'), findsOneWidget);
    expect(find.byIcon(Icons.forum_outlined), findsNothing);

    // Chat pane is to the right of the document pane.
    final documentOffset =
        tester.getTopLeft(find.text('No document open'));
    final chatOffset = tester.getTopLeft(find.text('Agent Chat'));
    expect(chatOffset.dx, greaterThan(documentOffset.dx));
  });

  testWidgets('narrow screen collapses chat and shows expand button',
      (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildApp());

    // Chat pane is hidden until expanded.
    expect(find.text('Agent Chat'), findsNothing);
    expect(find.byIcon(Icons.forum_outlined), findsOneWidget);

    // Expanding overlays the chat on top of the document.
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pump();

    expect(find.text('No document open'), findsOneWidget);
    expect(find.text('Agent Chat'), findsOneWidget);

    // Close button dismisses the overlay.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('Agent Chat'), findsNothing);
    expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
  });

  testWidgets('no layout overflows at boundary width', (tester) async {
    for (final width in [1023.0, 1024.0, 1025.0, 1200.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(buildApp());
      expect(tester.takeException(), isNull,
          reason: 'layout overflow at width $width');
    }
  });
}
