import 'dart:convert';

import 'dart:io';

import 'package:path/path.dart' as p;

import 'chat_message.dart';

/// Persists chat histories as JSON files, one per (document, session) pair.
///
/// Files live in `~/Documents/DocumentEditor/chats/` by default, named
/// `{documentId}_{session}.json`. The base directory can be overridden
/// (e.g. in tests) via the constructor.
class ChatHistoryStore {
  ChatHistoryStore({String? baseDirectory})
      : _directory = baseDirectory ??
            p.join(_defaultHome, 'Documents', 'DocumentEditor', 'chats');

  /// Home directory from the environment (sync access; `Directory.home()`
  /// is async and unavailable in a constructor).
  static String get _defaultHome =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

  /// Default session name for the current app run.
  static const String defaultSession = 'default';

  final String _directory;

  /// Absolute path of the base directory holding chat history files.
  String get directoryPath => _directory;

  /// Path of the history file for [documentId] and [session].
  String fileFor(String documentId, String session) =>
      p.join(_directory, '${documentId}_$session.json');

  /// Loads the history for [documentId] and [session].
  ///
  /// Returns an empty list when no file exists or its content is not valid
  /// history JSON, so a missing/corrupt file never breaks the UI.
  Future<List<ChatMessage>> load(String documentId, String session) async {
    final file = File(fileFor(documentId, session));
    if (!await file.exists()) return const [];
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final raw = (json['messages'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      return raw.map(ChatMessage.fromJson).toList();
    } on FormatException {
      return const [];
    }
  }

  /// Writes [messages] as the full history for [documentId] and [session],
  /// creating the base directory if needed.
  Future<void> save(
    String documentId,
    String session,
    List<ChatMessage> messages,
  ) async {
    await Directory(_directory).create(recursive: true);
    final payload = {
      'documentId': documentId,
      'session': session,
      'updatedAt': DateTime.now().toIso8601String(),
      'messages': messages.map((m) => m.toJson()).toList(),
    };
    await File(fileFor(documentId, session))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  }

  /// Deletes the history file for [documentId] and [session] if present.
  Future<void> clear(String documentId, String session) async {
    final file = File(fileFor(documentId, session));
    if (await file.exists()) {
      await file.delete();
    }
  }
}
