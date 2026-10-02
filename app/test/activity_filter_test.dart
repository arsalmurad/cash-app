import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/activity_filter.dart';

const _categories = [
  CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
  CategoryView(id: 'transport', name: 'Transport', iconKey: 'directions_car'),
];

const _groceries = TransactionView(
  id: 't1',
  accountId: 'everyday',
  title: 'Groceries',
  amountLabel: 'USD 12.34',
  voided: false,
  isExpense: true,
  categoryId: 'food',
);

const _paycheck = TransactionView(
  id: 't2',
  accountId: 'everyday',
  title: 'Paycheck',
  amountLabel: 'USD 2000.00',
  voided: false,
  isExpense: false,
  categoryId: null,
);

const _bus = TransactionView(
  id: 't3',
  accountId: 'savings',
  title: 'Bus fare',
  amountLabel: 'USD 2.50',
  voided: false,
  isExpense: true,
  categoryId: 'transport',
);

const _transactions = [_groceries, _paycheck, _bus];

const _transfer = TransferView(
  id: 'x1',
  title: 'Move to savings',
  fromAccountId: 'everyday',
  toAccountId: 'savings',
  sentLabel: 'USD 100.00',
  receivedLabel: 'USD 100.00',
);

void main() {
  test('an inactive filter is a no-op', () {
    const filter = ActivityFilter();
    expect(filter.isActive, isFalse);
    expect(
      filter.applyToTransactions(_transactions, _categories),
      _transactions,
    );
    expect(filter.applyToTransfers([_transfer]), [_transfer]);
  });

  test('query matches title case-insensitively', () {
    const filter = ActivityFilter(query: 'groc');
    expect(filter.isActive, isTrue);
    expect(filter.applyToTransactions(_transactions, _categories), [
      _groceries,
    ]);
  });

  test('query matches the resolved category name, not just the title', () {
    const filter = ActivityFilter(query: 'transport');
    expect(filter.applyToTransactions(_transactions, _categories), [_bus]);
  });

  test('kind filter narrows to expense, income, or transfer', () {
    expect(
      const ActivityFilter(kind: ActivityKindFilter.expense)
          .applyToTransactions(_transactions, _categories),
      [_groceries, _bus],
    );
    expect(
      const ActivityFilter(kind: ActivityKindFilter.income)
          .applyToTransactions(_transactions, _categories),
      [_paycheck],
    );
    expect(
      const ActivityFilter(kind: ActivityKindFilter.transfer)
          .applyToTransactions(_transactions, _categories),
      isEmpty,
    );
    expect(
      const ActivityFilter(kind: ActivityKindFilter.transfer)
          .applyToTransfers([_transfer]),
      [_transfer],
    );
    expect(
      const ActivityFilter(kind: ActivityKindFilter.expense)
          .applyToTransfers([_transfer]),
      isEmpty,
    );
  });

  test('account filter matches a transaction\'s own account', () {
    const filter = ActivityFilter(accountId: 'savings');
    expect(filter.applyToTransactions(_transactions, _categories), [_bus]);
  });

  test('account filter matches a transfer on either leg', () {
    expect(
      const ActivityFilter(accountId: 'everyday').applyToTransfers([_transfer]),
      [_transfer],
    );
    expect(
      const ActivityFilter(accountId: 'savings').applyToTransfers([_transfer]),
      [_transfer],
    );
    expect(
      const ActivityFilter(accountId: 'other').applyToTransfers([_transfer]),
      isEmpty,
    );
  });

  test('copyWith replaces query, kind, and clears accountId via callback', () {
    const filter = ActivityFilter(query: 'a', accountId: 'everyday');
    final cleared = filter.copyWith(accountId: () => null);
    expect(cleared.accountId, isNull);
    expect(cleared.query, 'a');

    final requeried = filter.copyWith(query: 'b');
    expect(requeried.query, 'b');
    expect(requeried.accountId, 'everyday');
  });
}
