import 'dart:io';

import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/ui/document_view_pane.dart';
import 'package:document_editor/src/ui/main_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds the toolbar [IconButton] whose tooltip is [tooltip].
IconButton findButton(WidgetTester tester, String tooltip) {
  final finder = find.ancestor(
    of: find.byWidgetPredicate((w) => w is Tooltip && w.message == tooltip),
    matching: find.byType(IconButton),
  );
  return tester.widget<IconButton>(finder);
}

void main() {
  late Directory tempDir;
  late DocumentState state;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('document_editor_widget');
    state = DocumentState();
  });

  tearDown(() {
    state.dispose();
    tempDir.deleteSync(recursive: true);
  });

  String writeTemp(String name, String content) {
    final file = File('${tempDir.path}/$name')..writeAsStringSync(content);
    return file.path;
  }

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: DocumentScope(
          document: state,
          child: const MainLayout(),
        ),
      ),
    );
  }

  testWidgets('shows placeholder before a file is opened', (tester) async {
    await pumpApp(tester);

    expect(find.text('No document open'), findsOneWidget);
    expect(find.byType(QuillEditor), findsNothing);
    // Toolbar controls are present.
    expect(find.byIcon(Icons.format_bold), findsOneWidget);
    expect(find.byIcon(Icons.format_italic), findsOneWidget);
    expect(find.byIcon(Icons.format_underlined), findsOneWidget);
    expect(find.byIcon(Icons.undo), findsOneWidget);
    expect(find.byIcon(Icons.redo), findsOneWidget);
  });

  testWidgets('opens a file and renders it in the editor', (tester) async {
    await pumpApp(tester);

    await state.openFile(writeTemp('doc.txt', 'hello document\n'));
    await tester.pump();

    expect(find.text('No document open'), findsNothing);
    expect(find.byType(QuillEditor), findsOneWidget);
    // The open file name is shown in the toolbar.
    expect(find.text('doc.txt'), findsOneWidget);
  });

  testWidgets('save button enables when the document becomes dirty',
      (tester) async {
    await pumpApp(tester);
    await state.openFile(writeTemp('dirty.txt', 'start\n'));
    await tester.pump();

    IconButton saveButton() => findButton(tester, 'Save (Ctrl/Cmd+S)');

    expect(saveButton().onPressed, isNull,
        reason: 'save should be disabled for a clean document');

    state.quill.replaceText(
      state.quill.document.length - 1,
      0,
      'x',
      const TextSelection.collapsed(offset: 6),
    );
    await tester.pump();

    expect(saveButton().onPressed, isNotNull,
        reason: 'save should be enabled for a dirty document');
  });

  testWidgets('bold toolbar button applies bold to the selection',
      (tester) async {
    await pumpApp(tester);
    await state.openFile(writeTemp('bold.txt', 'word\n'));
    await tester.pump();

    state.quill.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 4),
      ChangeSource.local,
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.format_bold));
    await tester.pump();

    final styles = state.quill.getAllSelectionStyles();
    expect(
      styles.any((s) => s.values.any((a) => a.key == 'bold')),
      isTrue,
      reason: 'selection should be bold after tapping the bold button',
    );
  });

  testWidgets('Ctrl+S saves the document through the shortcut layer',
      (tester) async {
    final path = writeTemp('shortcut.txt', 'before\n');
    await pumpApp(tester);
    await state.openFile(path);
    await tester.pump();

    // Make a change on the last line.
    state.quill.replaceText(
      state.quill.document.length - 1,
      0,
      'after',
      const TextSelection.collapsed(offset: 11),
    );
    await tester.pump();
    expect(state.dirty, isTrue);

    // Focus the editor so the shortcut reaches the pane's binding,
    // then fire Ctrl+S.
    await tester.tap(find.byType(QuillEditor));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.dirty, isFalse,
        reason: 'Ctrl+S should save the document');
    expect(File(path).readAsStringSync(), 'beforeafter\n');
  });
}
