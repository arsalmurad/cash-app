import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  if (library != null) {
    setUpAll(
      () => RustLib.init(externalLibrary: ExternalLibrary.open(library)),
    );
  }
  test('whole JPY and frozen FX survive real SQLite restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cash-personal-jpy-',
    );
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await directory.delete(recursive: true);
    });
    final ledger = LedgerController();
    addTearDown(ledger.dispose);
    await ledger.initialize();
    expect(
      await ledger.createAccount(name: 'Zero Yen', currencyCode: 'JPY'),
      isTrue,
    );
    for (final entry in [
      ('First', '123', '0.0065'),
      ('Later', '100', '0.01'),
    ]) {
      expect(
        await ledger.record(
          title: entry.$1,
          amount: entry.$2,
          kind: EntryKind.expense,
          accountId: 'zero-yen',
          rate: entry.$3,
        ),
        isTrue,
      );
    }
    final restarted = LedgerController();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    final account = restarted.overview!.accounts.singleWhere(
      (a) => a.id == 'zero-yen',
    );
    expect(account.balanceLabel, 'JPY -223');
    expect(account.reportingBalanceLabel, 'USD -1.80');
    expect(
      restarted.overview!.transactions
          .singleWhere((t) => t.title == 'First')
          .amountLabel,
      'JPY 123',
    );
    final before = await EventStore('ledger').readLog();
    expect(
      await restarted.record(
        title: 'Reject',
        amount: '0.5',
        kind: EntryKind.expense,
        accountId: account.id,
        rate: '0.01',
      ),
      isFalse,
    );
    expect(await EventStore('ledger').readLog(), orderedEquals(before));
  }, skip: library == null);
}
