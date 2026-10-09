import 'dart:convert';

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_config.dart';
import 'credential_store.dart';

/// Persists the [AgentConfig] as JSON plus provider API keys in a
/// [CredentialStore].
///
/// The config file lives in `~/Documents/DocumentEditor/config/` by default
/// (the same area as chat histories); the base directory can be overridden
/// (e.g. in tests) via the constructor. API keys are never written to the
/// JSON file — they go through [CredentialStore], which keeps them in the
/// OS keychain/keystore.
class ConfigStore {
  ConfigStore({String? baseDirectory, required CredentialStore credentials})
      : _directory = baseDirectory ??
            p.join(_defaultHome, 'Documents', 'DocumentEditor', 'config'),
        _credentials = credentials;

  /// Home directory from the environment (sync access; `Directory.home()`
  /// is async and unavailable in a constructor).
  static String get _defaultHome =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

  /// Name of the config file inside the base directory.
  static const String configFileName = 'agent_config.json';

  /// Credential-store key holding the API key for [providerId].
  static String credentialKeyFor(String providerId) =>
      'agent_config/provider_$providerId/api_key';

  final String _directory;
  final CredentialStore _credentials;

  /// Absolute path of the config JSON file.
  String get filePath => p.join(_directory, configFileName);

  /// Loads the config, returning an empty config when no file exists or the
  /// file is corrupt, so a bad file never breaks the UI.
  Future<AgentConfig> load() async {
    final file = File(filePath);
    if (!await file.exists()) return AgentConfig();
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return AgentConfig.fromJson(json);
    } on FormatException {
      return AgentConfig();
    }
  }

  /// Ids of the providers that currently have an API key stored.
  Future<Set<String>> apiKeyProviderIds() async {
    final ids = <String>{};
    final config = await load();
    for (final provider in config.providers) {
      final key = await _credentials.read(credentialKeyFor(provider.id));
      if (key != null && key.isNotEmpty) ids.add(provider.id);
    }
    return ids;
  }

  /// Reads the stored API key for [providerId], or `null` when absent.
  Future<String?> readApiKey(String providerId) =>
      _credentials.read(credentialKeyFor(providerId));

  /// Writes the config and applies [apiKeys] to the credential store.
  ///
  /// [apiKeys] maps provider id → new key: a non-null value writes (or
  /// overwrites) the key, `null` deletes it, and providers not present in
  /// the map keep their stored key.
  Future<void> save(AgentConfig config,
      {Map<String, String?> apiKeys = const {}}) async {
    await Directory(_directory).create(recursive: true);
    final payload = const JsonEncoder.withIndent('  ').convert(config.toJson());
    await File(filePath).writeAsString(payload);
    for (final entry in apiKeys.entries) {
      final key = entry.value;
      if (key == null || key.isEmpty) {
        await _credentials.delete(credentialKeyFor(entry.key));
      } else {
        await _credentials.write(credentialKeyFor(entry.key), key);
      }
    }
  }
}
