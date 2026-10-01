import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/storage/vault_keys_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('OS plugin contract keeps only its named root and survives provider restart', () async {
    final keys = NativeVaultKeys(key: 'synthetic-vault-test');
    expect(await keys.read(), isNull);
    await keys.write('synthetic-root');
    keys.lock();
    expect(
      await NativeVaultKeys(key: 'synthetic-vault-test').read(),
      'synthetic-root',
    );
    expect(await NativeVaultKeys(key: 'another-household').read(), isNull);
    expect(await const FlutterSecureStorage().readAll(), {
      'synthetic-vault-test': 'synthetic-root',
    });
  });
}
