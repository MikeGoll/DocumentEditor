import 'package:flutter/material.dart';
import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/ui/app_theme.dart';
import 'package:document_editor/src/ui/document_view_pane.dart';
import 'package:document_editor/src/ui/main_layout.dart';

/// Root widget for the Document Editor application.
class DocumentEditorApp extends StatefulWidget {
  const DocumentEditorApp({super.key, this.chatBaseDirectory});

  /// Overrides the directory where chat histories are stored.
  ///
  /// Defaults to `~/Documents/DocumentEditor/chats`; tests pass a temp dir.
  final String? chatBaseDirectory;

  @override
  State<DocumentEditorApp> createState() => _DocumentEditorAppState();
}

class _DocumentEditorAppState extends State<DocumentEditorApp> {
  final DocumentState _document = DocumentState();
  late final ChatController _chat = ChatController(
    document: _document,
    store: ChatHistoryStore(baseDirectory: widget.chatBaseDirectory),
  );

  @override
  void initState() {
    super.initState();
    // Keep the window title in sync with the open document.
    _document.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _chat.dispose();
    _document.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _document.title,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: DocumentScope(
        document: _document,
        child: MainLayout(chat: _chat),
      ),
    );
  }
}
