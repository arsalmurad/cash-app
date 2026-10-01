import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/csv_transactions.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _RecordingController extends LedgerController {
  int writes = 0;
  @override
  Future<bool> record({
    required String title,
    required String amount,
    required EntryKind kind,
    required String accountId,
    String? categoryId,
    String? recurringId,
    String? rate,
  }) async {
    writes += 1;
    return true;
  }
}

void main() {
  test('malformed CSV is reported before importing any rows', () async {
    final controller = _RecordingController()
      ..overview = const LedgerOverview(
        balanceLabel: 'USD 0.00',
        accounts: [
          AccountView(
            id: 'everyday',
            name: 'Everyday',
            currencyCode: 'USD',
            balanceLabel: 'USD 0.00',
          ),
        ],
        transactions: [],
        transfers: [],
      );
    final summary = await controller.importTransactionsCsv(
      'Coffee,4.50,expense,Everyday,\n"unfinished',
    );
    expect(summary.imported, 0);
    expect(summary.errors.single, contains('unfinished'));
    expect(controller.writes, 0);
    final valid = await controller.importTransactionsCsv(
      'Coffee,4.50,expense,Everyday,\n',
    );
    expect(valid.imported, 1);
    expect(controller.writes, 1);
    controller.dispose();
  });
  group('parseCsv', () {
    test(
      'rejects unfinished or misplaced quotes rather than changing fields',
      () {
        for (final csv in ['"unfinished', 'ab"cd,1', '"closed"extra,1']) {
          expect(() => parseCsv(csv), throwsFormatException);
        }
      },
    );

    test('preserves empty quoted fields and embedded carriage returns', () {
      expect(parseCsv('""'), [
        [''],
      ]);
      expect(parseCsv(encodeCsvRow(['a\rb', ''])), [
        ['a\rb', ''],
      ]);
      expect(parseCsv('a,b\rc,d\r\ne,f'), [
        ['a', 'b'],
        ['c', 'd'],
        ['e', 'f'],
      ]);
    });

    test('splits plain rows on commas and newlines', () {
      final rows = parseCsv('a,b,c\n1,2,3\n');
      expect(rows, [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('handles quoted fields with embedded commas and doubled quotes', () {
      final rows = parseCsv('"hello, world","say ""hi"""\nplain,ok\n');
      expect(rows, [
        ['hello, world', 'say "hi"'],
        ['plain', 'ok'],
      ]);
    });

    test('handles a final row with no trailing newline', () {
      final rows = parseCsv('a,b\nc,d');
      expect(rows, [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });
  });

  group('encodeCsvField', () {
    test('leaves plain fields unquoted', () {
      expect(encodeCsvField('Groceries'), 'Groceries');
    });

    test('quotes and escapes fields containing commas or quotes', () {
      expect(encodeCsvField('a,b'), '"a,b"');
      expect(encodeCsvField('say "hi"'), '"say ""hi"""');
    });
  });

  group('buildTransactionsCsv', () {
    test('exports a header and one row per non-transfer transaction', () {
      const accounts = [
        AccountView(
          id: 'everyday',
          name: 'Everyday',
          currencyCode: 'USD',
          balanceLabel: 'USD 0.00',
        ),
      ];
      const categories = [
        CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
      ];
      const transactions = [
        TransactionView(
          id: 't1',
          accountId: 'everyday',
          title: 'Groceries',
          amountLabel: 'USD 12.34',
          isExpense: true,
          categoryId: 'food',
        ),
      ];

      final csv = buildTransactionsCsv(
        transactions: transactions,
        accounts: accounts,
        categories: categories,
      );

      expect(
        csv,
        'title,amount,kind,account,category\nGroceries,12.34,expense,Everyday,Food\n',
      );
    });
  });

  group('parseTransactionsCsv', () {
    const accounts = [
      AccountView(
        id: 'everyday',
        name: 'Everyday',
        currencyCode: 'USD',
        balanceLabel: 'USD 0.00',
      ),
    ];
    const categories = [
      CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
    ];

    test('parses a valid row, matching account and category by name', () {
      final rows = parseTransactionsCsv(
        'title,amount,kind,account,category\nGroceries,12.34,expense,Everyday,Food\n',
        accounts: accounts,
        categories: categories,
      );

      expect(rows, hasLength(1));
      expect(rows.single.isValid, isTrue);
      expect(rows.single.title, 'Groceries');
      expect(rows.single.amount, '12.34');
      expect(rows.single.isExpense, isTrue);
      expect(rows.single.accountId, 'everyday');
      expect(rows.single.categoryId, 'food');
    });

    test('accepts a CSV with no header row', () {
      final rows = parseTransactionsCsv(
        'Coffee,4.50,expense,Everyday,\n',
        accounts: accounts,
        categories: categories,
      );

      expect(rows, hasLength(1));
      expect(rows.single.title, 'Coffee');
      expect(rows.single.categoryId, isNull);
    });

    test('a blank category is not an error', () {
      final rows = parseTransactionsCsv(
        'Coffee,4.50,expense,Everyday,\n',
        accounts: accounts,
        categories: categories,
      );

      expect(rows.single.isValid, isTrue);
    });

    test('an unknown account is an error', () {
      final rows = parseTransactionsCsv(
        'Coffee,4.50,expense,Nonexistent,\n',
        accounts: accounts,
        categories: categories,
      );

      expect(rows.single.isValid, isFalse);
      expect(rows.single.error, contains('unknown account'));
    });

    test('an invalid kind is an error', () {
      final rows = parseTransactionsCsv(
        'Coffee,4.50,sideways,Everyday,\n',
        accounts: accounts,
        categories: categories,
      );

      expect(rows.single.isValid, isFalse);
      expect(rows.single.error, contains('expense'));
    });

    test('a missing title or amount is an error', () {
      final rows = parseTransactionsCsv(
        ',4.50,expense,Everyday,\ntitle,,expense,Everyday,\n',
        accounts: accounts,
        categories: categories,
      );

      expect(rows, hasLength(2));
      expect(rows[0].error, contains('title'));
      expect(rows[1].error, contains('amount'));
    });

    test('blank lines are ignored', () {
      final rows = parseTransactionsCsv(
        'title,amount,kind,account,category\n\nCoffee,4.50,expense,Everyday,\n\n',
        accounts: accounts,
        categories: categories,
      );

      expect(rows, hasLength(1));
    });
  });
}
