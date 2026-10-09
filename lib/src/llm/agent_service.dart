import '../chat/chat_message.dart';
import '../config/agent_config_controller.dart';
import '../config/llm_provider.dart';
import '../documents/document_state.dart';
import '../tools/supporting_files.dart';
import '../tools/tool_registry.dart';
import 'llm_client.dart';
import 'system_prompt.dart';

/// Creates an [LlmClient] for a provider; injectable for tests.
typedef LlmClientFactory = LlmClient Function({
  required LlmProvider provider,
  required String? apiKey,
});

/// Connects the chat to the active LLM provider.
///
/// [respond] gathers the agent context (system prompt, document content,
/// comments, translation table, recent chat history), streams the provider's
/// reply through [onChunk], and reports failures through [onError] with a
/// user-facing message. It never throws: every failure mode is delivered
/// via [onError] so the chat UI can always recover.
///
/// When [tools] are registered, the agent runs a tool-use loop: tool calls
/// the model makes are executed locally (each reported via
/// `onToolActivity`) and their results sent back, until the model answers
/// without calling a tool or [maxToolRounds] is reached.
class AgentService {
  AgentService({
    required AgentConfigController config,
    required DocumentState document,
    LlmClientFactory clientFactory = createLlmClient,
    int maxHistoryMessages = 20,
    int maxDocumentChars = 24000,
    List<String> Function()? commentsProvider,
    ToolRegistry? tools,
    SupportingFiles? supportingFiles,
    this.maxToolRounds = 10,
  })  : _config = config,
        _document = document,
        _clientFactory = clientFactory,
        _maxHistoryMessages = maxHistoryMessages,
        _maxDocumentChars = maxDocumentChars,
        _commentsProvider = commentsProvider,
        _tools = tools ?? ToolRegistry(),
        _supportingFiles = supportingFiles;

  final AgentConfigController _config;
  final DocumentState _document;
  final LlmClientFactory _clientFactory;
  final int _maxHistoryMessages;
  final int _maxDocumentChars;
  final List<String> Function()? _commentsProvider;
  final ToolRegistry _tools;
  final SupportingFiles? _supportingFiles;

  /// Upper bound on model turns per reply, so a model stuck calling tools
  /// cannot loop forever.
  final int maxToolRounds;

  /// Streams an agent reply for the conversation in [history].
  ///
  /// [history] must include the user's newest message. Reply text is
  /// delivered incrementally via [onChunk]; each tool the agent runs is
  /// reported once via [onToolActivity] with a short summary. When the
  /// stream completes successfully no further callbacks fire. Any failure
  /// (missing provider, bad credentials, network error, provider error) is
  /// reported once through [onError].
  ///
  /// [isCancelled] is polled between steps; once it returns true no further
  /// tools run and no more callbacks fire.
  Future<void> respond({
    required List<ChatMessage> history,
    required void Function(String chunk) onChunk,
    required void Function(String error) onError,
    void Function(String summary)? onToolActivity,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;
    try {
      final agentConfig = _config.config;
      final provider = agentConfig.activeProvider;
      if (provider == null) {
        onError(
          'No LLM provider is configured. Open Settings → Providers and '
          'add one, then try again.',
        );
        return;
      }

      final apiKey = await _config.readApiKey(provider.id);
      final client = _clientFactory(provider: provider, apiKey: apiKey);
      final tools = _tools.definitions;

      final recent = _recentMessages(history);
      final messages = [
        for (final message in recent)
          LlmMessage(
            role: message.role == ChatRole.user ? LlmRole.user : LlmRole.assistant,
            text: message.text,
          ),
      ];

      try {
        for (var round = 0; round < maxToolRounds; round++) {
          if (cancelled()) return;
          // Rebuilt every round so the snapshot reflects edits made by the
          // agent's own tools and by the user in the meantime.
          final systemPrompt = buildAgentSystemPrompt(
            config: agentConfig,
            documentName: _document.fileName,
            documentContent: _document.hasDocument
                ? _document.quill.document.toPlainText()
                : null,
            comments: _commentsProvider?.call() ?? const [],
            tools: tools,
            supportingFiles: _supportingFiles?.displayNames ?? const [],
            maxDocumentChars: _maxDocumentChars,
          );

          final reply = StringBuffer();
          final calls = <LlmToolCall>[];
          await for (final event in client.streamTurn(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: tools,
          )) {
            if (cancelled()) return;
            switch (event) {
              case LlmTextEvent(:final text) when text.isNotEmpty:
                onChunk(text);
                reply.write(text);
              case LlmTextEvent():
                break;
              case LlmToolCallEvent(:final call):
                calls.add(call);
            }
          }
          if (calls.isEmpty) return;

          messages.add(LlmMessage(
            role: LlmRole.assistant,
            text: reply.toString(),
            toolCalls: calls,
          ));
          final results = <LlmToolResult>[];
          for (final call in calls) {
            if (cancelled()) return;
            final execution = await _tools.execute(call);
            onToolActivity?.call(execution.summary);
            results.add(execution.result);
          }
          messages.add(LlmMessage(role: LlmRole.user, toolResults: results));
        }
        if (!cancelled()) {
          onError(
            'The agent stopped after $maxToolRounds rounds of tool use '
            'without finishing. Try a narrower request.',
          );
        }
      } finally {
        client.close();
      }
    } on LlmException catch (error) {
      if (!cancelled()) onError(error.message);
    } catch (error) {
      if (!cancelled()) onError('Unexpected error while contacting the LLM: $error');
    }
  }

  /// The tail of [history] that fits the context budget, in order.
  List<ChatMessage> _recentMessages(List<ChatMessage> history) {
    // Tool activity entries are transcript-only; the model sees the
    // conversation text (and the current document) instead.
    final nonEmpty = history
        .where((m) => m.role != ChatRole.tool && m.text.trim().isNotEmpty)
        .toList();
    if (nonEmpty.length <= _maxHistoryMessages) return nonEmpty;
    return nonEmpty.sublist(nonEmpty.length - _maxHistoryMessages);
  }
}
