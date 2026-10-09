import 'package:flutter/material.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/config/llm_provider.dart';
import 'package:document_editor/src/ui/settings/settings_screen.dart';

/// Providers tab: list of configured providers plus add/edit/delete.
class ProvidersTab extends StatelessWidget {
  const ProvidersTab({super.key, required this.controller});

  final AgentConfigController controller;

  @override
  Widget build(BuildContext context) {
    final config = controller.config;

    return Column(
      children: [
        Expanded(
          child: config.providers.isEmpty
              ? const EmptyHint(
                  icon: Icons.cloud_off_outlined,
                  label: 'No providers configured',
                  hint: 'Add a provider to connect the agent to an LLM.',
                )
              : RadioGroup<String>(
                  groupValue: config.activeProviderId,
                  onChanged: (id) {
                    if (id != null) controller.setActiveProvider(id);
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final provider in config.providers)
                        _ProviderCard(
                          provider: provider,
                          hasApiKey: controller.hasApiKey(provider.id),
                          onEdit: () => _editProvider(context, provider),
                          onDelete: () => _confirmDelete(context, provider),
                        ),
                    ],
                  ),
                ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add provider'),
              onPressed: () => _editProvider(context),
            ),
          ),
        ),
      ],
    );
  }

  void _editProvider(BuildContext context, [LlmProvider? existing]) {
    showDialog<void>(
      context: context,
      builder: (_) => ProviderFormDialog(
        controller: controller,
        existing: existing,
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, LlmProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete provider?'),
        content:
            Text('“${provider.name}” and its stored API key will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.removeProvider(provider.id);
  }
}

/// A single provider row: active radio, summary, edit/delete actions.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.hasApiKey,
    required this.onEdit,
    required this.onDelete,
  });

  final LlmProvider provider;
  final bool hasApiKey;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = [
      provider.type.label,
      if (provider.effectiveEndpoint != null) provider.effectiveEndpoint!,
      if (provider.effectiveModel != null) provider.effectiveModel!,
      if (provider.type.requiresApiKey && !hasApiKey) 'no API key stored',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Tooltip(
              message: 'Use ${provider.name} for the agent',
              child: Radio<String>(value: provider.id),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(provider.name, style: theme.textTheme.titleSmall),
                  Text(
                    details,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit provider',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete provider',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// Add/edit form for a provider.
///
/// When [existing] is set the dialog edits that provider; the API key field
/// starts empty meaning "keep the stored key" (the stored key is never read
/// back into the form).
class ProviderFormDialog extends StatefulWidget {
  const ProviderFormDialog(
      {super.key, required this.controller, this.existing});

  final AgentConfigController controller;
  final LlmProvider? existing;

  @override
  State<ProviderFormDialog> createState() => _ProviderFormDialogState();
}

class _ProviderFormDialogState extends State<ProviderFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late ProviderType _type;
  bool _keyVisible = false;
  bool _hasStoredKey = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _endpoint = TextEditingController(text: existing?.endpoint ?? '');
    _model = TextEditingController(text: existing?.model ?? '');
    _apiKey = TextEditingController();
    _type = existing?.type ?? ProviderType.localOpenAi;
    _hasStoredKey = _isEditing && widget.controller.hasApiKey(existing!.id);
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  LlmProvider _candidate() => LlmProvider(
        id: widget.existing?.id ?? widget.controller.newProviderId(),
        name: _name.text,
        type: _type,
        endpoint: _endpoint.text.trim().isEmpty ? null : _endpoint.text.trim(),
        model: _model.text.trim().isEmpty ? null : _model.text.trim(),
      );

  /// The key to persist: `null` when the field is left empty (keep the
  /// stored key, or none), otherwise the typed value.
  String? get _keyToStore => _apiKey.text.isEmpty ? null : _apiKey.text;

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final errors = _candidate().validate(
        hasApiKey: _apiKey.text.isNotEmpty || _hasStoredKey);
    if (errors.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(errors.values.first)));
      return;
    }
    final provider = _candidate();
    if (widget.existing == null) {
      await widget.controller.addProvider(provider,
          apiKey: _keyToStore);
    } else {
      await widget.controller.updateProvider(provider,
          apiKey: _keyToStore);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(_isEditing ? 'Edit provider' : 'Add provider'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Work LLM',
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Name is required.'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ProviderType>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Provider type'),
                items: [
                  for (final type in ProviderType.values)
                    DropdownMenuItem(value: type, child: Text(type.label)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _type = value);
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _endpoint,
                decoration: InputDecoration(
                  labelText: 'Endpoint URL',
                  hintText: _type.endpointHint,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: 'Model (optional)',
                  hintText: 'e.g. gpt-4o-mini',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiKey,
                obscureText: !_keyVisible,
                decoration: InputDecoration(
                  labelText:
                      _type.requiresApiKey ? 'API key' : 'API key (optional)',
                  suffixIcon: IconButton(
                    icon: Icon(_keyVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    tooltip: _keyVisible ? 'Hide key' : 'Show key',
                    onPressed: () => setState(() => _keyVisible = !_keyVisible),
                  ),
                ),
              ),
              if (_isEditing && _hasStoredKey)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'A key is stored; leave the field empty to keep it.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
