/// Role of a chat message author.
enum ChatRole {
  /// A message typed by the user.
  user,

  /// A message produced by the agent (LLM integration arrives in Plan 07).
  agent,
}

/// A single chat message.
///
/// Plain data with JSON (de)serialization so histories can be persisted to
/// disk and reloaded on app start.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
  });

  /// Stable identifier, generated when the message is created.
  final String id;

  /// Who authored the message.
  final ChatRole role;

  /// Message body (plain text for now).
  final String text;

  /// Creation time, used for display ordering.
  final DateTime timestamp;

  /// Creates a new message with a generated id and [timestamp] (defaults to
  /// now).
  factory ChatMessage.create({
    required ChatRole role,
    required String text,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      id: '${role.name}-${DateTime.now().microsecondsSinceEpoch}',
      role: role,
      text: text,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: ChatRole.values.byName(json['role'] as String),
      text: json['text'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}
