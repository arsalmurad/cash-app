import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64, PlatformInt64Util;

import '../../data/rust/api/categories.dart';
import '../../data/rust/api/ledger.dart';
import '../../data/storage/actor_id.dart';
import '../../data/storage/event_store.dart';
import 'category_presets.dart';

class LedgerController extends ChangeNotifier {
  LedgerController({
    DeviceIdentity? identity,
    EventStore? ledgerStore,
    EventStore? categoryStore,
  }) : _identity = identity ?? DeviceIdentity(),
       _ledgerStore = ledgerStore ?? EventStore('ledger'),
       _categoryStore = categoryStore ?? EventStore('categories');

  final DeviceIdentity _identity;
  final EventStore _ledgerStore;
  final EventStore _categoryStore;

  PersonalLedger? _ledger;
  CategoryBook? _categoryBook;
  LedgerOverview? overview;
  List<CategoryView> categories = [];
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
      var actorId = await _identity.readActorId();
      if (actorId == null) {
        actorId = generateActorId();
        await _identity.writeActorId(actorId);
      }

      final ledgerLogBytes = await _ledgerStore.readLog();
      final ledger = await loadPersonalLedger(
        actorId: actorId,
        reportingCurrencyCode: 'USD',
        logBytes: ledgerLogBytes,
      );
      final report = await loadReport(ledger: ledger);
      _ledger = ledger;
      overview = report.overview;
      recoveredEventCount = report.recoveredEventCount.toInt();
      truncatedBytes = report.truncatedBytes.toInt();

      final categoryLogBytes = await _categoryStore.readLog();
      final categoryBook = await loadCategoryBook(
        actorId: actorId,
        logBytes: categoryLogBytes,
      );
      final categoryReport = await categoryLoadReport(book: categoryBook);
      _categoryBook = categoryBook;
      categories = categoryReport.categories;

      if (report.overview.accounts.isEmpty) {
        await _mutateLedger(
          () => addAccount(
            ledger: ledger,
            accountId: 'everyday',
            name: 'Everyday',
            currencyCode: 'USD',
            wallClockMillis: _nowMillis(),
          ),
        );
      }

      if (categories.isEmpty) {
        for (final preset in defaultCategoryPresets) {
          await _mutateCategories(
            () => upsertCategory(
              book: categoryBook,
              categoryId: preset.id,
              name: preset.name,
              iconKey: preset.iconKey,
              wallClockMillis: _nowMillis(),
            ),
          );
        }
      }
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// "Custom titles that auto-assign on repeat": the category of the most
  /// recent past transaction with a matching title, or `null`.
  Future<String?> suggestCategoryFor(String title) async {
    final ledger = _ledger;
    if (ledger == null) {
      return null;
    }
    return suggestCategoryForTitle(ledger: ledger, title: title);
  }

  /// Creates a category and returns it, or `null` on failure. Returning the
  /// authoritative record (rather than letting the caller guess its ID from
  /// the name) matters: the ID here is exactly what gets stored as a
  /// transaction's `categoryId`, and must match what [_slugify] actually
  /// produced, not an approximation of it.
  Future<CategoryView?> addCategory({
    required String name,
    required String iconKey,
  }) async {
    final book = _categoryBook;
    if (book == null) {
      return null;
    }
    final categoryId = _slugify(name);
    try {
      await _mutateCategories(
        () => upsertCategory(
          book: book,
          categoryId: categoryId,
          name: name.trim(),
          iconKey: iconKey,
          wallClockMillis: _nowMillis(),
        ),
      );
      notifyListeners();
      return categories.firstWhere((category) => category.id == categoryId);
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return null;
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
      await _mutateLedger(
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

  PlatformInt64 _nowMillis() =>
      PlatformInt64Util.from(DateTime.now().millisecondsSinceEpoch);

  String _slugify(String name) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'category-${DateTime.now().microsecondsSinceEpoch}' : slug;
  }

  /// Runs a ledger mutation and durably persists its appended event frame
  /// before updating [overview]. If the process dies before
  /// [EventStore.appendFrame] returns, the mutation was never durable and the
  /// next launch simply won't see it — there is no half-applied state to
  /// reconcile.
  Future<void> _mutateLedger(Future<LedgerMutation> Function() mutation) async {
    final result = await mutation();
    await _ledgerStore.appendFrame(result.appendedFrame);
    overview = result.overview;
  }

  /// Same durability protocol as [_mutateLedger], for the categories log.
  Future<void> _mutateCategories(
    Future<CategoryMutation> Function() mutation,
  ) async {
    final result = await mutation();
    await _categoryStore.appendFrame(result.appendedFrame);
    categories = result.categories;
  }
}
