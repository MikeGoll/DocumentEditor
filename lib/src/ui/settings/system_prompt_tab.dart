import 'package:flutter/material.dart';
import 'package:document_editor/src/config/agent_config.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';

/// System prompt tab: editor with a reset-to-default action and a live
/// preview of the prompt that will actually be injected into agent calls.
class SystemPromptTab extends StatefulWidget {
  const SystemPromptTab({super.key, required this.controller});

  final AgentConfigController controller;

  @override
  State<SystemPromptTab> createState() => _SystemPromptTabState();
}

class _SystemPromptTabState extends State<SystemPromptTab> {
  final _controller = TextEditingController();
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final config = widget.controller.config;
    _controller.text =
        config.isUsingDefaultPrompt ? '' : config.systemPrompt!;
    widget.controller.addListener(_syncFromController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromController);
    _controller.dispose();
    super.dispose();
  }

  /// Re-syncs the editor when the config changes outside this tab (e.g.
  /// after a reset from elsewhere), without clobbering local edits.
  void _syncFromController() {
    if (_dirty) return;
    final config = widget.controller.config;
    final text = config.isUsingDefaultPrompt ? '' : config.systemPrompt!;
    if (_controller.text != text) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  Future<void> _save() async {
    await widget.controller.setSystemPrompt(_controller.text);
    setState(() => _dirty = false);
  }

  Future<void> _reset() async {
    await widget.controller.resetSystemPrompt();
    setState(() => _dirty = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = widget.controller.config;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (config.isUsingDefaultPrompt)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Default prompt',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer),
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset to default'),
                onPressed: config.isUsingDefaultPrompt ? null : _reset,
              ),
              FilledButton(
                onPressed: _dirty ? _save : null,
                child: const Text('Save'),
              ),
            ],
          ),
          TextField(
            controller: _controller,
            maxLines: 8,
            minLines: 8,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(
              labelText: 'Custom system prompt',
              hintText:
                  'Leave empty to use the default prompt. When set, this '
                  'text is injected as the agent\'s system prompt.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('Preview', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: Text(
                  _controller.text.trim().isEmpty
                      ? AgentConfig.defaultSystemPrompt
                      : _controller.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
