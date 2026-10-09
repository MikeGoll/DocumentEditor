/// A single phrase → correction pair in the translation table.
///
/// The agent uses the table to apply the user's preferred wording when it
/// writes or edits document text.
class TranslationEntry {
  const TranslationEntry({required this.original, required this.correction});

  /// The phrase as it appears (or would appear) in the document.
  final String original;

  /// The wording the user prefers instead.
  final String correction;

  TranslationEntry copyWith({String? original, String? correction}) {
    return TranslationEntry(
      original: original ?? this.original,
      correction: correction ?? this.correction,
    );
  }

  Map<String, dynamic> toJson() =>
      {'original': original, 'correction': correction};

  factory TranslationEntry.fromJson(Map<String, dynamic> json) {
    return TranslationEntry(
      original: json['original'] as String? ?? '',
      correction: json['correction'] as String? ?? '',
    );
  }
}
