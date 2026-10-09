import '../llm/llm_client.dart';

/// What a tool produced: text for the model plus a one-line [summary] for
/// the chat transcript.
class ToolOutcome {
  const ToolOutcome({
    required this.content,
    required this.summary,
    this.isError = false,
  });

  /// A failed call; [content] tells the model what went wrong.
  const ToolOutcome.error(this.content, {required this.summary})
      : isError = true;

  /// Result text sent back to the model.
  final String content;

  /// Short, user-facing description of what happened (e.g. "Edited the
  /// document (2 changes)").
  final String summary;

  /// Whether the call failed.
  final bool isError;
}

/// An action the agent can take, exposed to the LLM via function calling.
abstract class AgentTool {
  /// Name, description and JSON schema sent to the provider.
  LlmTool get definition;

  /// Runs the tool with the model-supplied [arguments].
  ///
  /// Implementations may throw [ToolArgumentException] for invalid input;
  /// any other failure should be returned as [ToolOutcome.error].
  Future<ToolOutcome> execute(Map<String, dynamic> arguments);
}

/// Invalid arguments supplied by the model.
class ToolArgumentException implements Exception {
  const ToolArgumentException(this.message);

  final String message;

  @override
  String toString() => 'ToolArgumentException: $message';
}

/// The result of running one tool call through a [ToolRegistry].
class ToolExecution {
  const ToolExecution({required this.result, required this.summary});

  /// Sent back to the model.
  final LlmToolResult result;

  /// Shown in the chat transcript.
  final String summary;
}

/// The set of tools offered to the agent, looked up by name.
class ToolRegistry {
  ToolRegistry([Iterable<AgentTool> tools = const []]) {
    tools.forEach(register);
  }

  final Map<String, AgentTool> _tools = {};

  /// Adds [tool], replacing any tool with the same name.
  void register(AgentTool tool) => _tools[tool.definition.name] = tool;

  /// Tool definitions for the LLM request, in registration order.
  List<LlmTool> get definitions =>
      [for (final tool in _tools.values) tool.definition];

  bool get isEmpty => _tools.isEmpty;

  /// Runs [call] and converts every failure mode (unknown tool, malformed
  /// arguments, tool errors) into an error result the model can act on.
  /// Never throws.
  Future<ToolExecution> execute(LlmToolCall call) async {
    ToolOutcome outcome;
    final tool = _tools[call.name];
    if (tool == null) {
      outcome = ToolOutcome.error(
        'Unknown tool "${call.name}". Available tools: '
        '${_tools.keys.join(', ')}.',
        summary: 'Agent requested an unknown tool (${call.name})',
      );
    } else if (call.malformedArguments != null) {
      outcome = ToolOutcome.error(
        'The arguments were not a valid JSON object. Retry with valid JSON.',
        summary: 'Agent sent invalid arguments to ${call.name}',
      );
    } else {
      try {
        outcome = await tool.execute(call.arguments);
      } on ToolArgumentException catch (error) {
        outcome = ToolOutcome.error(
          'Invalid arguments: ${error.message}',
          summary: 'Agent sent invalid arguments to ${call.name}',
        );
      } catch (error) {
        outcome = ToolOutcome.error(
          'The tool failed: $error',
          summary: '${call.name} failed',
        );
      }
    }
    return ToolExecution(
      result: LlmToolResult(
        callId: call.id,
        name: call.name,
        content: outcome.content,
        isError: outcome.isError,
      ),
      summary: outcome.summary,
    );
  }
}

/// Reads a required string argument.
String requireString(Map<String, dynamic> arguments, String key) {
  final value = arguments[key];
  if (value is String) return value;
  throw ToolArgumentException('"$key" must be a string.');
}

/// Reads an optional non-negative integer argument (models sometimes send
/// whole numbers as doubles).
int? optionalInt(Map<String, dynamic> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is num && value == value.roundToDouble() && value >= 0) {
    return value.toInt();
  }
  throw ToolArgumentException('"$key" must be a non-negative integer.');
}

/// Returns at most [maxChars] of [text] starting at [offset], with a note
/// telling the model how to fetch the rest.
String pageText(String text, {required int offset, required int maxChars}) {
  if (offset >= text.length && text.isNotEmpty) {
    return '[offset $offset is past the end; the text has ${text.length} '
        'characters]';
  }
  final end = offset + maxChars < text.length ? offset + maxChars : text.length;
  final page = text.substring(offset, end);
  if (offset == 0 && end == text.length) return page;
  final note = end < text.length
      ? 'Showing characters $offset-$end of ${text.length}. Call again with '
          'offset $end to continue.'
      : 'Showing characters $offset-$end of ${text.length} (end of text).';
  return '$page\n\n[$note]';
}
