import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/llm_provider.dart';

/// Why an LLM request failed.
enum LlmErrorKind {
  /// The request is not possible with the current configuration
  /// (missing model, endpoint, or API key).
  config,

  /// The provider rejected the credentials (HTTP 401/403).
  auth,

  /// The provider could not be reached (DNS, connection refused, timeout).
  network,

  /// The provider returned an error response or malformed data.
  api,
}

/// A failure while talking to an LLM provider.
///
/// [message] is user-facing: it is safe to show in the chat pane as-is.
class LlmException implements Exception {
  const LlmException(this.kind, this.message);

  final LlmErrorKind kind;
  final String message;

  @override
  String toString() => 'LlmException(${kind.name}): $message';
}

/// Role of a single message in a completion request.
enum LlmRole { user, assistant }

/// A tool the model may call, described by a JSON schema.
///
/// [parameters] is a JSON Schema object (`{'type': 'object', ...}`). Keep
/// schemas to the subset every provider accepts: `type`, `description`,
/// `properties`, `required`, `items` and `enum`.
class LlmTool {
  const LlmTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

/// A tool invocation requested by the model.
class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.malformedArguments,
    this.signature,
  });

  /// Provider-assigned id that links the call to its result.
  final String id;

  /// Name of the requested tool.
  final String name;

  /// Decoded arguments (empty when they could not be decoded).
  final Map<String, dynamic> arguments;

  /// The raw argument text when it was not a valid JSON object, so the
  /// tool layer can report the problem back to the model.
  final String? malformedArguments;

  /// Opaque provider data that must be echoed back with the call
  /// (Gemini's `thoughtSignature`).
  final String? signature;
}

/// The outcome of a tool call, sent back to the model.
class LlmToolResult {
  const LlmToolResult({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  /// The [LlmToolCall.id] this result answers.
  final String callId;

  /// The tool name (Gemini matches results by name).
  final String name;

  /// Plain-text result shown to the model.
  final String content;

  /// Whether the tool failed; [content] then explains why.
  final bool isError;
}

/// A single message in a completion request.
///
/// Plain conversation turns carry only [text]. Within a tool-use loop,
/// assistant messages may also carry the [toolCalls] the model made, and
/// the following user message carries their [toolResults].
class LlmMessage {
  const LlmMessage({
    required this.role,
    this.text = '',
    this.toolCalls = const [],
    this.toolResults = const [],
  });

  final LlmRole role;
  final String text;
  final List<LlmToolCall> toolCalls;
  final List<LlmToolResult> toolResults;
}

/// An event in a streamed model turn.
sealed class LlmEvent {
  const LlmEvent();
}

/// A chunk of reply text.
class LlmTextEvent extends LlmEvent {
  const LlmTextEvent(this.text);

  final String text;
}

/// A complete tool call (emitted once its arguments have fully arrived).
class LlmToolCallEvent extends LlmEvent {
  const LlmToolCallEvent(this.call);

  final LlmToolCall call;
}

/// Abstraction over a single LLM provider backend.
///
/// [streamTurn] streams one model turn as text chunks and tool calls;
/// [streamCompletion] is the text-only view of the same. Subclasses must
/// override at least one of the two (each defaults to the other).
/// Implementations throw [LlmException] (synchronously or as a stream
/// error) when the request cannot be made or fails. Callers should [close]
/// the client when done so underlying HTTP resources are released.
class LlmClient {
  /// Human-readable provider label (e.g. "OpenAI").
  String get label => throw UnimplementedError();

  /// Streams the assistant's reply text for [messages] under [systemPrompt].
  Stream<String> streamCompletion({
    required String systemPrompt,
    required List<LlmMessage> messages,
  }) =>
      streamTurn(systemPrompt: systemPrompt, messages: messages)
          .where((event) => event is LlmTextEvent)
          .map((event) => (event as LlmTextEvent).text);

  /// Streams one model turn for [messages] under [systemPrompt], offering
  /// the model [tools] it may call.
  ///
  /// Tool calls are emitted as [LlmToolCallEvent]s once complete; the
  /// caller runs them and continues the conversation with their results.
  Stream<LlmEvent> streamTurn({
    required String systemPrompt,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
  }) =>
      streamCompletion(systemPrompt: systemPrompt, messages: messages)
          .map(LlmTextEvent.new);

  /// Releases underlying resources (no-op for clients without them).
  void close() {}
}

/// Creates the right [LlmClient] for [provider].
///
/// [apiKey] is the stored API key for the provider, or `null` for local
/// providers that need none.
LlmClient createLlmClient({
  required LlmProvider provider,
  required String? apiKey,
}) {
  switch (provider.type) {
    case ProviderType.openai:
    case ProviderType.localOpenAi:
      return OpenAiClient(
        label: provider.type.label,
        endpoint: provider.effectiveEndpoint,
        apiKey: apiKey,
        model: provider.effectiveModel,
        requiresApiKey: provider.type.requiresApiKey,
      );
    case ProviderType.anthropic:
      return AnthropicClient(
        endpoint: provider.effectiveEndpoint,
        apiKey: apiKey,
        model: provider.effectiveModel,
      );
    case ProviderType.google:
      return GoogleClient(
        endpoint: provider.effectiveEndpoint,
        apiKey: apiKey,
        model: provider.effectiveModel,
      );
  }
}

/// Validates the pieces every client needs and throws a [LlmException]
/// with a [LlmErrorKind.config] when something is missing.
void _requireCommon({
  required String label,
  required String? endpoint,
  required String? model,
  required String? apiKey,
  required bool requiresApiKey,
}) {
  if (endpoint == null || endpoint.isEmpty) {
    throw const LlmException(
        LlmErrorKind.config, 'No API endpoint is configured.');
  }
  if (model == null || model.isEmpty) {
    throw LlmException(
        LlmErrorKind.config,
        'No model is configured for $label. Open Settings → Providers and '
        'set a model (e.g. gpt-4o-mini).');
  }
  if (requiresApiKey && (apiKey == null || apiKey.isEmpty)) {
    throw LlmException(
        LlmErrorKind.auth,
        'No API key is stored for $label. Open Settings → Providers and '
        'add one.');
  }
}

/// Yields the payload of each `data:` line of an SSE byte stream.
Stream<String> _sseDataLines(Stream<List<int>> bytes) async* {
  final lines = utf8.decoder.bind(bytes).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.startsWith('data:')) {
      final payload = line.substring(5).trimLeft();
      if (payload.isNotEmpty) yield payload;
    }
  }
}

