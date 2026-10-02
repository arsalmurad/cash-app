import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';

// Ownership-only doubles; actual encryption/recovery is covered by host and
// platform scenarios. No native library is loaded by these tests.
class _TrackedHousehold implements Household {
  int releases = 0;

  @override
  void dispose() => releases++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements RustLibApi {
  final handle = _TrackedHousehold();
  int creations = 0;
  int exports = 0;

  @override
  Future<Household> crateApiSharedHouseholdNew({
    required String memberId,
    required String reportingCurrencyCode,
  }) async {
    creations++;
    return handle;
  }

  @override
  Future<Uint8List> crateApiSharedHouseholdExport({
    required Household household,
  }) async {
    expect(household, same(handle));
    expect(handle.releases, 0);
    exports++;
    return Uint8List.fromList([1]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements BlobStore {
  _Store({this.saveBeforeFailure = false, this.fail = false});
  final bool saveBeforeFailure;
  final bool fail;
  final entered = Completer<void>();
  final release = Completer<void>();
  Uint8List? value;

  @override
  Future<Uint8List?> read() async => value;

  @override
  Future<void> write(Uint8List bytes) async {
    if (!fail) {
      value = Uint8List.fromList(bytes);
      return;
    }
    entered.complete();
    await release.future;
    if (saveBeforeFailure) value = Uint8List.fromList(bytes);
    throw StateError('Synthetic uncertain save');
  }

  @override
  Future<void> delete() async => value = null;
}

void main() {
  for (final saved in [false, true]) {
    test(
      'uncertain save releases its owned handle once (saved=$saved)',
      () async {
        final api = _Api();
        RustLib.initMock(api: api);
        addTearDown(RustLib.dispose);
        final store = _Store(fail: true, saveBeforeFailure: saved);
        final controller = HouseholdController(
          stateStore: store,
          configStore: _Store(),
          newMemberId: () => 'test-device',
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        final first = controller.prepareJoinRequest();
        await store.entered.future;
        final queued = controller.prepareJoinRequest();
        expect(
          api.handle.releases,
          0,
          reason: 'Do not release an in-use handle',
        );
        store.release.complete();
        expect(await first, isNull);
        expect(await queued, isNull);
        expect(controller.requiresRestart, isTrue);
        expect(controller.hasIdentity, isFalse);
        expect(api.handle.releases, 1);
        expect(api.creations, 1);
        expect(api.exports, 1);
        expect(store.value != null, saved);
        await controller.initialize();
        expect(
          api.handle.releases,
          1,
          reason: 'Repeated refusal must not double release',
        );
      },
    );
  }
}
