import 'package:flutter/material.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/config/translation_entry.dart';
import 'package:document_editor/src/ui/settings/settings_screen.dart';

/// Translation table tab: add, edit, and remove phrase → correction pairs.
class TranslationTableTab extends StatefulWidget {
  const TranslationTableTab({super.key, required this.controller});

  final AgentConfigController controller;

  @override
  State<TranslationTableTab> createState() => _TranslationTableTabState();
}

class _TranslationTableTabState extends State<TranslationTableTab> {
  final _originalController = TextEditingController();
  final _correctionController = TextEditingController();
  String? _editingOriginal;
  final _editOriginalController = TextEditingController();
  final _editCorrectionController = TextEditingController();

  @override
  void dispose() {
    _originalController.dispose();
    _correctionController.dispose();
    _editOriginalController.dispose();
    _editCorrectionController.dispose();
    super.dispose();
  }

  void _startEdit(TranslationEntry entry) {
    setState(() {
      _editingOriginal = entry.original;
      _editOriginalController.text = entry.original;
      _editCorrectionController.text = entry.correction;
    });
  }

  void _cancelEdit() => setState(() => _editingOriginal = null);

  Future<void> _saveEdit() async {
    final original = _editOriginalController.text.trim();
    final correction = _editCorrectionController.text.trim();
    if (original.isEmpty || correction.isEmpty) return;
    await widget.controller.setTranslationEntry(original, correction);
    if (mounted) _cancelEdit();
  }

  Future<void> _addEntry() async {
    final original = _originalController.text.trim();
    final correction = _correctionController.text.trim();
    if (original.isEmpty || correction.isEmpty) return;
    await widget.controller.setTranslationEntry(original, correction);
    _originalController.clear();
    _correctionController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.controller.config.translationTable.values.toList()
      ..sort((a, b) =>
          a.original.toLowerCase().compareTo(b.original.toLowerCase()));

    return Column(
      children: [
        Expanded(
          child: entries.isEmpty
              ? const EmptyHint(
                  icon: Icons.translate,
                  label: 'No translation entries',
                  hint:
                      'Add phrases the agent should always render a certain '
                          'way.',
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final entry in entries)
                      if (entry.original == _editingOriginal)
                        _TranslationEditRow(
                          originalController: _editOriginalController,
                          correctionController: _editCorrectionController,
                          onSave: _saveEdit,
                          onCancel: _cancelEdit,
                        )
                      else
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${entry.original}  →  ${entry.correction}',
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  tooltip: 'Edit entry',
                                  onPressed: () => _startEdit(entry),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Delete entry',
                                  onPressed: () => widget.controller
                                      .removeTranslationEntry(entry.original),
                                ),
                              ],
                            ),
                          ),
                        ),
                  ],
                ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _originalController,
                  decoration:
                      const InputDecoration(labelText: 'Phrase'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _correctionController,
                  decoration:
                      const InputDecoration(labelText: 'Preferred wording'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add'),
                onPressed: _addEntry,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Inline edit row replacing a table entry while it is being edited.
class _TranslationEditRow extends StatelessWidget {
  const _TranslationEditRow({
    required this.originalController,
    required this.correctionController,
    required this.onSave,
    required this.onCancel,
  });

  final TextEditingController originalController;
  final TextEditingController correctionController;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: originalController,
                    decoration: const InputDecoration(labelText: 'Phrase'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: correctionController,
                    decoration: const InputDecoration(
                        labelText: 'Preferred wording'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(onPressed: onSave, child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