/// Decodes one JSON object from an SSE payload, throwing a user-facing
/// [LlmException] when the payload is not valid JSON.
Map<String, dynamic> _decodeSseJson(String data, String label) {
  try {
    return jsonDecode(data) as Map<String, dynamic>;
  } on FormatException {
    throw LlmException(LlmErrorKind.api, '$label returned malformed data.');
  }
}

/// Maps an HTTP error status + body to a user-facing [LlmException].
LlmException _httpError(int status, String body, String label) {
  final message = _extractErrorMessage(body) ??
      (status == 401 || status == 403
          ? '$label rejected the API key (HTTP $status).'
          : '$label returned HTTP $status.');
  final kind =
      status == 401 || status == 403 ? LlmErrorKind.auth : LlmErrorKind.api;
  return LlmException(kind, message);
}

/// Pulls a human-readable message out of a provider error body, if present.
String? _extractErrorMessage(String body) {
  try {
    final json = jsonDecode(body);
    if (json is Map<String, dynamic>) {
      final error = json['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message'];
        if (message is String && message.isNotEmpty) return message;
      }
      final message = json['message'];
      if (message is String && message.isNotEmpty) return message;
    }
  } on FormatException {
    // Not JSON; fall through to the generic message.
  }
  return null;
}

/// Wraps low-level I/O failures into network [LlmException]s.
Never _rethrowNetwork(Object error, String label) {
  if (error is LlmException) throw error;
  throw LlmException(LlmErrorKind.network, 'Could not reach $label: $error');
}

