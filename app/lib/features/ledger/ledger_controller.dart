import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64, PlatformInt64Util, Uint8List;

import '../../data/rust/api/budgets.dart';
import '../../data/rust/api/budgets.dart' as budget_api show removeBudget;
import '../../data/rust/api/categories.dart';
import '../../data/rust/api/goals.dart';
import '../../data/rust/api/goals.dart' as goal_api show removeGoal;
import '../../data/rust/api/ledger.dart';
import '../../data/rust/api/recurring.dart';
import '../../data/rust/api/recurring.dart' as recurring_api show stopRecurring;
import '../../data/storage/actor_id.dart';
import '../../data/storage/event_store.dart';
import 'category_presets.dart';
import 'csv_transactions.dart';

class LedgerController extends ChangeNotifier {
  LedgerController({
    DeviceIdentity? identity,
    EventStore? ledgerStore,
    EventStore? categoryStore,
    EventStore? budgetStore,
    EventStore? goalStore,
    EventStore? recurringStore,
  }) : _identity = identity ?? DeviceIdentity(),
       _ledgerStore = ledgerStore ?? EventStore('ledger'),
       _categoryStore = categoryStore ?? EventStore('categories'),
       _budgetStore = budgetStore ?? EventStore('budgets'),
       _goalStore = goalStore ?? EventStore('goals'),
       _recurringStore = recurringStore ?? EventStore('recurring');

  final DeviceIdentity _identity;
  final EventStore _ledgerStore;
  final EventStore _categoryStore;
  final EventStore _budgetStore;
  final EventStore _goalStore;
  final EventStore _recurringStore;

  PersonalLedger? _ledger;
  CategoryBook? _categoryBook;
  BudgetBook? _budgetBook;
  GoalBook? _goalBook;
  RecurringBook? _recurringBook;
  LedgerOverview? overview;
  List<CategoryView> categories = [];
  List<BudgetView> budgets = [];
  List<GoalView> goals = [];
  List<UpcomingView> upcoming = [];
  bool isLoading = true;
  String? errorMessage;
  int _sequence = 0;
  Future<void> _mutationQueue = Future<void>.value();
  bool _writesDisabled = false;
  static const String _reportingCurrencyCode = 'USD';

  /// The currency every entry is also valued in, at a rate frozen on the entry.
  String get reportingCurrencyCode => _reportingCurrencyCode;

  /// Diagnostics from the most recent [initialize] load, mainly for tests:
  /// how many persisted events were recovered and whether the tail of the
  /// log was truncated (a torn write from a previous crash).
  int recoveredEventCount = 0;
  int truncatedBytes = 0;

