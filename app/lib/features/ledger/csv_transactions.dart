import '../../data/rust/api/categories.dart';
import '../../data/rust/api/ledger.dart';

/// A minimal RFC 4180 CSV codec. Not a general-purpose CSV library — just
/// enough to round-trip this app's own export format, so pulling in a
/// dependency for it was not worth it (see `docs/DECISIONS.md`).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var afterQuote = false;
  var fieldStarted = false;
  var i = 0;
  var sawAnyField = false;

  void endField() {
    row.add(field.toString());
    field.clear();
    afterQuote = false;
    fieldStarted = false;
    sawAnyField = true;
  }

  void endRow() {
    endField();
    rows.add(row);
    row = [];
    sawAnyField = false;
  }

  while (i < text.length) {
    final char = text[i];
    if (inQuotes) {
      if (char == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        afterQuote = true;
        i += 1;
        continue;
      }
      field.write(char);
      i += 1;
      continue;
    }
    if (afterQuote && char != ',' && char != '\r' && char != '\n') {
      throw FormatException(
        'Unexpected text after a closing CSV quote',
        text,
        i,
      );
    }
    switch (char) {
      case '"':
        if (fieldStarted) {
          throw FormatException('A CSV quote must start a field', text, i);
        }
        fieldStarted = true;
        inQuotes = true;
        i += 1;
      case ',':
        endField();
        i += 1;
      case '\r':
        endRow();
        i += 1;
        if (i < text.length && text[i] == '\n') i += 1;
      case '\n':
        endRow();
        i += 1;
      default:
        fieldStarted = true;
        field.write(char);
        i += 1;
    }
  }
  if (inQuotes) {
    throw FormatException(
      'The CSV contains an unfinished quoted field',
      text,
      i,
    );
  }
  if (fieldStarted || field.isNotEmpty || sawAnyField) {
    endRow();
  }
  return rows;
}

String encodeCsvField(String value) {
  final needsQuoting =
      value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r');
  if (!needsQuoting) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}

String encodeCsvRow(List<String> fields) =>
    fields.map(encodeCsvField).join(',');

const csvColumns = ['title', 'amount', 'kind', 'account', 'category'];

/// Exports active non-transfer transactions as CSV. Removed entries stay in
/// the ledger history, not this importable export. Transfers are left out:
/// they move money between two of this ledger's own accounts rather than
/// describing income or an expense, so they don't fit this row shape (see
/// `docs/DECISIONS.md`).
String buildTransactionsCsv({
  required List<TransactionView> transactions,
  required List<AccountView> accounts,
  required List<CategoryView> categories,
}) {
  final accountNames = {
    for (final account in accounts) account.id: account.name,
  };
  final categoryNames = {
    for (final category in categories) category.id: category.name,
  };
  final buffer = StringBuffer(encodeCsvRow(csvColumns));
  buffer.write('\n');
  for (final transaction in transactions.where((entry) => !entry.voided)) {
    buffer.write(
      encodeCsvRow([
        transaction.title,
        _amountFromLabel(transaction.amountLabel),
        transaction.isExpense ? 'expense' : 'income',
        accountNames[transaction.accountId] ?? transaction.accountId,
        transaction.categoryId == null
            ? ''
            : (categoryNames[transaction.categoryId] ??
                  transaction.categoryId!),
      ]),
    );
    buffer.write('\n');
  }
  return buffer.toString();
}

/// A transaction amount label is always `"<CODE> <amount>"` (see
/// `Currency::format_minor_units`); the amount alone is what
/// `record_transaction` accepts back.
String _amountFromLabel(String amountLabel) {
  final spaceIndex = amountLabel.indexOf(' ');
  return spaceIndex < 0 ? amountLabel : amountLabel.substring(spaceIndex + 1);
}