/// Decodes a tool call's JSON argument text into an [LlmToolCall].
LlmToolCall _toolCallFromJson({
  required String id,
  required String name,
  required String argumentsJson,
}) {
  final raw = argumentsJson.trim();
  if (raw.isEmpty) {
    return LlmToolCall(id: id, name: name, arguments: const {});
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return LlmToolCall(id: id, name: name, arguments: decoded);
    }
  } on FormatException {
    // Reported below.
  }
  return LlmToolCall(
    id: id,
    name: name,
    arguments: const {},
    malformedArguments: raw,
  );
}

/// OpenAI Chat Completions client.
///
/// Serves both the hosted OpenAI API and any local OpenAI-compatible
/// endpoint (Ollama, LM Studio, llama.cpp, ...).
class OpenAiClient extends LlmClient {
  OpenAiClient({
    required this.label,
    required String? endpoint,
    required this.apiKey,
    required String? model,
    this.requiresApiKey = false,
    http.Client? httpClient,
  })  : _endpoint = endpoint,
        _model = model,
        _ownsHttp = httpClient == null,
        _http = httpClient ?? http.Client();

  @override
  final String label;

  /// Whether an API key is mandatory (hosted OpenAI: yes; local servers: no).
  final bool requiresApiKey;

  final String? _endpoint;
  final String? _model;
  final String? apiKey;
  final bool _ownsHttp;
  final http.Client _http;

  @override
  void close() {
    if (_ownsHttp) _http.close();
  }

  @override
  Stream<LlmEvent> streamTurn({
    required String systemPrompt,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
  }) async* {
    _requireCommon(
      label: label,
      endpoint: _endpoint,
      model: _model,
      apiKey: apiKey,
      requiresApiKey: requiresApiKey,
    );
    final url = Uri.parse('${_endpoint!}/chat/completions');
    final request = http.Request('POST', url)
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'model': _model,
        'stream': true,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          for (final m in messages) ..._encodeMessage(m),
        ],
        if (tools.isNotEmpty)
          'tools': [
            for (final tool in tools)
              {
                'type': 'function',
                'function': {
                  'name': tool.name,
                  'description': tool.description,
                  'parameters': tool.parameters,
                },
              },
          ],
      });
    final key = apiKey;
    if (key != null && key.isNotEmpty) {
      request.headers['authorization'] = 'Bearer $key';
    }

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (error) {
      _rethrowNetwork(error, label);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.transform(utf8.decoder).join();
      throw _httpError(response.statusCode, body, label);
    }

    // Tool calls arrive in fragments keyed by index; the arguments string
    // is streamed piecewise and only complete at the end of the turn.
    final pending = <int, ({String id, String name, StringBuffer args})>{};
    await for (final data in _sseDataLines(response.stream)) {
      if (data == '[DONE]') break;
      final json = _decodeSseJson(data, label);
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final delta = (choices.first as Map<String, dynamic>)['delta'];
      if (delta is! Map<String, dynamic>) continue;
      final content = delta['content'];
      if (content is String && content.isNotEmpty) yield LlmTextEvent(content);
      final toolCalls = delta['tool_calls'];
      if (toolCalls is! List) continue;
      for (final (position, call) in toolCalls.indexed) {
        if (call is! Map<String, dynamic>) continue;
        final index = call['index'] is int ? call['index'] as int : position;
        final function = call['function'];
        final fn = function is Map<String, dynamic> ? function : const {};
        final entry = pending.putIfAbsent(
          index,
          () => (
            id: call['id'] as String? ?? 'call_$index',
            name: fn['name'] as String? ?? '',
            args: StringBuffer(),
          ),
        );
        final args = fn['arguments'];
        if (args is String) entry.args.write(args);
      }
    }
    final indices = pending.keys.toList()..sort();
    for (final index in indices) {
      final entry = pending[index]!;
      yield LlmToolCallEvent(_toolCallFromJson(
        id: entry.id,
        name: entry.name,
        argumentsJson: entry.args.toString(),
      ));
    }
  }

  /// Encodes [m] as one or more Chat Completions messages (tool results
  /// become one `tool` message each).
  static List<Map<String, dynamic>> _encodeMessage(LlmMessage m) {
    if (m.toolResults.isNotEmpty) {
      return [
        for (final result in m.toolResults)
          {
            'role': 'tool',
            'tool_call_id': result.callId,
            'content':
                result.isError ? 'Error: ${result.content}' : result.content,
          },
        if (m.text.isNotEmpty) {'role': 'user', 'content': m.text},
      ];
    }
    if (m.toolCalls.isNotEmpty) {
      return [
        {
          'role': 'assistant',
          'content': m.text.isEmpty ? null : m.text,
          'tool_calls': [
            for (final call in m.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': jsonEncode(call.arguments),
                },
              },
          ],
        },
      ];
    }
    return [
      {
        'role': m.role == LlmRole.user ? 'user' : 'assistant',
        'content': m.text
      },
    ];
  }
}

