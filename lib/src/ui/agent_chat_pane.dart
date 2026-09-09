import 'package:flutter/material.dart';
import 'package:document_editor/src/ui/pane_placeholder.dart';

/// Placeholder for the agent chat pane (right side of the app).
///
/// On wide windows this sits side-by-side with the document viewer. On
/// narrow windows it is shown as an overlay driven by [MainLayout] and an
/// [onClose] callback lets the user dismiss the overlay.
class AgentChatPane extends StatelessWidget {
  const AgentChatPane({super.key, this.onClose});

  /// When non-null a close button is shown (overlay mode on narrow screens).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Header with pane title and (in overlay mode) a close button.
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
              if (onClose != null)
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close chat',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        const Expanded(
          child: PanePlaceholder(
            icon: Icons.smart_toy_outlined,
            label: 'Agent chat',
            hint: 'Chat history and agent responses will appear here.',
          ),
        ),
      ],
    );
  }
}
