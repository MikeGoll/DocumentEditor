import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_message.dart';

/// The agent chat pane (right side of the app).
///
/// On wide windows this sits side-by-side with the document viewer. On
/// narrow windows it is shown as an overlay driven by [MainLayout] and an
/// [onClose] callback lets the user dismiss the overlay.
///
/// Messages are stored locally per document via [ChatController]; no LLM
/// connectivity is required.
class AgentChatPane extends StatefulWidget {
  const AgentChatPane({
    super.key,
    required this.chat,
    this.onClose,
  });

  /// Chat state for the current document.
  final ChatController chat;

  /// When non-null a close button is shown (overlay mode on narrow screens).
  final VoidCallback? onClose;

  @override
  State<AgentChatPane> createState() => _AgentChatPaneState();
}

class _AgentChatPaneState extends State<AgentChatPane> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          height: 48,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.dividerColor),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Agent Chat',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => widget.chat.reset(),
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Reset chat',
                visualDensity: VisualDensity.compact,
              ),
              if (widget.onClose != null)
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close chat',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.chat,
            builder: (context, _) => widget.chat.messages.isEmpty
                ? const _ChatEmptyState()
                : _MessageList(messages: widget.chat.messages),
          ),
        ),
        _ChatInputBar(chat: widget.chat),
      ],
    );
  }
}

/// Placeholder shown when the conversation is empty.
class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 40, color: theme.disabledColor),
            const SizedBox(height: 12),
            Text(
              'No messages yet',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Type a message below to start a local conversation.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.disabledColor),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scrollable list of chat bubbles, newest at the bottom.
///
/// Owns its [ScrollController] and auto-scrolls to the latest message
/// whenever new messages arrive.
class _MessageList extends StatefulWidget {
  const _MessageList({required this.messages});

  final List<ChatMessage> messages;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final ScrollController _scroll = ScrollController();
  int _lastCount = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Auto-scroll to the latest message when new ones arrive.
    if (widget.messages.length != _lastCount) {
      _lastCount = widget.messages.length;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: widget.messages.length,
      itemBuilder: (context, index) =>
          _MessageBubble(message: widget.messages[index]),
    );
  }
}

/// A single message bubble: user messages align right in the primary color,
/// agent messages align left in a neutral surface.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatRole.user;
    final scheme = theme.colorScheme;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isUser ? scheme.onPrimaryContainer : null,
              ),
            ),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _formatTime(message.timestamp),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.disabledColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Bottom input row: a text field plus a send button.
///
/// Enter (or the send button) submits the message to [chat].
class _ChatInputBar extends StatefulWidget {
  const _ChatInputBar({required this.chat});

  final ChatController chat;

  @override
  State<_ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<_ChatInputBar> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    widget.chat.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('chat-input'),
              controller: _controller,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                hintText: 'Type a message…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('chat-send'),
            onPressed: _submit,
            icon: const Icon(Icons.send),
            tooltip: 'Send message',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