/// Anthropic Messages API client.
class AnthropicClient extends LlmClient {
  AnthropicClient({
    required String? endpoint,
    required this.apiKey,
    required String? model,
    http.Client? httpClient,
  })  : _endpoint = endpoint,
        _model = model,
        _ownsHttp = httpClient == null,
        _http = httpClient ?? http.Client();

  static const String _apiVersion = '2023-06-01';
  static const int _defaultMaxTokens = 4096;

  final String? _endpoint;
  final String? _model;
  final String? apiKey;
  final bool _ownsHttp;
  final http.Client _http;

  @override
  String get label => 'Anthropic';

  @override
  void close() {
    if (_ownsHttp) _http.close();
  }

  @override
  Stream<LlmEvent> streamTurn({
    required String systemPrompt,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
  }) async* {
    _requireCommon(
      label: label,
      endpoint: _endpoint,
      model: _model,
      apiKey: apiKey,
      requiresApiKey: true,
    );
    final url = Uri.parse('${_endpoint!}/v1/messages');
    final request = http.Request('POST', url)
      ..headers['content-type'] = 'application/json'
      ..headers['x-api-key'] = apiKey!
      ..headers['anthropic-version'] = _apiVersion
      ..body = jsonEncode({
        'model': _model,
        'max_tokens': _defaultMaxTokens,
        'stream': true,
        'system': systemPrompt,
        'messages': [for (final m in messages) _encodeMessage(m)],
        if (tools.isNotEmpty)
          'tools': [
            for (final tool in tools)
              {
                'name': tool.name,
                'description': tool.description,
                'input_schema': tool.parameters,
              },
          ],
      });

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (error) {
      _rethrowNetwork(error, label);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.transform(utf8.decoder).join();
      throw _httpError(response.statusCode, body, label);
    }

    // tool_use blocks stream their input as partial JSON; a call is
    // complete when its content block stops.
    final pending = <int, ({String id, String name, StringBuffer args})>{};
    await for (final data in _sseDataLines(response.stream)) {
      final json = _decodeSseJson(data, label);
      final index = json['index'] is int ? json['index'] as int : 0;
      switch (json['type']) {
        case 'content_block_start':
          final block = json['content_block'];
          if (block is Map<String, dynamic> && block['type'] == 'tool_use') {
            pending[index] = (
              id: block['id'] as String? ?? 'toolu_$index',
              name: block['name'] as String? ?? '',
              args: StringBuffer(),
            );
          }
        case 'content_block_delta':
          final delta = json['delta'];
          if (delta is! Map<String, dynamic>) continue;
          if (delta['type'] == 'text_delta') {
            final text = delta['text'];
            if (text is String && text.isNotEmpty) yield LlmTextEvent(text);
          } else if (delta['type'] == 'input_json_delta') {
            final partial = delta['partial_json'];
            if (partial is String) pending[index]?.args.write(partial);
          }
        case 'content_block_stop':
          final entry = pending.remove(index);
          if (entry != null) {
            yield LlmToolCallEvent(_toolCallFromJson(
              id: entry.id,
              name: entry.name,
              argumentsJson: entry.args.toString(),
            ));
          }
      }
    }
  }

