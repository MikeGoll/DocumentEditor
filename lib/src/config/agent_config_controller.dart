import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:document_editor/src/config/translation_entry.dart';

import 'agent_config.dart';
import 'config_store.dart';
import 'llm_provider.dart';

/// In-memory agent configuration backed by a [ConfigStore].
///
/// Every mutation is persisted best-effort in the background (mirroring
/// [ChatController]'s pattern), so the configuration survives restarts
/// without an explicit "save" step in the UI. Listeners are notified
/// synchronously when the in-memory config changes.
class AgentConfigController extends ChangeNotifier {
  AgentConfigController({required ConfigStore store}) : _store = store {
    _load();
  }

  final ConfigStore _store;

  AgentConfig _config = AgentConfig();
  Set<String> _providersWithApiKeys = const {};
  bool _loading = true;
  bool _disposed = false;

  /// Serializes config I/O so quick successive edits cannot write the file
  /// out of order.
  Future<void> _pending = Future.value();

  /// Completes when all in-flight config I/O has finished.
  ///
  /// Useful in tests to deterministically wait for file writes.
  Future<void> get whenIdle => _pending;

  /// The current configuration snapshot.
  AgentConfig get config => _config;

  /// Whether the initial config load is still in flight.
  bool get isLoading => _loading;

  /// Ids of providers that have an API key stored.
  Set<String> get providersWithApiKeys => Set.unmodifiable(_providersWithApiKeys);

  /// Whether an API key is stored for [providerId].
  bool hasApiKey(String providerId) => _providersWithApiKeys.contains(providerId);

  /// Reads the stored API key for [providerId], or `null` when absent.
  Future<String?> readApiKey(String providerId) =>
      _store.readApiKey(providerId);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Adds [provider] (and its [apiKey], if any) and persists.
  ///
  /// When no provider is active yet, the new one becomes active.
  Future<void> addProvider(LlmProvider provider, {String? apiKey}) {
    final providers = [..._config.providers, provider];
    final active = _config.activeProviderId ?? provider.id;
    return _mutate(
      _config.copyWith(providers: providers, activeProviderId: active),
      apiKeys: _apiKeyUpdate(provider.id, apiKey),
    );
  }

  /// Replaces the provider with [provider.id] and persists.
  ///
  /// [apiKey] is optional: when omitted the stored key is left untouched.
  Future<void> updateProvider(LlmProvider provider, {String? apiKey}) {
    final providers = [
      for (final p in _config.providers)
        if (p.id == provider.id) provider else p,
    ];
    return _mutate(
      _config.copyWith(providers: providers),
      apiKeys: apiKey == null ? null : _apiKeyUpdate(provider.id, apiKey),
    );
  }

  /// Removes the provider with [id], deletes its stored key, and persists.
  ///
  /// When the removed provider was active, the first remaining provider
  /// (if any) becomes active.
  Future<void> removeProvider(String id) {
    final removed = _config.providers.where((p) => p.id == id);
    if (removed.isEmpty) return Future.value();
    final providers = [
      for (final p in _config.providers)
        if (p.id != id) p,
    ];
    String? active = _config.activeProviderId;
    if (active == id) {
      active = providers.isNotEmpty ? providers.first.id : null;
    }
    return _mutate(
      _config.copyWith(
        providers: providers,
        activeProviderId: active,
        clearActiveProvider: active == null,
      ),
      apiKeys: {id: null},
    );
  }

  /// Sets (or, with `null`, clears) the active provider and persists.
  Future<void> setActiveProvider(String? id) {
    if (id != null &&
        !_config.providers.any((p) => p.id == id)) {
      return Future.value();
    }
    return _mutate(_config.copyWith(activeProviderId: id));
  }

  /// Stores (or, with `null` or blank, deletes) the API key for
  /// [providerId].
  Future<void> setApiKey(String providerId, String? apiKey) {
    final key =
        (apiKey == null || apiKey.trim().isEmpty) ? null : apiKey.trim();
    return _mutate(_config, apiKeys: {providerId: key}, refreshKeys: true);
  }

  /// Adds or replaces a translation-table entry keyed by [original].
  Future<void> setTranslationEntry(String original, String correction) {
    final table = Map<String, TranslationEntry>.from(_config.translationTable);
    table[original] =
        TranslationEntry(original: original, correction: correction);
    return _mutate(_config.copyWith(translationTable: table));
  }

  /// Removes the translation-table entry for [original], if present.
  Future<void> removeTranslationEntry(String original) {
    if (!_config.translationTable.containsKey(original)) return Future.value();
    final table = Map<String, TranslationEntry>.from(_config.translationTable)
      ..remove(original);
    return _mutate(_config.copyWith(translationTable: table));
  }

  /// Sets the custom system prompt and persists.
  ///
  /// A blank [prompt] restores the default prompt.
  Future<void> setSystemPrompt(String prompt) {
    final trimmed = prompt.trim();
    return _mutate(
      _config.copyWith(
        systemPrompt: trimmed.isEmpty ? null : prompt,
        clearSystemPrompt: trimmed.isEmpty,
      ),
    );
  }

  /// Restores the built-in default system prompt and persists.
  Future<void> resetSystemPrompt() {
    if (_config.isUsingDefaultPrompt) return Future.value();
    return _mutate(_config.copyWith(clearSystemPrompt: true));
  }

  /// Generates a unique provider id that does not collide with existing
  /// ones (used when creating a provider from the UI).
  String newProviderId() {
    final taken = _config.providers.map((p) => p.id).toSet();
    var candidate = 'provider_${_random.nextInt(1 << 30).toRadixString(36)}';
    while (taken.contains(candidate)) {
      candidate = 'provider_${_random.nextInt(1 << 30).toRadixString(36)}';
    }
    return candidate;
  }

  final Random _random = Random();

  Map<String, String?>? _apiKeyUpdate(String providerId, String? apiKey) {
    if (apiKey == null) return null;
    return {providerId: apiKey.trim().isEmpty ? null : apiKey.trim()};
  }

  void _load() {
    _loading = true;
    _notify();
    _chain(() async {
      final config = await _store.load();
      _config = config;
      _providersWithApiKeys = await _store.apiKeyProviderIds();
      _loading = false;
    });
  }

  /// Applies [config] in memory, persists it, and notifies listeners.
  Future<void> _mutate(
    AgentConfig config, {
    Map<String, String?>? apiKeys,
    bool refreshKeys = false,
  }) {
    _config = config;
    _notify();
    return _chain(() async {
      await _store.save(config, apiKeys: apiKeys ?? const {});
      if (refreshKeys || apiKeys != null) {
        _providersWithApiKeys = await _store.apiKeyProviderIds();
      }
    });
  }

  /// Runs [op] on the I/O chain, swallowing failures so a bad disk write
  /// never breaks the in-memory config, and notifies on completion.
  Future<void> _chain(Future<void> Function() op) {
    _pending = _pending.then((_) async {
      try {
        await op();
      } catch (_) {
        // Persistence is best-effort; keep the in-memory config usable.
      }
      _notify();
    });
    return _pending;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
