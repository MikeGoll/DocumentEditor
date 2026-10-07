import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:document_editor/src/documents/adapters/document_adapter.dart';
import 'package:document_editor/src/documents/document_format.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/ui/pane_placeholder.dart';
import 'package:document_editor/src/ui/table_embed_builder.dart';
import 'package:path/path.dart' as p;

/// Exposes the [DocumentState] to the widget subtree.
///
/// Deliberately a plain [InheritedWidget] (not an [InheritedNotifier]) so
/// that editor keystrokes do not rebuild the whole subtree; widgets that
/// need live updates wrap the relevant part in a [ListenableBuilder].
class DocumentScope extends InheritedWidget {
  const DocumentScope({
    super.key,
    required this.document,
    required super.child,
  });

  final DocumentState document;

  static DocumentState of(BuildContext context) =>
      (context
                  .getElementForInheritedWidgetOfExactType<DocumentScope>()
                  ?.widget as DocumentScope)
          .document;

  @override
  bool updateShouldNotify(DocumentScope oldWidget) =>
      document != oldWidget.document;
}

/// The document viewer pane: an editing toolbar plus the text editor.
///
/// Hosts a [QuillEditor] bound to the [DocumentState]. When no file is
/// open a placeholder invites the user to open a `.txt` file.
class DocumentViewPane extends StatefulWidget {
  const DocumentViewPane({super.key});

  @override
  State<DocumentViewPane> createState() => _DocumentViewPaneState();
}

class _DocumentViewPaneState extends State<DocumentViewPane> {
  DocumentState get _doc => DocumentScope.of(context);

  @override
  Widget build(BuildContext context) {
    final doc = _doc;

    return CallbackShortcuts(
      // Save and redo shortcuts that are not handled by the editor's own
      // shortcut map. B/I/U, select-all, copy and undo (Ctrl/Cmd+Z) are
      // provided by flutter_quill / Flutter's default shortcuts.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            () => doc.save(),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
            () => doc.save(),
        const SingleActivator(
                LogicalKeyboardKey.keyZ, control: true, shift: true):
            () => doc.quill.redo(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            () => doc.quill.redo(),
      },
      child: const Column(
        children: [_DocumentToolbar(), Expanded(child: _DocumentBody())],
      ),
    );
  }
}

/// Toolbar with file actions and formatting controls.
///
/// Rebuilds on any document-state or editor change so button enabled/active
/// states stay in sync (dirty flag, selection styles, undo/redo history).
class _DocumentToolbar extends StatelessWidget {
  const _DocumentToolbar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = DocumentScope.of(context);
    final quill = doc.quill;

    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([doc, quill]),
        builder: (context, _) => Row(
          children: [
            _ToolbarButton(
              icon: Icons.folder_open,
              tooltip: 'Open .txt, .md or .docx file',
              onPressed: () => _pickFile(doc, context),
            ),
            const SizedBox(width: 12),
            _ToolbarButton(
              icon: Icons.format_bold,
              tooltip: 'Bold (Ctrl/Cmd+B)',
              active: _hasStyle(quill, Attribute.bold),
              onPressed: () => quill.formatSelection(Attribute.bold),
            ),
            _ToolbarButton(
              icon: Icons.format_italic,
              tooltip: 'Italic (Ctrl/Cmd+I)',
              active: _hasStyle(quill, Attribute.italic),
              onPressed: () => quill.formatSelection(Attribute.italic),
            ),
            _ToolbarButton(
              icon: Icons.format_underlined,
              tooltip: 'Underline (Ctrl/Cmd+U)',
              active: _hasStyle(quill, Attribute.underline),
              onPressed: () => quill.formatSelection(Attribute.underline),
            ),
            const SizedBox(width: 12),
            _ToolbarButton(
              icon: Icons.undo,
              tooltip: 'Undo (Ctrl/Cmd+Z)',
              onPressed: quill.hasUndo ? quill.undo : null,
            ),
            _ToolbarButton(
              icon: Icons.redo,
              tooltip: 'Redo (Ctrl/Cmd+Shift+Z)',
              onPressed: quill.hasRedo ? quill.redo : null,
            ),
            const Spacer(),
            // Flexible (not Expanded) so short titles keep their intrinsic
            // width while long ones are constrained and elide instead of
            // overflowing the Row.
            if (doc.fileName != null)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    doc.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            _ToolbarButton(
              icon: Icons.save_as_outlined,
              tooltip: 'Save as… (change format)',
              onPressed: doc.hasDocument ? () => _saveAs(doc, context) : null,
            ),
            _ToolbarButton(
              icon: Icons.save_outlined,
              tooltip: 'Save (Ctrl/Cmd+S)',
              onPressed: doc.dirty ? () => _save(doc) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile(DocumentState doc, BuildContext context) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'md', 'markdown', 'docx'],
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null || !context.mounted) return;
    try {
      await doc.openFile(path);
    } on FileSystemException catch (e) {
      doc.reportError('Could not open file: ${e.message}');
    } on IOException catch (e) {
      doc.reportError('Could not open file: $e');
    } on FormatException catch (e) {
      doc.reportError('Could not open file: ${e.message}');
    }
  }

