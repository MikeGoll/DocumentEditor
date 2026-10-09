/// The LLM backends the agent can talk to.
enum ProviderType {
  localOpenAi(
    label: 'Local OpenAI-style API',
    requiresApiKey: false,
    defaultEndpoint: null,
    endpointHint: 'e.g. http://localhost:11434/v1',
  ),
  anthropic(
    label: 'Anthropic',
    requiresApiKey: true,
    defaultEndpoint: 'https://api.anthropic.com',
    endpointHint: 'Defaults to https://api.anthropic.com',
  ),
  openai(
    label: 'OpenAI',
    requiresApiKey: true,
    defaultEndpoint: 'https://api.openai.com/v1',
    endpointHint: 'Defaults to https://api.openai.com/v1',
  ),
  google(
    label: 'Google',
    requiresApiKey: true,
    defaultEndpoint: 'https://generativelanguage.googleapis.com/v1beta',
    endpointHint:
        'Defaults to https://generativelanguage.googleapis.com/v1beta',
  );

  const ProviderType({
    required this.label,
    required this.requiresApiKey,
    required this.defaultEndpoint,
    required this.endpointHint,
  });

  /// Human-readable name used in the UI.
  final String label;

  /// Whether an API key must be stored for this provider type.
  final bool requiresApiKey;

  /// Endpoint used when the user leaves the endpoint field empty.
  final String? defaultEndpoint;

  /// Hint text for the endpoint field in the provider form.
  final String endpointHint;
}

/// A configured LLM provider.
///
/// The API key is deliberately *not* part of this object: keys live in the
/// [CredentialStore] (see `config_store.dart`) so they never end up in the
/// plain-JSON config file.
class LlmProvider {
  LlmProvider({
    required this.id,
    required this.name,
    required this.type,
    this.endpoint,
    this.model,
  });

  /// Stable unique identifier (used as the credential-store key).
  final String id;

  /// User-chosen display name.
  final String name;

  final ProviderType type;

  /// API endpoint override; `null` means "use the type default".
  final String? endpoint;

  /// Model identifier (e.g. `gpt-4o-mini`); optional.
  final String? model;

  /// Endpoint to actually call: the override, or the type default.
  String? get effectiveEndpoint {
    final value = endpoint ?? type.defaultEndpoint;
    return (value == null || value.trim().isEmpty)
        ? null
        : value.trim();
  }

  /// Model to actually use, or `null` when unset.
  String? get effectiveModel {
    final value = model;
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  /// Validates the provider, returning a field-name → error message map.
  ///
  /// [hasApiKey] reports whether an API key is stored for this provider; it
  /// is only consulted for types that require one.
  Map<String, String> validate({required bool hasApiKey}) {
    final errors = <String, String>{};
    if (name.trim().isEmpty) {
      errors['name'] = 'Name is required.';
    }
    if (type == ProviderType.localOpenAi && effectiveEndpoint == null) {
      errors['endpoint'] = 'Endpoint URL is required for local APIs.';
    }
    final endpoint = effectiveEndpoint;
    if (endpoint != null &&
        !endpoint.startsWith('http://') &&
        !endpoint.startsWith('https://')) {
      errors['endpoint'] = 'Endpoint must start with http:// or https://.';
    }
    if (type.requiresApiKey && !hasApiKey) {
      errors['apiKey'] = 'API key is required for ${type.label}.';
    }
    return errors;
  }

  LlmProvider copyWith({
    String? name,
    ProviderType? type,
    String? endpoint,
    String? model,
    bool clearEndpoint = false,
    bool clearModel = false,
  }) {
    return LlmProvider(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      endpoint: clearEndpoint ? null : (endpoint ?? this.endpoint),
      model: clearModel ? null : (model ?? this.model),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        if (endpoint != null && endpoint!.trim().isNotEmpty)
          'endpoint': endpoint,
        if (model != null && model!.trim().isNotEmpty) 'model': model,
      };

  factory LlmProvider.fromJson(Map<String, dynamic> json) {
    return LlmProvider(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      type: ProviderType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => ProviderType.localOpenAi,
      ),
      endpoint: json['endpoint'] as String?,
      model: json['model'] as String?,
    );
  }
}