  /// Encodes [m] as a Messages API message with content blocks when it
  /// carries tool calls or results.
  static Map<String, dynamic> _encodeMessage(LlmMessage m) {
    final role = m.role == LlmRole.user ? 'user' : 'assistant';
    if (m.toolCalls.isEmpty && m.toolResults.isEmpty) {
      return {'role': role, 'content': m.text};
    }
    return {
      'role': role,
      'content': [
        for (final result in m.toolResults)
          {
            'type': 'tool_result',
            'tool_use_id': result.callId,
            'content': result.content,
            if (result.isError) 'is_error': true,
          },
        // Empty text blocks are rejected by the API.
        if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
        for (final call in m.toolCalls)
          {
            'type': 'tool_use',
            'id': call.id,
            'name': call.name,
            'input': call.arguments,
          },
      ],
    };
  }
}

/// Google Gemini (Generative Language API) client.
class GoogleClient extends LlmClient {
  GoogleClient({
    required String? endpoint,
    required this.apiKey,
    required String? model,
    http.Client? httpClient,
  })  : _endpoint = endpoint,
        _model = model,
        _ownsHttp = httpClient == null,
        _http = httpClient ?? http.Client();

  final String? _endpoint;
  final String? _model;
  final String? apiKey;
  final bool _ownsHttp;
  final http.Client _http;

  @override
  String get label => 'Google';

  @override
  void close() {
    if (_ownsHttp) _http.close();
  }

  @override
  Stream<LlmEvent> streamTurn({
    required String systemPrompt,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
  }) async* {
    _requireCommon(
      label: label,
      endpoint: _endpoint,
      model: _model,
      apiKey: apiKey,
      requiresApiKey: true,
    );
    final url = Uri.parse(
      '${_endpoint!}/models/$_model:streamGenerateContent?alt=sse',
    );
    final request = http.Request('POST', url)
      ..headers['content-type'] = 'application/json'
      ..headers['x-goog-api-key'] = apiKey!
      ..body = jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt}
          ]
        },
        'contents': [for (final m in messages) _encodeMessage(m)],
        if (tools.isNotEmpty)
          'tools': [
            {
              'functionDeclarations': [
                for (final tool in tools)
                  {
                    'name': tool.name,
                    'description': tool.description,
                    'parameters': tool.parameters,
                  },
              ],
            },
          ],
      });

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (error) {
      _rethrowNetwork(error, label);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.transform(utf8.decoder).join();
      throw _httpError(response.statusCode, body, label);
    }

    var callCount = 0;
    await for (final data in _sseDataLines(response.stream)) {
      final json = _decodeSseJson(data, label);
      final candidates = json['candidates'];
      if (candidates is! List || candidates.isEmpty) continue;
      final content = (candidates.first as Map<String, dynamic>)['content'];
      if (content is! Map<String, dynamic>) continue;
      final parts = content['parts'];
      if (parts is! List) continue;
      for (final part in parts) {
        if (part is! Map<String, dynamic>) continue;
        final text = part['text'];
        if (text is String && text.isNotEmpty && part['thought'] != true) {
          yield LlmTextEvent(text);
        }
        // Gemini sends each function call complete, in a single part.
        final call = part['functionCall'];
        if (call is Map<String, dynamic>) {
          final args = call['args'];
          yield LlmToolCallEvent(LlmToolCall(
            id: call['id'] as String? ?? 'call_${callCount++}',
            name: call['name'] as String? ?? '',
            arguments: args is Map<String, dynamic> ? args : const {},
            signature: part['thoughtSignature'] as String?,
          ));
        }
      }
    }
  }

  /// Encodes [m] as a `contents` entry with function call / response
  /// parts when it carries tool calls or results.
  static Map<String, dynamic> _encodeMessage(LlmMessage m) {
    return {
      'role': m.role == LlmRole.user ? 'user' : 'model',
      'parts': [
        for (final result in m.toolResults)
          {
            'functionResponse': {
              'name': result.name,
              'response': result.isError
                  ? {'error': result.content}
                  : {'result': result.content},
            },
          },
        if (m.text.isNotEmpty || (m.toolCalls.isEmpty && m.toolResults.isEmpty))
          {'text': m.text},
        for (final call in m.toolCalls)
          {
            'functionCall': {'name': call.name, 'args': call.arguments},
            if (call.signature != null) 'thoughtSignature': call.signature,
          },
      ],
    };
  }
}
