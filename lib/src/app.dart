import 'package:flutter/material.dart';
import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/config/config_store.dart';
import 'package:document_editor/src/config/credential_store.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/llm/agent_service.dart';
import 'package:document_editor/src/tools/document_tools.dart';
import 'package:document_editor/src/tools/supporting_files.dart';
import 'package:document_editor/src/tools/tool_registry.dart';
import 'package:document_editor/src/ui/app_theme.dart';
import 'package:document_editor/src/ui/document_view_pane.dart';
import 'package:document_editor/src/ui/main_layout.dart';
import 'package:document_editor/src/ui/settings/settings_screen.dart';

/// Root widget for the Document Editor application.
class DocumentEditorApp extends StatefulWidget {
  const DocumentEditorApp({
    super.key,
    this.chatBaseDirectory,
    this.configBaseDirectory,
    this.credentialStore,
  });

  /// Overrides the directory where chat histories are stored.
  ///
  /// Defaults to `~/Documents/DocumentEditor/chats`; tests pass a temp dir.
  final String? chatBaseDirectory;

  /// Overrides the directory where the agent configuration is stored.
  ///
  /// Defaults to `~/Documents/DocumentEditor/config`; tests pass a temp dir.
  final String? configBaseDirectory;

  /// Overrides where API keys are stored.
  ///
  /// Defaults to the OS keychain/keystore via `flutter_secure_storage`;
  /// tests pass an in-memory store.
  final CredentialStore? credentialStore;

  @override
  State<DocumentEditorApp> createState() => _DocumentEditorAppState();
}

class _DocumentEditorAppState extends State<DocumentEditorApp> {
  final DocumentState _document = DocumentState();
  late final AgentConfigController _config = AgentConfigController(
    store: ConfigStore(
      baseDirectory: widget.configBaseDirectory,
      credentials: widget.credentialStore ?? const SecureCredentialStore(),
    ),
  );
  final SupportingFiles _supportingFiles = SupportingFiles();
  late final AgentService _agent = AgentService(
    config: _config,
    document: _document,
    supportingFiles: _supportingFiles,
    tools: ToolRegistry([
      ReadDocumentTool(_document),
      WriteDocumentTool(_document),
      ReadSupportingFileTool(_supportingFiles),
    ]),
  );
  late final ChatController _chat = ChatController(
    document: _document,
    store: ChatHistoryStore(baseDirectory: widget.chatBaseDirectory),
    agent: _agent.respond,
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
    _supportingFiles.dispose();
    _config.dispose();
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
      home: AgentConfigScope(
        config: _config,
        child: DocumentScope(
          document: _document,
          child: MainLayout(chat: _chat, supportingFiles: _supportingFiles),
        ),
      ),
    );
  }
}
