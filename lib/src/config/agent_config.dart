import 'llm_provider.dart';
import 'translation_entry.dart';

/// The full agent configuration: providers, active provider, translation
/// table, and system prompt.
///
/// API keys are intentionally excluded — they live in the secure
/// credential store (see `config_store.dart`).
class AgentConfig {
  AgentConfig({
    List<LlmProvider> providers = const [],
    this.activeProviderId,
    Map<String, TranslationEntry> translationTable = const {},
    this.systemPrompt,
  })  : _providers = List.unmodifiable(providers),
        _translationTable = Map.unmodifiable(translationTable);

  /// Default system prompt: the agent acts as the document's author and is
  /// confined to the document's own content.
  static const String defaultSystemPrompt =
      'You are the assistant author of the open document. '
      'Base every answer and every proposed edit strictly on the content of '
      'the document itself; do not introduce outside facts or opinions. '
      'If the document does not contain the information needed to answer, '
      'say so instead of guessing.';

  final List<LlmProvider> _providers;
  final Map<String, TranslationEntry> _translationTable;

  /// All configured providers, in user-defined order.
  List<LlmProvider> get providers => _providers;

  /// Id of the provider the agent should use, or `null` when none is active.
  final String? activeProviderId;

  /// Translation table keyed by the original phrase.
  Map<String, TranslationEntry> get translationTable => _translationTable;

  /// Custom system prompt; `null` or blank means "use the default".
  final String? systemPrompt;

  /// The provider currently selected for agent calls, if any.
  LlmProvider? get activeProvider {
    final id = activeProviderId;
    if (id == null) return null;
    for (final provider in _providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// Whether the effective system prompt is the built-in default.
  bool get isUsingDefaultPrompt {
    final prompt = systemPrompt;
    return prompt == null || prompt.trim().isEmpty;
  }

  /// The system prompt to inject into agent calls (custom or default).
  String get effectiveSystemPrompt {
    final prompt = systemPrompt;
    return (prompt == null || prompt.trim().isEmpty)
        ? defaultSystemPrompt
        : prompt.trim();
  }

  AgentConfig copyWith({
    List<LlmProvider>? providers,
    String? activeProviderId,
    bool clearActiveProvider = false,
    Map<String, TranslationEntry>? translationTable,
    String? systemPrompt,
    bool clearSystemPrompt = false,
  }) {
    return AgentConfig(
      providers: providers ?? _providers,
      activeProviderId: clearActiveProvider
          ? null
          : (activeProviderId ?? this.activeProviderId),
      translationTable: translationTable ?? _translationTable,
      systemPrompt: clearSystemPrompt
          ? null
          : (systemPrompt ?? this.systemPrompt),
    );
  }

  Map<String, dynamic> toJson() => {
        'activeProviderId': activeProviderId,
        'providers': _providers.map((p) => p.toJson()).toList(),
        'translationTable':
            _translationTable.map((k, v) => MapEntry(k, v.toJson())),
        if (!isUsingDefaultPrompt) 'systemPrompt': systemPrompt,
      };

  factory AgentConfig.fromJson(Map<String, dynamic> json) {
    final rawProviders = (json['providers'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final rawTable = (json['translationTable'] as Map<String, dynamic>? ??
            const <String, dynamic>{})
        .map<String, TranslationEntry>(
          (k, v) => MapEntry(k, TranslationEntry.fromJson(v as Map<String, dynamic>)),
        );
    return AgentConfig(
      providers: rawProviders.map(LlmProvider.fromJson).toList(),
      activeProviderId: json['activeProviderId'] as String?,
      translationTable: rawTable,
      systemPrompt: json['systemPrompt'] as String?,
    );
  }
}
