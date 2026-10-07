import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/ui/document_view_pane.dart';
import 'package:document_editor/src/ui/main_layout.dart';

/// Chat UI tests.
///
/// Real file I/O does not complete inside testWidgets' FakeAsync zone: it
/// must be *started* inside [WidgetTester.runAsync] so its continuations run
/// in the real zone. The controller is therefore created and all taps that
/// trigger history I/O are dispatched inside runAsync, and
/// [ChatController.whenIdle] is awaited there to let writes finish.
void main() {
  late Directory tempDir;
  late DocumentState state;
  late ChatController chat;

  ChatController createChat() => ChatController(
        document: state,
        store: ChatHistoryStore(baseDirectory: tempDir.path),
      );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('chat_ui_test');
    state = DocumentState();
  });

  tearDown(() {
    chat.dispose();
    state.dispose();
    tempDir.deleteSync(recursive: true);
  });

  /// Creates the chat controller and pumps the app around it.
  ///
  /// The controller is created inside runAsync so its initial history load
  /// (real file I/O) can complete.
  Future<void> pumpApp(WidgetTester tester,
      {Size size = const Size(1400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      chat = createChat();
      await chat.whenIdle;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: DocumentScope(
          document: state,
          child: MainLayout(chat: chat),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> sendMessage(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const ValueKey('chat-input')),
      text,
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pump();
      // Let the history file write finish so later assertions are stable.
      await chat.whenIdle;
    });
    await tester.pump();
  }

  testWidgets('sending a message shows a user bubble', (tester) async {
    await pumpApp(tester);
    expect(find.text('No messages yet'), findsOneWidget);

    await sendMessage(tester, 'Hello there');

    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('No messages yet'), findsNothing);
    // The input is cleared after sending.
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-input')),
    );
    expect(input.controller!.text, isEmpty);
  });

  testWidgets('blank messages are not sent', (tester) async {
    await pumpApp(tester);

    await sendMessage(tester, '   ');

    expect(find.text('No messages yet'), findsOneWidget);
  });

  testWidgets('messages appear in chronological order', (tester) async {
    await pumpApp(tester);

    await sendMessage(tester, 'first');
    await sendMessage(tester, 'second');
    await sendMessage(tester, 'third');

    final first = tester.getTopLeft(find.text('first'));
    final second = tester.getTopLeft(find.text('second'));
    final third = tester.getTopLeft(find.text('third'));
    expect(first.dy, lessThan(second.dy));
    expect(second.dy, lessThan(third.dy));
  });

  testWidgets('history persists across app restarts', (tester) async {
    await pumpApp(tester);
    await sendMessage(tester, 'remember me');
    expect(find.text('remember me'), findsOneWidget);

    // Simulate an app restart: unmount, dispose the controller, then launch
    // a fresh controller + layout pointing at the same chat directory.
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
    await pumpApp(tester);

    expect(find.text('remember me'), findsOneWidget);
  });

  testWidgets('reset clears the conversation and its file', (tester) async {
    await pumpApp(tester);
    await sendMessage(tester, 'to be cleared');
    expect(find.text('to be cleared'), findsOneWidget);
    // The history file was written to disk.
    expect(File('${tempDir.path}/untitled_default.json').existsSync(), isTrue);

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pump();
      await chat.whenIdle;
    });
    await tester.pump();

    expect(find.text('to be cleared'), findsNothing);
    expect(find.text('No messages yet'), findsOneWidget);
    // The history file was removed from disk.
    expect(File('${tempDir.path}/untitled_default.json').existsSync(), isFalse);
  });

  testWidgets('chat works in the narrow-screen overlay', (tester) async {
    await pumpApp(tester, size: const Size(700, 900));

    // Expand the collapsed chat.
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pump();
    expect(find.text('Agent Chat'), findsOneWidget);

    await sendMessage(tester, 'overlay message');

    expect(find.text('overlay message'), findsOneWidget);

    // Close the overlay and reopen: the message is still there.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pump();
    expect(find.text('overlay message'), findsOneWidget);
  });
}
