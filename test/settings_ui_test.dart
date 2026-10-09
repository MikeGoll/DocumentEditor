import 'dart:io';

import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/config/config_store.dart';
import 'package:document_editor/src/config/credential_store.dart';
import 'package:document_editor/src/config/llm_provider.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/ui/document_view_pane.dart';
import 'package:document_editor/src/ui/main_layout.dart';
import 'package:document_editor/src/ui/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings UI tests.
///
/// Real file I/O does not complete inside testWidgets' FakeAsync zone: the
/// controller is created inside [WidgetTester.runAsync] so its initial
/// config load runs in the real zone, and taps that trigger config I/O are
/// dispatched inside runAsync with [AgentConfigController.whenIdle] awaited.
void main() {
  late Directory tempDir;
  late InMemoryCredentialStore credentials;
  late ConfigStore store;
  late AgentConfigController config;
  late ChatController chat;

  /// Finds the input field whose label reads [label].
  ///
  /// [first] picks the earliest match in the tree (used when the same label
  /// appears in both the inline edit row and the add bar).
  Finder fieldByLabel(String label, {bool first = false}) {
    final matches = find
        .ancestor(of: find.text(label), matching: find.byType(TextField));
    return first ? matches.first : matches.last;
  }

  Finder promptField() => find.byWidgetPredicate((w) =>
      w is TextField &&
      w is! TextFormField &&
      w.decoration?.labelText == 'Custom system prompt');

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final document = DocumentState();
    addTearDown(document.dispose);
    await tester.runAsync(() async {
      config = AgentConfigController(store: store);
      chat = ChatController(
        document: document,
        store: ChatHistoryStore(baseDirectory: tempDir.path),
      );
      await config.whenIdle;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AgentConfigScope(
          config: config,
          child: DocumentScope(
            document: document,
            child: MainLayout(chat: chat),
          ),
        ),
      ),
    );
    addTearDown(chat.dispose);
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('settings_ui_test');
    credentials = InMemoryCredentialStore();
    store = ConfigStore(
        baseDirectory: tempDir.path, credentials: credentials);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  testWidgets('settings opens from the toolbar gear', (tester) async {
    await pumpApp(tester);

    await openSettings(tester);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Translation Table'), findsOneWidget);
    expect(find.text('System Prompt'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('can add a provider with an API key; key is stored securely',
      (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldByLabel('Name'), 'My OpenAI');
    // Switch the type to OpenAI so an API key is required.
    await tester.tap(find.byType(DropdownButtonFormField<ProviderType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldByLabel('API key'), 'sk-widget-test');

    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();

    expect(find.text('My OpenAI'), findsOneWidget);
    expect(find.text('no API key stored'), findsNothing);
    final id = config.config.providers.single.id;
    expect(config.config.activeProviderId, id);
    expect(await credentials.read(ConfigStore.credentialKeyFor(id)),
        'sk-widget-test');
    // The key must not leak into the plain-JSON config file.
    final fileContent =
        await tester.runAsync(() => File(store.filePath).readAsString());
    expect(fileContent, isNot(contains('sk-widget-test')));
  });

  testWidgets('local provider without endpoint is rejected', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldByLabel('Name'), 'Local');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(
        find.text('Endpoint URL is required for local APIs.'), findsOneWidget);
    // The form is still open; fill in the endpoint and it succeeds.
    await tester.enterText(
        fieldByLabel('Endpoint URL'), 'http://localhost:11434/v1');
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();

    expect(find.text('Local'), findsOneWidget);
    expect(config.config.providers.single.type, ProviderType.localOpenAi);
  });

  testWidgets('can switch the active provider via the radio', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    await tester.runAsync(() async {
      await config.addProvider(
          LlmProvider(id: 'p1', name: 'One', type: ProviderType.openai));
      await config.addProvider(
          LlmProvider(id: 'p2', name: 'Two', type: ProviderType.openai));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();

    expect(config.config.activeProviderId, 'p1');
    await tester.runAsync(() async {
      await tester.tap(find.byWidgetPredicate(
          (w) => w is Radio<String> && w.value == 'p2'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();

    expect(config.config.activeProviderId, 'p2');
  });

  testWidgets('translation table entries can be added, edited, deleted',
      (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.text('Translation Table'));
    await tester.pumpAndSettle();

    // Add an entry.
    await tester.enterText(fieldByLabel('Phrase'), 'colour');
    await tester
        .enterText(fieldByLabel('Preferred wording'), 'color');
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();
    expect(find.text('colour  →  color'), findsOneWidget);

    // Edit it. The edit row precedes the add bar in the tree, so pick the
    // first field with this label.
    await tester.tap(find.byTooltip('Edit entry'));
    await tester.pumpAndSettle();
    await tester.enterText(
        fieldByLabel('Preferred wording', first: true),
        'colour (keep British)');
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();
    expect(find.text('colour  →  colour (keep British)'), findsOneWidget);

    // Delete it.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Delete entry'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();
    expect(find.text('No translation entries'), findsOneWidget);
  });

  testWidgets('system prompt can be customized, previewed, and reset',
      (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();

    // Default prompt is shown in the preview with the "Default" chip.
    expect(find.text('Default prompt'), findsOneWidget);
    expect(find.textContaining('assistant author of the open document'),
        findsOneWidget);

    // Customize: the editor text is previewed immediately; the chip
    // (which reflects the saved config) disappears only after saving.
    await tester.enterText(promptField(), 'Be terse.');
    await tester.pumpAndSettle();
    expect(find.text('Be terse.'), findsNWidgets(2)); // editor + preview

    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();
    expect(find.text('Default prompt'), findsNothing);
    expect(config.config.effectiveSystemPrompt, 'Be terse.');

    // Reset restores the default.
    await tester.runAsync(() async {
      await tester.tap(find.text('Reset to default'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();
    expect(find.text('Default prompt'), findsOneWidget);
    expect(config.config.isUsingDefaultPrompt, isTrue);
  });

  testWidgets('configuration persists across app restarts', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldByLabel('Name'), 'Persistent');
    await tester.enterText(
        fieldByLabel('Endpoint URL'), 'http://localhost:11434/v1');
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await config.whenIdle;
    });
    await tester.pumpAndSettle();
    expect(find.text('Persistent'), findsOneWidget);

    // "Restart": a fresh controller over the same storage.
    await tester.pumpWidget(const SizedBox());
    final document2 = DocumentState();
    addTearDown(document2.dispose);
    await tester.runAsync(() async {
      config = AgentConfigController(store: store);
      await config.whenIdle;
    });
    addTearDown(config.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AgentConfigScope(
          config: config,
          child: DocumentScope(
            document: document2,
            child: MainLayout(chat: chat),
          ),
        ),
      ),
    );
    await openSettings(tester);
    expect(find.text('Persistent'), findsOneWidget);
  });
}
