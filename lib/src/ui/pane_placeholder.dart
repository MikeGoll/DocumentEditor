import 'package:flutter/material.dart';

/// Simple centered placeholder used by the panes until real content lands.
class PanePlaceholder extends StatelessWidget {
  const PanePlaceholder({
    super.key,
    required this.icon,
    required this.label,
    required this.hint,
  });

  final IconData icon;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.5);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: muted),
          const SizedBox(height: 12),
          Text(label, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            hint,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}
