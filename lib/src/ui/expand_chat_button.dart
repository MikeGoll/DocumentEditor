import 'package:flutter/material.dart';

/// Floating button shown on narrow screens to expand the collapsed chat pane.
///
/// When [onPressed] is null the button is disabled (e.g. the chat overlay
/// is already open).
class ExpandChatButton extends StatelessWidget {
  const ExpandChatButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        elevation: 2,
        child: IconButton(
          onPressed: onPressed,
          icon: const Icon(Icons.forum_outlined),
          tooltip: 'Expand chat',
          iconSize: 28,
        ),
      ),
    );
  }
}
