import 'dart:async';
import 'dart:io';

import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/chat/chat_message.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/llm/llm_client.dart';
import 'package:document_editor/src/tools/document_tools.dart';
import 'package:document_editor/src/tools/supporting_files.dart';
import 'package:document_editor/src/tools/tool_registry.dart';
import 'package:document_editor/src/ui/document_view_pane.dart';
import 'package:document_editor/src/ui/main_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// UI tests for agent tool use: edits made through the write tool appear in
/// the open editor, tool activity shows in the chat, and attached
/// supporting files are listed.
///
/// As in chat_ui_test, real file I/O is started inside
/// [WidgetTester.runAsync].
void main() {
  late Directory tempDir;
  late DocumentState state;
  late SupportingFiles files;
  late ChatController chat;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('agent_tools_ui_test');
    state = DocumentState();
    files = SupportingFiles();
  });

  tearDown(() {
    chat.dispose();
    files.dispose();
    state.dispose();
    tempDir.deleteSync(recursive: true);
  });

  /// An agent that edits the document through the real write tool.
  AgentResponder editingAgent(String oldText, String newText) {
    final tools = ToolRegistry([WriteDocumentTool(state)]);
    return ({
      required List<ChatMessage> history,
      required void Function(String chunk) onChunk,
      required void Function(String error) onError,
      required void Function(String summary) onToolActivity,
      required bool Function() isCancelled,
    }) async {
      final execution = await tools.execute(LlmToolCall(
        id: 'w',
        name: 'write_document',
        arguments: {
          'edits': [
            {'old_text': oldText, 'new_text': newText},
          ],
        },
      ));
      onToolActivity(execution.summary);
      onChunk('Done.');
    };
  }

  Future<void> pumpApp(WidgetTester tester, {AgentResponder? agent}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      final file = File('${tempDir.path}/doc.txt')
        ..writeAsStringSync('The draft sentence.');
      await state.openFile(file.path);
      chat = ChatController(
        document: state,
        store: ChatHistoryStore(baseDirectory: tempDir.path),
        agent: agent,
      );
      await chat.whenIdle;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: DocumentScope(
          document: state,
          child: MainLayout(chat: chat, supportingFiles: files),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('agent edits appear in the editor and the chat', (tester) async {
    await pumpApp(tester,
        agent: editingAgent('draft sentence', 'final sentence'));
    expect(find.textContaining('The draft sentence.', findRichText: true),
        findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'Fix');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pump();
      await chat.whenReplyDone;
      await chat.whenIdle;
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('The final sentence.', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('The draft sentence.', findRichText: true),
        findsNothing);
    expect(find.text('Edited the document'), findsOneWidget);
    expect(find.text('Done.'), findsOneWidget);
    // Unsaved agent edits mark the document dirty.
    expect(find.text('doc.txt*'), findsOneWidget);

    // The edit is undoable from the toolbar.
    await tester.tap(find.byTooltip('Undo (Ctrl/Cmd+Z)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The draft sentence.', findRichText: true),
        findsOneWidget);
  });

  testWidgets('user can keep editing while the agent is responding',
      (tester) async {
    // The agent waits for [release] before writing, so the user can type
    // while the reply is in flight. Created inside runAsync below: a
    // completer from the fake-async zone would never deliver its value.
    late Completer<void> release;
    final tools = ToolRegistry([WriteDocumentTool(state)]);
    await pumpApp(tester, agent: ({
      required List<ChatMessage> history,
      required void Function(String chunk) onChunk,
      required void Function(String error) onError,
      required void Function(String summary) onToolActivity,
      required bool Function() isCancelled,
    }) async {
      await release.future;
      final execution = await tools.execute(const LlmToolCall(
        id: 'w',
        name: 'write_document',
        arguments: {
          'edits': [
            {'old_text': 'draft', 'new_text': 'final'},
          ],
        },
      ));
      onToolActivity(execution.summary);
    });

    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'Fix');
    await tester.runAsync(() async {
      release = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pump();
      expect(chat.isResponding, isTrue);

      // The user types at the start of the document mid-reply.
      state.quill.replaceText(
          0, 0, 'Note: ', const TextSelection.collapsed(offset: 6));
      await tester.pump();
      expect(
          find.textContaining('Note: The draft sentence.', findRichText: true),
          findsOneWidget);

      release.complete();
      await chat.whenReplyDone;
      await chat.whenIdle;
    });
    await tester.pumpAndSettle();

    // Both the user's typing and the agent's edit are present, and the
    // user's caret moved with the text it was in.
    expect(find.textContaining('Note: The final sentence.', findRichText: true),
        findsOneWidget);
    expect(state.quill.selection, const TextSelection.collapsed(offset: 6));
  });

  testWidgets('attached supporting files are listed and removable',
      (tester) async {
    await pumpApp(tester);
    expect(find.byTooltip('Attach supporting files for the agent'),
        findsOneWidget);
    expect(find.byType(InputChip), findsNothing);

    files.addAll(['/data/notes.md', '/data/brief.docx']);
    await tester.pump();
    expect(find.widgetWithText(InputChip, 'notes.md'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'brief.docx'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.widgetWithText(InputChip, 'notes.md'),
      matching: find.byTooltip('Remove'),
    ));
    await tester.pump();
    expect(files.paths, ['/data/brief.docx']);
    expect(find.widgetWithText(InputChip, 'notes.md'), findsNothing);
  });
}
