import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../../data/rust/api/ledger.dart';
import '../../data/storage/actor_id.dart';
import '../../data/storage/event_store.dart';

class LedgerController extends ChangeNotifier {
  LedgerController({EventStore? store}) : _store = store ?? EventStore();

  final EventStore _store;
  PersonalLedger? _ledger;
  LedgerOverview? overview;
  bool isLoading = true;
  String? errorMessage;
  int _sequence = 0;

  /// Diagnostics from the most recent [initialize] load, mainly for tests:
  /// how many persisted events were recovered and whether the tail of the
  /// log was truncated (a torn write from a previous crash).
  int recoveredEventCount = 0;
  int truncatedBytes = 0;

  Future<void> initialize() async {
    try {
      var actorId = await _store.readActorId();
      if (actorId == null) {
        actorId = generateActorId();
        await _store.writeActorId(actorId);
      }

      final logBytes = await _store.readLog();
      final ledger = await loadPersonalLedger(
        actorId: actorId,
        reportingCurrencyCode: 'USD',
        logBytes: logBytes,
      );
      final report = await loadReport(ledger: ledger);
      _ledger = ledger;
      overview = report.overview;
      recoveredEventCount = report.recoveredEventCount.toInt();
      truncatedBytes = report.truncatedBytes.toInt();

      if (report.overview.accounts.isEmpty) {
        await _mutate(
          () => addAccount(
            ledger: ledger,
            accountId: 'everyday',
            name: 'Everyday',
            currencyCode: 'USD',
            wallClockMillis: PlatformInt64Util.from(
              DateTime.now().millisecondsSinceEpoch,
            ),
          ),
        );
      }
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> record({
    required String title,
    required String amount,
    required EntryKind kind,
    String? categoryId,
  }) async {
    final ledger = _ledger;
    if (ledger == null || overview == null) {
      return false;
    }
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final now = DateTime.now();
      _sequence += 1;
      await _mutate(
        () => recordTransaction(
          ledger: ledger,
          transactionId: 'local-${now.microsecondsSinceEpoch}-$_sequence',
          accountId: 'everyday',
          kind: kind,
          amount: amount,
          currencyCode: 'USD',
          fxNumerator: PlatformInt64Util.from(1),
          fxDenominator: PlatformInt64Util.from(1),
          title: title.trim(),
          categoryId: categoryId,
          wallClockMillis: PlatformInt64Util.from(now.millisecondsSinceEpoch),
        ),
      );
      return true;
    } catch (error) {
      errorMessage = error.toString();
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Runs a mutation and durably persists its appended event frame before
  /// updating [overview]. If the process dies before [EventStore.appendFrame]
  /// returns, the mutation was never durable and the next launch simply
  /// won't see it — there is no half-applied state to reconcile.
  Future<void> _mutate(Future<LedgerMutation> Function() mutation) async {
    final result = await mutation();
    await _store.appendFrame(result.appendedFrame);
    overview = result.overview;
  }
}