  Future<void> initialize() async {
    try {
      _ensureWritable();
      var actorId = await _identity.readActorId();
      if (actorId == null) {
        actorId = generateActorId();
        await _identity.writeActorId(actorId);
      }

      final ledgerLogBytes = await _ledgerStore.readLog();
      final ledger = await loadPersonalLedger(
        actorId: actorId,
        reportingCurrencyCode: _reportingCurrencyCode,
        logBytes: ledgerLogBytes,
      );
      final report = await loadReport(ledger: ledger);
      await _repairTail(
        _ledgerStore,
        ledgerLogBytes.length,
        report.truncatedBytes,
      );
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
      await _repairTail(
        _categoryStore,
        categoryLogBytes.length,
        categoryReport.truncatedBytes,
      );
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

      final budgetLogBytes = await _budgetStore.readLog();
      final budgetBook = await loadBudgetBook(
        actorId: actorId,
        logBytes: budgetLogBytes,
      );
      final budgetReport = await budgetLoadReport(book: budgetBook);
      await _repairTail(
        _budgetStore,
        budgetLogBytes.length,
        budgetReport.truncatedBytes,
      );
      _budgetBook = budgetBook;

      final goalLogBytes = await _goalStore.readLog();
      final goalBook = await loadGoalBook(
        actorId: actorId,
        logBytes: goalLogBytes,
      );
      final goalReport = await goalLoadReport(book: goalBook);
      await _repairTail(
        _goalStore,
        goalLogBytes.length,
        goalReport.truncatedBytes,
      );
      _goalBook = goalBook;

      final recurringLogBytes = await _recurringStore.readLog();
      final recurringBook = await loadRecurringBook(
        actorId: actorId,
        logBytes: recurringLogBytes,
      );
      final recurringReport = await recurringLoadReport(book: recurringBook);
      await _repairTail(
        _recurringStore,
        recurringLogBytes.length,
        recurringReport.truncatedBytes,
      );
      _recurringBook = recurringBook;

      await _refreshBudgetProgress();
      await _refreshGoalProgress();
      await _refreshUpcoming();
    } catch (error) {
      _disableWrites();
      errorMessage = error.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _repairTail(
    EventStore store,
    int length,
    BigInt discarded,
  ) async {
    if (discarded != BigInt.zero) {
      await store.recoverPrefix(
        length - discarded.toInt(),
        expectedLength: length,
      );
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

  /// Renames and/or re-icons an existing category. `categoryId` must be an
  /// existing category's ID (not a new one to create) — [upsertCategory]
  /// replaces that record in place rather than adding a second one.
  Future<bool> updateCategory({
    required String categoryId,
    required String name,
    required String iconKey,
  }) async {
    final book = _categoryBook;
    if (book == null) {
      return false;
    }
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
      return true;
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  /// The exact rate to freeze on an entry in [account]'s currency. Accounts
  /// in the reporting currency always use 1:1; any other currency needs the
  /// user's typed [rate] (never guessed or carried over from another entry).
  Future<FxRatio> _resolveRate(AccountView account, String? rate) async {
    if (account.currencyCode == _reportingCurrencyCode) {
      return FxRatio(
        numerator: PlatformInt64Util.from(1),
        denominator: PlatformInt64Util.from(1),
      );
    }
    if (rate == null || rate.trim().isEmpty) {
      throw _EntryInputError(
        'Enter the ${account.currencyCode} to $_reportingCurrencyCode '
        'exchange rate',
      );
    }
    return fxRateFromDecimal(
      rate: rate,
      sourceCurrencyCode: account.currencyCode,
      targetCurrencyCode: _reportingCurrencyCode,
    );
  }

  Future<bool> record({
    required String title,
    required String amount,
    required EntryKind kind,
    required String accountId,
    String? categoryId,
    String? recurringId,
    String? rate,
    PlatformInt64? expectedOccurrenceMillis,
  }) async {
    final ledger = _ledger;
    final account = _findAccount(accountId);
    if (ledger == null || account == null) {
      return false;
    }
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final fx = await _resolveRate(account, rate);
      final now = DateTime.now();
      _sequence += 1;
      await _mutateLedger(() async {
        if (recurringId != null &&
            !upcoming.any(
              (current) =>
                  current.recurringId == recurringId &&
                  current.isExpense == (kind == EntryKind.expense) &&
                  current.occurrenceMillis.toInt() <=
                      DateTime.now().millisecondsSinceEpoch &&
                  (expectedOccurrenceMillis == null ||
                      current.occurrenceMillis == expectedOccurrenceMillis) &&
                  current.title == title.trim() &&
                  _amountFromLabel(current.amountLabel) == amount &&
                  current.accountId == accountId &&
                  current.categoryId == categoryId,
            )) {
          throw const _EntryInputError(
            'This reminder changed or stopped. Check Upcoming before recording.',
          );
        }
        return recordTransaction(
          ledger: ledger,
          transactionId: 'local-${now.microsecondsSinceEpoch}-$_sequence',
          accountId: accountId,
          kind: kind,
          amount: amount,
          currencyCode: account.currencyCode,
          fxNumerator: fx.numerator,
          fxDenominator: fx.denominator,
          title: title.trim(),
          categoryId: categoryId,
          recurringId: recurringId,
          wallClockMillis: PlatformInt64Util.from(now.millisecondsSinceEpoch),
        );
      });
      return true;
    } catch (error) {
      errorMessage = error.toString();
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Creates a new account. `currencyCode` is a 3-letter ISO 4217 code (e.g.
  /// `USD`, `EUR`, `JPY`); the Rust core validates it and rejects anything
  /// else.
  Future<bool> createAccount({
    required String name,
    required String currencyCode,
  }) async {
    final ledger = _ledger;
    if (ledger == null) {
      return false;
    }
    try {
      await _mutateLedger(
        () => addAccount(
          ledger: ledger,
          accountId: _slugify(name),
          name: name.trim(),
          currencyCode: currencyCode,
          wallClockMillis: _nowMillis(),
        ),
      );
      notifyListeners();
      return true;
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  /// Moves money from one account to another. `receivedAmount` may be
  /// omitted only when both accounts share a currency, in which case it
  /// defaults to `sentAmount`; a cross-currency transfer must state what
  /// actually arrived; see `EventKind::TransferRecorded` for why that isn't
  /// assumed to equal the sent amount converted at some rate.
  Future<bool> transfer({
    required String fromAccountId,
    required String toAccountId,
    required String sentAmount,
    String? receivedAmount,
    String title = 'Transfer',
    String? sentRate,
    String? receivedRate,
  }) async {
    final ledger = _ledger;
    final fromAccount = _findAccount(fromAccountId);
    final toAccount = _findAccount(toAccountId);
    if (ledger == null || fromAccount == null || toAccount == null) {
      return false;
    }
    final resolvedReceivedAmount = receivedAmount ?? sentAmount;
    if (receivedAmount == null &&
        fromAccount.currencyCode != toAccount.currencyCode) {
      errorMessage = 'Enter the amount received in ${toAccount.currencyCode}';
      notifyListeners();
      return false;
    }

    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final sentFx = await _resolveRate(fromAccount, sentRate);
      final receivedFx = await _resolveRate(toAccount, receivedRate);
      final now = DateTime.now();
      _sequence += 1;
      await _mutateLedger(
        () => recordTransfer(
          ledger: ledger,
          transferId: 'local-${now.microsecondsSinceEpoch}-$_sequence',
          fromAccountId: fromAccountId,
          toAccountId: toAccountId,
          sentAmount: sentAmount,
          sentCurrencyCode: fromAccount.currencyCode,
          sentFxNumerator: sentFx.numerator,
          sentFxDenominator: sentFx.denominator,
          receivedAmount: resolvedReceivedAmount,
          receivedCurrencyCode: toAccount.currencyCode,
          receivedFxNumerator: receivedFx.numerator,
          receivedFxDenominator: receivedFx.denominator,
          title: title.trim(),
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

  /// Creates or updates a budget and refreshes progress. `customPeriodDays`
  /// is required only when `period` is [BudgetPeriodKind.custom].
  Future<bool> addOrUpdateBudget({
    String? budgetId,
    required String name,
    String? categoryId,
    required String limitAmount,
    required BudgetPeriodKind period,
    int? customPeriodDays,
  }) async {
    final book = _budgetBook;
    if (book == null) {
      return false;
    }
    try {
      await _mutateBudgets(
        () => upsertBudget(
          book: book,
          budgetId: budgetId ?? _slugify(name),
          name: name.trim(),
          categoryId: categoryId,
          limitAmount: limitAmount,
          limitCurrencyCode: _reportingCurrencyCode,
          period: period,
          customPeriodDays: customPeriodDays,
          wallClockMillis: _nowMillis(),
        ),
      );
      notifyListeners();
      return true;
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  /// Creates or updates a goal and refreshes progress. A save goal must set
  /// `linkedAccountId` and leave `categoryId` unset; a spend goal must leave
  /// `linkedAccountId` unset (see [GoalKind]).
  Future<bool> addOrUpdateGoal({
    String? goalId,
    required String name,
    required GoalKind kind,
    required String targetAmount,
    String? linkedAccountId,
    String? categoryId,
    PlatformInt64? deadlineMillis,
  }) async {
    final book = _goalBook;
    if (book == null) {
      return false;
    }
    try {
      await _mutateGoals(
        () => upsertGoal(
          book: book,
          goalId: goalId ?? _slugify(name),
          name: name.trim(),
          kind: kind,
          targetAmount: targetAmount,
          targetCurrencyCode: _reportingCurrencyCode,
          linkedAccountId: linkedAccountId,
          categoryId: categoryId,
          deadlineMillis: deadlineMillis,
          wallClockMillis: _nowMillis(),
        ),
      );
      notifyListeners();
      return true;
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  /// Creates or updates a recurring rule and refreshes the upcoming list.
  Future<bool> addOrUpdateRecurring({
    String? recurringId,
    required String title,
    required RecurringKind kind,
    required String amount,
    required String accountId,
    String? categoryId,
    required RecurringFrequency frequency,
    required PlatformInt64 startMillis,
  }) async {
    final book = _recurringBook;
    final account = _findAccount(accountId);
    if (book == null || account == null) {
      return false;
    }
    try {
      await _mutateRecurring(
        () => upsertRecurring(
          book: book,
          recurringId: recurringId ?? _slugify(title),
          title: title.trim(),
          kind: kind,
          amount: amount,
          currencyCode: account.currencyCode,
          accountId: accountId,
          categoryId: categoryId,
          frequency: frequency,
          startMillis: startMillis,
          wallClockMillis: _nowMillis(),
        ),
      );
      notifyListeners();
      return true;
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> removeBudget(String id) async {
    final book = _budgetBook;
    if (book == null) return false;
    return _removeDefinition(
      () => _mutateBudgets(
        () => budget_api.removeBudget(
          book: book,
          budgetId: id,
          wallClockMillis: _nowMillis(),
        ),
      ),
    );
  }

  Future<bool> removeGoal(String id) async {
    final book = _goalBook;
    if (book == null) return false;
    return _removeDefinition(
      () => _mutateGoals(
        () => goal_api.removeGoal(
          book: book,
          goalId: id,
          wallClockMillis: _nowMillis(),
        ),
      ),
    );
  }

  Future<bool> stopRecurring(String id) async {
    final book = _recurringBook;
    if (book == null) return false;
    return _removeDefinition(
      () => _mutateRecurring(
        () => recurring_api.stopRecurring(
          book: book,
          recurringId: id,
          wallClockMillis: _nowMillis(),
        ),
      ),
    );
  }

  Future<bool> _removeDefinition(Future<void> Function() action) async {
    errorMessage = null;
    try {
      await action();
      notifyListeners();
      return true;
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  /// Records an upcoming occurrence as a real transaction, tagged with its
  /// recurring rule so [_refreshUpcoming] advances past it next time.
  Future<bool> recordUpcoming(UpcomingView occurrence, {String? rate}) async {
    return record(
      rate: rate,
      title: occurrence.title,
      amount: _amountFromLabel(occurrence.amountLabel),
      kind: occurrence.isExpense ? EntryKind.expense : EntryKind.income,
      accountId: occurrence.accountId,
      categoryId: occurrence.categoryId,
      recurringId: occurrence.recurringId,
      expectedOccurrenceMillis: occurrence.occurrenceMillis,
    );
  }

  /// An amount label is always `"<CODE> <amount>"`; the amount alone is what
  /// `record` accepts back (mirrors `csv_transactions._amountFromLabel`).
  String _amountFromLabel(String amountLabel) {
    final spaceIndex = amountLabel.indexOf(' ');
    return spaceIndex < 0 ? amountLabel : amountLabel.substring(spaceIndex + 1);
  }

  /// Exports every non-transfer transaction as CSV text (see
  /// `csv_transactions.dart`); `null` when there's nothing loaded yet.
  String? exportTransactionsCsv() {
    final currentOverview = overview;
    if (currentOverview == null) {
      return null;
    }
    return buildTransactionsCsv(
      transactions: currentOverview.transactions,
      accounts: currentOverview.accounts,
      categories: categories,
    );
  }

  /// Imports transactions from CSV text, recording each valid row through
  /// [record] (so every imported transaction goes through the same
  /// validation and durability path as one entered by hand). Returns how
  /// many rows were imported and the errors for rows that weren't.
  Future<CsvImportSummary> importTransactionsCsv(String csvText) async {
    final currentOverview = overview;
    if (currentOverview == null) {
      return const CsvImportSummary(imported: 0, errors: ['ledger not loaded']);
    }
    final List<CsvImportRow> rows;
    try {
      rows = parseTransactionsCsv(
        csvText,
        accounts: currentOverview.accounts,
        categories: categories,
      );
    } on FormatException catch (error) {
      // Parse the entire file before the first mutation. Malformed quoting
      // cannot silently alter a title/account or leave a partial import.
      return CsvImportSummary(imported: 0, errors: [error.message]);
    }
    var imported = 0;
    final errors = <String>[];
    for (final row in rows) {
      if (!row.isValid) {
        errors.add('line ${row.lineNumber}: ${row.error}');
        continue;
      }
      final saved = await record(
        title: row.title!,
        amount: row.amount!,
        kind: row.isExpense! ? EntryKind.expense : EntryKind.income,
        accountId: row.accountId!,
        categoryId: row.categoryId,
      );
      if (saved) {
        imported += 1;
      } else {
        errors.add(
          'line ${row.lineNumber}: ${errorMessage ?? "could not save"}',
        );
      }
    }
    return CsvImportSummary(imported: imported, errors: errors);
  }

  PlatformInt64 _nowMillis() =>
      PlatformInt64Util.from(DateTime.now().millisecondsSinceEpoch);

  AccountView? _findAccount(String id) {
    for (final account in overview?.accounts ?? const <AccountView>[]) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
  }

  String _slugify(String name) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty
        ? 'category-${DateTime.now().microsecondsSinceEpoch}'
        : slug;
  }

  void _ensureWritable() {
    if (_writesDisabled) {
      throw StateError(
        'Restart the app to reload saved data before continuing.',
      );
    }
  }

  void _disableWrites() {
    _writesDisabled = true;
    // Rust mutations precede their append. These books may contain an event
    // whose durability is unknown; never consult or mutate them again.
    // Keep the last confirmed display values available to the user.
    _ledger = null;
    _categoryBook = null;
    _budgetBook = null;
    _goalBook = null;
    _recurringBook = null;
  }

  Future<void> _runMutation(Future<void> Function() action) {
    final next = _mutationQueue.then<void>((_) async {
      _ensureWritable();
      await action();
    });
    // Invalid input must not poison the queue, but queued actions still check
    // the fail-closed flag before touching any captured Rust handle.
    _mutationQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _saveFrame(EventStore store, Uint8List frame) async {
    try {
      await store.appendFrame(frame);
    } catch (error) {
      _disableWrites();
      throw StateError(
        'Save could not be confirmed. Restart the app and check saved data '
        'before retrying, to avoid duplicates. ($error)',
      );
    }
  }

  /// Serialize mutation, durable append, and display refresh as one operation.
  /// A failed append may have written nothing, a torn frame, or a complete
  /// frame. Stop further writes and let startup recover the durable truth.
  Future<void> _mutateLedger(Future<LedgerMutation> Function() mutation) =>
      _runMutation(() async {
        final result = await mutation();
        await _saveFrame(_ledgerStore, result.appendedFrame);
        overview = result.overview;
        await _refreshBudgetProgress();
        await _refreshGoalProgress();
        await _refreshUpcoming();
      });

  /// Same durability protocol as [_mutateLedger], for the categories log.
  Future<void> _mutateCategories(
    Future<CategoryMutation> Function() mutation,
  ) => _runMutation(() async {
    final result = await mutation();
    await _saveFrame(_categoryStore, result.appendedFrame);
    categories = result.categories;
  });

  /// Same durability protocol as [_mutateLedger], for the budgets log.
  Future<void> _mutateBudgets(Future<BudgetMutation> Function() mutation) =>
      _runMutation(() async {
        final result = await mutation();
        await _saveFrame(_budgetStore, result.appendedFrame);
        await _refreshBudgetProgress();
      });

  /// Recomputes every budget's progress against the ledger's current state.
  /// Called after any ledger mutation (an expense changes spend totals) and
  /// after any budget mutation (a new/edited budget needs its own progress).
  Future<void> _refreshBudgetProgress() async {
    final ledger = _ledger;
    final book = _budgetBook;
    if (ledger == null || book == null) {
      return;
    }
    budgets = await budgetProgress(
      ledger: ledger,
      book: book,
      nowMillis: _nowMillis(),
    );
  }

  /// Same durability protocol as [_mutateLedger], for the goals log.
  Future<void> _mutateGoals(Future<GoalMutation> Function() mutation) =>
      _runMutation(() async {
        final result = await mutation();
        await _saveFrame(_goalStore, result.appendedFrame);
        await _refreshGoalProgress();
      });

  /// Recomputes every goal's progress against the ledger's current state.
  /// Called after any ledger mutation (an expense or a linked account's
  /// balance change moves a goal's progress) and after any goal mutation.
  Future<void> _refreshGoalProgress() async {
    final ledger = _ledger;
    final book = _goalBook;
    if (ledger == null || book == null) {
      return;
    }
    goals = await goalProgress(ledger: ledger, book: book);
  }

  /// Same durability protocol as [_mutateLedger], for the recurring-rule log.
  Future<void> _mutateRecurring(
    Future<RecurringMutation> Function() mutation,
  ) => _runMutation(() async {
    final result = await mutation();
    await _saveFrame(_recurringStore, result.appendedFrame);
    await _refreshUpcoming();
  });

  /// Recomputes every recurring rule's next occurrence. Called after any
  /// ledger mutation (recording an occurrence advances its rule) and after
  /// any recurring mutation (a new/edited rule needs its own occurrence).
  Future<void> _refreshUpcoming() async {
    final ledger = _ledger;
    final book = _recurringBook;
    if (ledger == null || book == null) {
      return;
    }
    upcoming = await recurringSchedule(
      ledger: ledger,
      book: book,
      nowMillis: _nowMillis(),
    );
  }
}

/// A problem with what the user typed, reported as-is (without the
/// "Exception:" prefix a bare [Exception] would add) in the snackbar.
class _EntryInputError implements Exception {
  const _EntryInputError(this.message);

  final String message;

  @override
  String toString() => message;
}
