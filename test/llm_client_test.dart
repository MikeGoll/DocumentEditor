import 'dart:convert';
import 'dart:io';

import 'package:document_editor/src/config/llm_provider.dart';
import 'package:document_editor/src/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Boots a local [HttpServer] that records requests and replies with a
/// canned body, so provider clients can be exercised without real APIs.
class _MockServer {
  _MockServer(this.server, this.port);

  final HttpServer server;
  final int port;
  final List<HttpRequest> requests = [];

  /// Raw request bodies, in order.
  final List<String> bodies = [];

  String get endpoint => 'http://127.0.0.1:$port';

  /// Decoded JSON body of the most recent request.
  Map<String, dynamic> get lastBody =>
      jsonDecode(bodies.last) as Map<String, dynamic>;

  /// Canned response for every request; [status] defaults to 200.
  void respond(String body, {int status = 200, String contentType = 'text/plain'}) {
    server.listen((request) async {
      final chunks = <int>[];
      await for (final chunk in request) {
        chunks.addAll(chunk);
      }
      requests.add(request);
      bodies.add(utf8.decode(chunks));
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.parse(contentType)
        ..write(body);
      await request.response.close();
    });
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}

Future<_MockServer> _startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  return _MockServer(server, server.port);
}

void main() {
  group('OpenAiClient', () {
    late _MockServer server;

    LlmClient client({String? model = 'gpt-4o-mini', String? apiKey = 'sk-test'}) {
      return OpenAiClient(
        label: 'OpenAI',
        endpoint: '${server.endpoint}/v1',
        apiKey: apiKey,
        model: model,
      );
    }

    setUp(() async {
      server = await _startServer();
    });

    tearDown(() async {
      await server.close();
    });

    test('streams chat completion chunks from SSE data lines', () async {
      server.respond(
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"lo"}}]}\n\n'
        'data: [DONE]\n\n',
        contentType: 'text/event-stream',
      );

      final chunks = await client().streamCompletion(
        systemPrompt: 'You are helpful.',
        messages: const [LlmMessage(role: LlmRole.user, text: 'Hi')],
      ).toList();

      expect(chunks, ['Hel', 'lo']);
    });

    test('sends system prompt, model and bearer key', () async {
      server.respond('data: [DONE]\n\n', contentType: 'text/event-stream');

      await client().streamCompletion(
        systemPrompt: 'SYS',
        messages: const [
          LlmMessage(role: LlmRole.user, text: 'u'),
          LlmMessage(role: LlmRole.assistant, text: 'a'),
        ],
      ).toList();

      final request = server.requests.single;
      expect(request.uri.path, '/v1/chat/completions');
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(request.headers.value('authorization'), 'Bearer sk-test');

      final body = server.lastBody;
      expect(body['model'], 'gpt-4o-mini');
      expect(body['stream'], true);
      expect(
        body['messages'],
        [
          {'role': 'system', 'content': 'SYS'},
          {'role': 'user', 'content': 'u'},
          {'role': 'assistant', 'content': 'a'},
        ],
      );
    });

    test('works without an API key for local endpoints', () async {
      server.respond('data: [DONE]\n\n', contentType: 'text/event-stream');

      final chunks = await client(apiKey: null).streamCompletion(
        systemPrompt: 'SYS',
        messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
      ).toList();

      expect(chunks, isEmpty);
      expect(server.requests.single.headers.value('authorization'), isNull);
    });

    test('maps 401 with an error body to an auth exception', () async {
      server.respond(
        jsonEncode({'error': {'message': 'Invalid API key'}}),
        status: 401,
        contentType: 'application/json',
      );

      await expectLater(
        client().streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.auth)
              .having((e) => e.message, 'message', 'Invalid API key'),
        ),
      );
    });

    test('maps 400 to an api exception with the provider message', () async {
      server.respond(
        jsonEncode({'error': {'message': 'model not found'}}),
        status: 400,
        contentType: 'application/json',
      );

      await expectLater(
        client().streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.api)
              .having((e) => e.message, 'message', 'model not found'),
        ),
      );
    });

    test('maps connection failure to a network exception', () async {
      // Point at a port with nothing listening.
      final closed = await _startServer();
      final deadPort = closed.port;
      await closed.close();

      final client = OpenAiClient(
        label: 'Local',
        endpoint: 'http://127.0.0.1:$deadPort/v1',
        apiKey: null,
        model: 'llama3',
      );

      await expectLater(
        client.streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.network)),
      );
    });

    test('throws a config exception when no model is set', () async {
      await expectLater(
        client(model: null).streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.config)),
      );
    });
  });

  group('AnthropicClient', () {
    late _MockServer server;

    LlmClient client({String? model = 'claude-sonnet-4-5', String? apiKey = 'sk-ant'}) {
      return AnthropicClient(endpoint: server.endpoint, apiKey: apiKey, model: model);
    }

    setUp(() async {
      server = await _startServer();
    });

    tearDown(() async {
      await server.close();
    });

    test('streams text deltas and ignores other event types', () async {
      server.respond(
        'event: message_start\n'
        'data: {"type":"message_start","message":{"id":"m1"}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Bon"}}\n\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"jour"}}\n\n'
        'event: message_stop\n'
        'data: {"type":"message_stop"}\n\n',
        contentType: 'text/event-stream',
      );

      final chunks = await client().streamCompletion(
        systemPrompt: 'SYS',
        messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
      ).toList();

      expect(chunks, ['Bon', 'jour']);
    });

    test('sends x-api-key, version header and system prompt', () async {
      server.respond('data: {"type":"message_stop"}\n\n',
          contentType: 'text/event-stream');

      await client().streamCompletion(
        systemPrompt: 'SYS',
        messages: const [
          LlmMessage(role: LlmRole.user, text: 'u'),
          LlmMessage(role: LlmRole.assistant, text: 'a'),
        ],
      ).toList();

      final request = server.requests.single;
      expect(request.uri.path, '/v1/messages');
      expect(request.headers.value('x-api-key'), 'sk-ant');
      expect(request.headers.value('anthropic-version'), isNotNull);
      expect(request.headers.contentType?.mimeType, 'application/json');

      final body = server.lastBody;
      expect(body['model'], 'claude-sonnet-4-5');
      expect(body['stream'], true);
      expect(body['system'], 'SYS');
      expect(body['max_tokens'], greaterThan(0));
      expect(
        body['messages'],
        [
          {'role': 'user', 'content': 'u'},
          {'role': 'assistant', 'content': 'a'},
        ],
      );
    });

    test('throws an auth exception when no API key is stored', () async {
      await expectLater(
        client(apiKey: null).streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.auth)),
      );
    });

    test('maps a 401 error body to an auth exception', () async {
      server.respond(
        jsonEncode({'type': 'error', 'error': {'message': 'invalid x-api-key'}}),
        status: 401,
        contentType: 'application/json',
      );

      await expectLater(
        client().streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.auth)
              .having((e) => e.message, 'message', 'invalid x-api-key'),
        ),
      );
    });
  });

  group('GoogleClient', () {
    late _MockServer server;

    LlmClient client({String? model = 'gemini-2.0-flash', String? apiKey = 'g-key'}) {
      return GoogleClient(endpoint: '${server.endpoint}/v1beta', apiKey: apiKey, model: model);
    }

    setUp(() async {
      server = await _startServer();
    });

    tearDown(() async {
      await server.close();
    });

    test('streams candidate parts from SSE data lines', () async {
      server.respond(
        'data: {"candidates":[{"content":{"parts":[{"text":"He"}]}}]}\n\n'
        'data: {"candidates":[{"content":{"parts":[{"text":"y"}]}}]}\n\n'
        'data: {"candidates":[{"content":{"parts":[]},"finishReason":"STOP"}]}\n\n',
        contentType: 'text/event-stream',
      );

      final chunks = await client().streamCompletion(
        systemPrompt: 'SYS',
        messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
      ).toList();

      expect(chunks, ['He', 'y']);
    });

    test('targets the model stream endpoint with the API key header', () async {
      server.respond('data: {}\n\n', contentType: 'text/event-stream');

      await client().streamCompletion(
        systemPrompt: 'SYS',
        messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
      ).toList();

      final request = server.requests.single;
      expect(request.uri.path, '/v1beta/models/gemini-2.0-flash:streamGenerateContent');
      expect(request.uri.queryParameters['alt'], 'sse');
      expect(request.headers.value('x-goog-api-key'), 'g-key');

      final body = server.lastBody;
      expect(body['systemInstruction'], {'parts': [{'text': 'SYS'}]});
      expect(
        body['contents'],
        [
          {'role': 'user', 'parts': [{'text': 'u'}]},
        ],
      );
    });

    test('throws an auth exception when no API key is stored', () async {
      await expectLater(
        client(apiKey: null).streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.auth)),
      );
    });

    test('maps a 403 error body to an auth exception', () async {
      server.respond(
        jsonEncode({'error': {'code': 403, 'message': 'API key not valid'}}),
        status: 403,
        contentType: 'application/json',
      );

      await expectLater(
        client().streamCompletion(
          systemPrompt: 'SYS',
          messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        ).toList(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.kind, 'kind', LlmErrorKind.auth)
              .having((e) => e.message, 'message', 'API key not valid'),
        ),
      );
    });
  });

  group('createLlmClient', () {
    test('creates the right client for each provider type', () {
      LlmClient forType(ProviderType type) => createLlmClient(
            provider: LlmProvider(
              id: 'p',
              name: 'n',
              type: type,
              endpoint: 'http://127.0.0.1:1',
              model: 'm',
            ),
            apiKey: 'k',
          );

      expect(forType(ProviderType.openai), isA<OpenAiClient>());
      expect(forType(ProviderType.localOpenAi), isA<OpenAiClient>());
      expect(forType(ProviderType.anthropic), isA<AnthropicClient>());
      expect(forType(ProviderType.google), isA<GoogleClient>());
    });
  });

  group('tool calling', () {
    late _MockServer server;

    const tool = LlmTool(
      name: 'write_document',
      description: 'Edits the document.',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    );

    // A prior tool round, replayed in the next request.
    const toolRound = [
      LlmMessage(role: LlmRole.user, text: 'Edit it'),
      LlmMessage(
        role: LlmRole.assistant,
        text: 'Editing.',
        toolCalls: [
          LlmToolCall(
            id: 'call_1',
            name: 'write_document',
            arguments: {'text': 'hi'},
            signature: 'sig-1',
          ),
        ],
      ),
      LlmMessage(
        role: LlmRole.user,
        toolResults: [
          LlmToolResult(
            callId: 'call_1',
            name: 'write_document',
            content: 'Text not found.',
            isError: true,
          ),
        ],
      ),
    ];

    setUp(() async {
      server = await _startServer();
    });

    tearDown(() async {
      await server.close();
    });

    test('OpenAI: assembles streamed tool call fragments', () async {
      server.respond(
        'data: {"choices":[{"delta":{"content":"Sure."}}]}\n\n'
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9",'
        '"type":"function","function":{"name":"write_document","arguments":""}}]}}]}\n\n'
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
        '"function":{"arguments":"{\\"text\\":"}}]}}]}\n\n'
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
        '"function":{"arguments":"\\"hello\\"}"}}]}}]}\n\n'
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n'
        'data: [DONE]\n\n',
        contentType: 'text/event-stream',
      );

      final events = await OpenAiClient(
        label: 'OpenAI',
        endpoint: '${server.endpoint}/v1',
        apiKey: 'sk',
        model: 'gpt',
      ).streamTurn(
        systemPrompt: 'SYS',
        messages: toolRound,
        tools: const [tool],
      ).toList();

      expect((events.first as LlmTextEvent).text, 'Sure.');
      final call = (events.last as LlmToolCallEvent).call;
      expect(call.id, 'call_9');
      expect(call.name, 'write_document');
      expect(call.arguments, {'text': 'hello'});

      final body = server.lastBody;
      expect(body['tools'], [
        {
          'type': 'function',
          'function': {
            'name': 'write_document',
            'description': 'Edits the document.',
            'parameters': tool.parameters,
          },
        },
      ]);
      final messages = body['messages'] as List;
      expect(messages[2], {
        'role': 'assistant',
        'content': 'Editing.',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {
              'name': 'write_document',
              'arguments': '{"text":"hi"}',
            },
          },
        ],
      });
      expect(messages[3], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'Error: Text not found.',
      });
    });

    test('OpenAI: flags malformed tool arguments', () async {
      server.respond(
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c",'
        '"function":{"name":"write_document","arguments":"{oops"}}]}}]}\n\n'
        'data: [DONE]\n\n',
        contentType: 'text/event-stream',
      );

      final events = await OpenAiClient(
        label: 'OpenAI',
        endpoint: '${server.endpoint}/v1',
        apiKey: 'sk',
        model: 'gpt',
      ).streamTurn(
        systemPrompt: 'SYS',
        messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
        tools: const [tool],
      ).toList();

      final call = (events.single as LlmToolCallEvent).call;
      expect(call.malformedArguments, '{oops');
      expect(call.arguments, isEmpty);
    });

    test('OpenAI: omits tools when none are offered', () async {
      server.respond('data: [DONE]\n\n', contentType: 'text/event-stream');

      await OpenAiClient(
        label: 'OpenAI',
        endpoint: '${server.endpoint}/v1',
        apiKey: 'sk',
        model: 'gpt',
      ).streamCompletion(
        systemPrompt: 'SYS',
        messages: const [LlmMessage(role: LlmRole.user, text: 'u')],
      ).toList();

      expect(server.lastBody.containsKey('tools'), isFalse);
    });

    test('Anthropic: assembles tool_use blocks from input_json_delta',
        () async {
      server.respond(
        'data: {"type":"content_block_start","index":0,'
        '"content_block":{"type":"text","text":""}}\n\n'
        'data: {"type":"content_block_delta","index":0,'
        '"delta":{"type":"text_delta","text":"On it."}}\n\n'
        'data: {"type":"content_block_stop","index":0}\n\n'
        'data: {"type":"content_block_start","index":1,"content_block":'
        '{"type":"tool_use","id":"toolu_1","name":"write_document","input":{}}}\n\n'
        'data: {"type":"content_block_delta","index":1,'
        '"delta":{"type":"input_json_delta","partial_json":"{\\"text\\": \\"he"}}\n\n'
        'data: {"type":"content_block_delta","index":1,'
        '"delta":{"type":"input_json_delta","partial_json":"llo\\"}"}}\n\n'
        'data: {"type":"content_block_stop","index":1}\n\n'
        'data: {"type":"message_stop"}\n\n',
        contentType: 'text/event-stream',
      );

      final events = await AnthropicClient(
        endpoint: server.endpoint,
        apiKey: 'sk-ant',
        model: 'claude',
      ).streamTurn(
        systemPrompt: 'SYS',
        messages: toolRound,
        tools: const [tool],
      ).toList();

      expect((events.first as LlmTextEvent).text, 'On it.');
      final call = (events.last as LlmToolCallEvent).call;
      expect(call.id, 'toolu_1');
      expect(call.arguments, {'text': 'hello'});

      final body = server.lastBody;
      expect(body['tools'], [
        {
          'name': 'write_document',
          'description': 'Edits the document.',
          'input_schema': tool.parameters,
        },
      ]);
      final messages = body['messages'] as List;
      expect(messages[1], {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Editing.'},
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'write_document',
            'input': {'text': 'hi'},
          },
        ],
      });
      expect(messages[2], {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'content': 'Text not found.',
            'is_error': true,
          },
        ],
      });
    });

    test('Google: emits function calls and replays thought signatures',
        () async {
      server.respond(
        'data: {"candidates":[{"content":{"role":"model","parts":['
        '{"text":"Okay."},'
        '{"functionCall":{"name":"write_document","args":{"text":"hello"}},'
        '"thoughtSignature":"sig-9"}]}}]}\n\n',
        contentType: 'text/event-stream',
      );

      final events = await GoogleClient(
        endpoint: server.endpoint,
        apiKey: 'g-key',
        model: 'gemini',
      ).streamTurn(
        systemPrompt: 'SYS',
        messages: toolRound,
        tools: const [tool],
      ).toList();

      expect((events.first as LlmTextEvent).text, 'Okay.');
      final call = (events.last as LlmToolCallEvent).call;
      expect(call.name, 'write_document');
      expect(call.arguments, {'text': 'hello'});
      expect(call.signature, 'sig-9');

      final body = server.lastBody;
      expect(body['tools'], [
        {
          'functionDeclarations': [
            {
              'name': 'write_document',
              'description': 'Edits the document.',
              'parameters': tool.parameters,
            },
          ],
        },
      ]);
      final contents = body['contents'] as List;
      expect(contents[1], {
        'role': 'model',
        'parts': [
          {'text': 'Editing.'},
          {
            'functionCall': {
              'name': 'write_document',
              'args': {'text': 'hi'},
            },
            'thoughtSignature': 'sig-1',
          },
        ],
      });
      expect(contents[2], {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'write_document',
              'response': {'error': 'Text not found.'},
            },
          },
        ],
      });
    });
  });
}
