import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';

/// 讀取一律丟例外的 secure storage（模擬 keystore 損壞）。
class _ThrowingStorage extends FlutterSecureStorage {
  /// 建立替身。
  const _ThrowingStorage();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => throw Exception('keystore broken');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('key store read failure is treated as not paired', () async {
    expect(
      await AdbKeyStore(storage: const _ThrowingStorage()).hasKey(),
      isFalse,
    );
  });

  test('loadOrCreate persists the key and reloads the same one', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AdbKeyStore();
    expect(await store.hasKey(), isFalse);
    final first = await store.loadOrCreate();
    expect(await store.hasKey(), isTrue);
    final again = await AdbKeyStore().loadOrCreate();
    expect(again.keyPair.publicKey.modulus, first.keyPair.publicKey.modulus);
    await store.delete();
    expect(await store.hasKey(), isFalse);
  });
}
