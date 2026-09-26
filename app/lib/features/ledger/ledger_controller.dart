import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../../data/rust/api/ledger.dart';

class LedgerController extends ChangeNotifier {
  PersonalLedger? _ledger;
  LedgerOverview? overview;
  bool isLoading = true;
  String? errorMessage;
  int _sequence = 0;

  Future<void> initialize() async {
    try {
      final ledger = await createPersonalLedger(
        actorId: 'local-prototype-device',
        reportingCurrencyCode: 'USD',
      );
      _ledger = ledger;
      overview = await addAccount(
        ledger: ledger,
        accountId: 'everyday',
        name: 'Everyday',
        currencyCode: 'USD',
        wallClockMillis: PlatformInt64Util.from(
          DateTime.now().millisecondsSinceEpoch,
        ),
      );
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
      overview = await recordTransaction(
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
}