  Future<void> _save(DocumentState doc) async {
    try {
      await doc.save();
    } on FileSystemException catch (e) {
      doc.reportError('Could not save file: ${e.message}');
    } on IOException catch (e) {
      doc.reportError('Could not save file: $e');
    } on FormatException catch (e) {
      doc.reportError('Could not save file: ${e.message}');
    }
  }

  Future<void> _saveAs(DocumentState doc, BuildContext context) async {
    DocumentFormat selected = doc.format;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Save as…'),
            content: RadioGroup<DocumentFormat>(
              groupValue: selected,
              onChanged: (format) {
                if (format != null) {
                  setState(() => selected = format);
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final format in DocumentFormat.values)
                    RadioListTile<DocumentFormat>(
                      value: format,
                      title: Text(
                        '${format.label} (.${format.fileExtension})',
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !context.mounted) return;
    final format = selected;
    // Serialize in the target format; the picker dialog writes these bytes
    // to the location the user chooses.
    final bytes =
        DocumentAdapter.forFormat(format).serialize(doc.quill.document.toDelta());
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save as ${format.label}',
      fileName:
          '${p.basenameWithoutExtension(doc.fileName ?? 'document')}.${format.fileExtension}',
      bytes: Uint8List.fromList(bytes),
    );
    if (uri == null || !context.mounted) return;
    try {
      await doc.saveAsWritten(uri.toFilePath(), format);
    } on FileSystemException catch (e) {
      doc.reportError('Could not save file: ${e.message}');
    } on IOException catch (e) {
      doc.reportError('Could not save file: $e');
    } on FormatException catch (e) {
      doc.reportError('Could not save file: ${e.message}');
    }
  }

  bool _hasStyle(QuillController quill, Attribute attribute) {
    return quill
        .getAllSelectionStyles()
        .any((style) => style.values.any((a) => a.key == attribute.key));
  }
}

/// Body of the document pane: editor when a file is open, placeholder
/// otherwise.
class _DocumentBody extends StatelessWidget {
  const _DocumentBody();

  @override
  Widget build(BuildContext context) {
    final doc = DocumentScope.of(context);

    // Surface open/save errors as a transient snackbar.
    final error = doc.errorMessage;
    if (error != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error)));
        doc.clearError();
      });
    }

    return ListenableBuilder(
      listenable: doc,
      builder: (context, _) {
        if (!doc.hasDocument) {
          return const PanePlaceholder(
            icon: Icons.description_outlined,
            label: 'No document open',
            hint: 'Open a .txt, .md or .docx file to start editing.',
          );
        }
        return QuillEditor.basic(
          controller: doc.quill,
          config: const QuillEditorConfig(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
            embedBuilders: [TableEmbedBuilder()],
          ),
        );
      },
    );
  }
}

/// Small square toolbar button with an optional "active" highlight.
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: active ? theme.colorScheme.primary : null),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
