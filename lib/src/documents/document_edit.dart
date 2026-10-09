/// A content-anchored text replacement in a document.
///
/// [oldText] must match exactly one place in the document's plain text;
/// it is replaced by [newText]. An empty [oldText] appends [newText] to the
/// end of the document.
class TextEdit {
  const TextEdit({required this.oldText, required this.newText});

  final String oldText;
  final String newText;
}

/// Raised when a batch of [TextEdit]s cannot be applied.
///
/// [message] is written for the agent: it explains what went wrong and how
/// to fix the request.
class DocumentEditException implements Exception {
  const DocumentEditException(this.message);

  final String message;

  @override
  String toString() => 'DocumentEditException: $message';
}