/// The result of importing a CSV: how many rows were recorded, and the
/// error message for each row that wasn't (unparseable or rejected by the
/// ledger).
class CsvImportSummary {
  const CsvImportSummary({required this.imported, required this.errors});

  final int imported;
  final List<String> errors;
}

/// One row parsed from an imported CSV, resolved against the ledger's
/// current accounts and categories. `error` is set when the row cannot be
/// imported at all (unknown kind, blank title/amount, or an account name
/// that doesn't match); a category name that doesn't match is not an error
/// — the transaction is just imported without a category.
class CsvImportRow {
  const CsvImportRow({
    required this.lineNumber,
    this.title,
    this.amount,
    this.isExpense,
    this.accountId,
    this.categoryId,
    this.error,
  });

  final int lineNumber;
  final String? title;
  final String? amount;
  final bool? isExpense;
  final String? accountId;
  final String? categoryId;
  final String? error;

  bool get isValid => error == null;
}

/// Parses an imported CSV against the ledger's current accounts and
/// categories. The header row (if present) is detected by its first column
/// reading `title` (case-insensitive) and skipped; a CSV with no header is
/// also accepted, since the column order is fixed either way.
List<CsvImportRow> parseTransactionsCsv(
  String csvText, {
  required List<AccountView> accounts,
  required List<CategoryView> categories,
}) {
  final accountIdsByName = {
    for (final account in accounts) account.name.toLowerCase(): account.id,
  };
  final accountIds = {for (final account in accounts) account.id};
  final categoryIdsByName = {
    for (final category in categories) category.name.toLowerCase(): category.id,
  };
  final categoryIds = {for (final category in categories) category.id};

  final rows = parseCsv(csvText)
      .where((row) => row.any((f) => f.trim().isNotEmpty))
      .toList();
  if (rows.isEmpty) {
    return const [];
  }
  var startIndex = 0;
  if (rows.first.isNotEmpty &&
      rows.first.first.trim().toLowerCase() == 'title') {
    startIndex = 1;
  }

  final results = <CsvImportRow>[];
  for (var i = startIndex; i < rows.length; i++) {
    final lineNumber = i + 1;
    final row = rows[i];
    if (row.length < 4) {
      results.add(
        CsvImportRow(
          lineNumber: lineNumber,
          error: 'expected at least title,amount,kind,account',
        ),
      );
      continue;
    }
    final title = row[0].trim();
    final amount = row[1].trim();
    final kindText = row[2].trim().toLowerCase();
    final accountText = row[3].trim();
    final categoryText = row.length > 4 ? row[4].trim() : '';

    if (title.isEmpty) {
      results.add(CsvImportRow(lineNumber: lineNumber, error: 'missing title'));
      continue;
    }
    if (amount.isEmpty) {
      results.add(
        CsvImportRow(lineNumber: lineNumber, error: 'missing amount'),
      );
      continue;
    }
    bool isExpense;
    if (kindText == 'expense') {
      isExpense = true;
    } else if (kindText == 'income') {
      isExpense = false;
    } else {
      results.add(
        CsvImportRow(
          lineNumber: lineNumber,
          error: 'kind must be "expense" or "income", got "$kindText"',
        ),
      );
      continue;
    }
    final accountId = accountIds.contains(accountText)
        ? accountText
        : accountIdsByName[accountText.toLowerCase()];
    if (accountId == null) {
      results.add(
        CsvImportRow(
          lineNumber: lineNumber,
          error: 'unknown account "$accountText"',
        ),
      );
      continue;
    }
    String? categoryId;
    if (categoryText.isNotEmpty) {
      categoryId = categoryIds.contains(categoryText)
          ? categoryText
          : categoryIdsByName[categoryText.toLowerCase()];
    }

    results.add(
      CsvImportRow(
        lineNumber: lineNumber,
        title: title,
        amount: amount,
        isExpense: isExpense,
        accountId: accountId,
        categoryId: categoryId,
      ),
    );
  }
  return results;
}
