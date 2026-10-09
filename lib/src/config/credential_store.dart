import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Abstraction over secure, local-only credential storage.
///
/// Implementations must never upload values; API keys stay on the device.
abstract class CredentialStore {
  /// Reads the value for [key], or `null` when absent.
  Future<String?> read(String key);

  /// Writes [value] for [key], overwriting any previous value.
  Future<void> write(String key, String value);

  /// Deletes the value for [key] if present.
  Future<void> delete(String key);
}

/// [CredentialStore] backed by the OS keychain/keystore via
/// `flutter_secure_storage` (Keychain on macOS/iOS, DPAPI-backed on
/// Windows, EncryptedSharedPreferences on Android).
class SecureCredentialStore implements CredentialStore {
  const SecureCredentialStore();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory [CredentialStore] for tests and previews.
class InMemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
