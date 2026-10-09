import 'package:flutter/material.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/ui/settings/provider_settings_tab.dart';
import 'package:document_editor/src/ui/settings/system_prompt_tab.dart';
import 'package:document_editor/src/ui/settings/translation_table_tab.dart';

/// Exposes the [AgentConfigController] to the widget subtree.
class AgentConfigScope extends InheritedWidget {
  const AgentConfigScope({
    super.key,
    required this.config,
    required super.child,
  });

  final AgentConfigController config;

  static AgentConfigController of(BuildContext context) =>
      (context
                  .getElementForInheritedWidgetOfExactType<AgentConfigScope>()
                  ?.widget as AgentConfigScope)
          .config;

  @override
  bool updateShouldNotify(AgentConfigScope oldWidget) =>
      config != oldWidget.config;
}

/// Opens the settings dialog (providers, translation table, system prompt).
Future<void> showSettingsDialog(BuildContext context) {
  final controller = AgentConfigScope.of(context);
  return showDialog<void>(
    context: context,
    builder: (_) => SettingsDialog(controller: controller),
  );
}

/// The settings screen: a tabbed dialog for providers, the translation
/// table, and the system prompt.
///
/// All changes are applied (and persisted) immediately; there is no
/// separate save step.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.controller});

  final AgentConfigController controller;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 3, vsync: this);
  late final VoidCallback _onTabChanged;

  @override
  void initState() {
    super.initState();
    // Rebuild the tab content when the selected tab changes (a plain
    // TabBar does not notify its surroundings; TabBarView would).
    _onTabChanged = () => setState(() {});
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 8, 0),
              child: Row(
                children: [
                  Text('Settings', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close settings',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Providers'),
                Tab(text: 'Translation Table'),
                Tab(text: 'System Prompt'),
              ],
            ),
            const Divider(),
            // Rebuild the active tab whenever the configuration changes;
            // the dialog itself does not listen to the controller.
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => SizedBox(
                height: 420,
                child: switch (_tabController.index) {
                  1 => TranslationTableTab(controller: widget.controller),
                  2 => SystemPromptTab(controller: widget.controller),
                  _ => ProvidersTab(controller: widget.controller),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centered icon + label + hint shown when a settings section is empty.
class EmptyHint extends StatelessWidget {
  const EmptyHint({
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

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
