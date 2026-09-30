import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/rust/api/categories.dart';
import '../../data/rust/api/ledger.dart';
import 'category_edit_dialog.dart';
import 'category_presets.dart';

/// What `AddTransactionSheet` returns: either a single-account transaction
/// or a transfer between two accounts. The two need different fields (a
/// transfer has no category, and needs a second account), so they're kept
/// as separate types under one sealed result rather than one struct with
/// optional fields for whichever mode wasn't used.
sealed class EntryDraft {
  const EntryDraft();
}

class TransactionDraft extends EntryDraft {
  const TransactionDraft({
    required this.title,
    required this.amount,
    required this.kind,
    required this.accountId,
    this.categoryId,
    this.rate,
  });

  final String title;
  final String amount;
  final EntryKind kind;
  final String accountId;
  final String? categoryId;

  /// Reporting-currency units per one unit of the account's currency, as
  /// typed. Only set when the account isn't in the reporting currency.
  final String? rate;
}

class TransferDraft extends EntryDraft {
  const TransferDraft({
    required this.fromAccountId,
    required this.toAccountId,
    required this.sentAmount,
    this.receivedAmount,
    required this.title,
    this.sentRate,
    this.receivedRate,
  });

  final String fromAccountId;
  final String toAccountId;
  final String sentAmount;

  /// Only set (and only needed) when the two accounts don't share a
  /// currency; see `LedgerController.transfer`.
  final String? receivedAmount;
  final String title;

  /// Typed rate for each leg; only set for a leg whose account isn't in the
  /// reporting currency.
  final String? sentRate;
  final String? receivedRate;
}

enum _EntryMode { expense, income, transfer }

class AddTransactionSheet extends StatefulWidget {
  const AddTransactionSheet({
    required this.accounts,
    required this.reportingCurrencyCode,
    required this.categories,
    required this.onSuggestCategory,
    required this.onAddCategory,
    super.key,
  });

  final List<AccountView> accounts;

  /// The ledger's reporting currency. Entries on accounts in any other
  /// currency need an exchange rate to it, frozen on the entry.
  final String reportingCurrencyCode;
  final List<CategoryView> categories;
  final Future<String?> Function(String title) onSuggestCategory;
  final Future<CategoryView?> Function(String name, String iconKey)
  onAddCategory;

  @override
  State<AddTransactionSheet> createState() => _AddTransactionSheetState();
}

class _AddTransactionSheetState extends State<AddTransactionSheet> {
  final formKey = GlobalKey<FormState>();
  final titleController = TextEditingController();
  final amountController = TextEditingController();
  final receivedAmountController = TextEditingController();
  final rateController = TextEditingController();
  final sentRateController = TextEditingController();
  final receivedRateController = TextEditingController();
  _EntryMode mode = _EntryMode.expense;
  String? categoryId;
  bool categoryManuallyChosen = false;
  Timer? suggestionDebounce;
  late List<CategoryView> categories = widget.categories;
  String? accountId;
  String? fromAccountId;
  String? toAccountId;

  @override
  void initState() {
    super.initState();
    if (categories.isNotEmpty) {
      categoryId = categories.first.id;
    }
    if (widget.accounts.isNotEmpty) {
      accountId = widget.accounts.first.id;
      fromAccountId = widget.accounts.first.id;
      toAccountId = widget.accounts
          .firstWhere(
            (account) => account.id != fromAccountId,
            orElse: () => widget.accounts.first,
          )
          .id;
    }
    titleController.addListener(_onTitleChanged);
  }

  @override
  void dispose() {
    suggestionDebounce?.cancel();
    titleController.removeListener(_onTitleChanged);
    titleController.dispose();
    amountController.dispose();
    receivedAmountController.dispose();
    rateController.dispose();
    sentRateController.dispose();
    receivedRateController.dispose();
    super.dispose();
  }

  void _onTitleChanged() {
    // "Custom titles that auto-assign on repeat": once the user has picked a
    // category themselves, stop overriding their choice.
    if (categoryManuallyChosen || mode == _EntryMode.transfer) {
      return;
    }
    suggestionDebounce?.cancel();
    final title = titleController.text;
    suggestionDebounce = Timer(const Duration(milliseconds: 400), () async {
      final suggested = await widget.onSuggestCategory(title);
      if (!mounted || suggested == null || categoryManuallyChosen) {
        return;
      }
      if (categories.any((category) => category.id == suggested)) {
        setState(() => categoryId = suggested);
      }
    });
  }

  AccountView? _accountById(String? id) {
    for (final account in widget.accounts) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
  }

  bool _needsRate(String? accountId) {
    final account = _accountById(accountId);
    return account != null &&
        account.currencyCode != widget.reportingCurrencyCode;
  }

  /// A rate field for [accountId]'s currency, or no widgets when that
  /// account is already in the reporting currency.
  List<Widget> _rateField({
    required Key key,
    required TextEditingController controller,
    required String? accountId,
  }) {
    if (!_needsRate(accountId)) {
      return const [];
    }
    final currency = _accountById(accountId)!.currencyCode;
    return [
      const SizedBox(height: 12),
      TextFormField(
        key: key,
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Exchange rate',
          helperText:
              '${widget.reportingCurrencyCode} per 1 $currency, frozen on '
              'this entry',
          hintText: '1.0000',
        ),
        validator: (value) => value == null || value.trim().isEmpty
            ? 'Enter the exchange rate'
            : null,
      ),
    ];
  }

  bool get _transferCrossesCurrencies {
    final from = _accountById(fromAccountId);
    final to = _accountById(toAccountId);
    return from != null && to != null && from.currencyCode != to.currencyCode;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottomInset),
        child: Form(
          key: formKey,
          // Scrollable so the sheet stays usable on short viewports (a phone
          // in landscape, or with the keyboard up) instead of overflowing.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Add entry',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                SegmentedButton<_EntryMode>(
                  segments: const [
                    ButtonSegment(
                      value: _EntryMode.expense,
                      icon: Icon(Icons.arrow_upward_rounded),
                      label: Text('Expense'),
                    ),
                    ButtonSegment(
                      value: _EntryMode.income,
                      icon: Icon(Icons.arrow_downward_rounded),
                      label: Text('Income'),
                    ),
                    ButtonSegment(
                      value: _EntryMode.transfer,
                      icon: Icon(Icons.swap_horiz_rounded),
                      label: Text('Transfer'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (selection) {
                    setState(() => mode = selection.first);
                  },
                ),
                const SizedBox(height: 16),
                if (mode == _EntryMode.transfer)
                  ..._transferFields()
                else
                  ..._transactionFields(),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    mode == _EntryMode.transfer
                        ? 'Add transfer'
                        : 'Add transaction',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _transactionFields() {
    return [
      TextFormField(
        controller: titleController,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Title'),
        validator: (value) =>
            value == null || value.trim().isEmpty ? 'Enter a title' : null,
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: amountController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Amount',
          prefixText: '${_accountById(accountId)?.currencyCode ?? ''} ',
          hintText: '0.00',
        ),
        validator: (value) =>
            value == null || value.trim().isEmpty ? 'Enter an amount' : null,
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const Key('accountDropdown'),
        initialValue: accountId,
        decoration: const InputDecoration(labelText: 'Account'),
        items: [
          for (final account in widget.accounts)
            DropdownMenuItem(value: account.id, child: Text(account.name)),
        ],
        onChanged: (value) => setState(() => accountId = value),
      ),
      ..._rateField(
        key: const Key('rateField'),
        controller: rateController,
        accountId: accountId,
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const Key('categoryDropdown'),
        initialValue: categoryId,
        decoration: const InputDecoration(labelText: 'Category'),
        items: [
          for (final category in categories)
            DropdownMenuItem(
              value: category.id,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(categoryIcon(category.iconKey), size: 18),
                  const SizedBox(width: 8),
                  Text(category.name),
                ],
              ),
            ),
          const DropdownMenuItem(
            value: _addCategoryValue,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 18),
                SizedBox(width: 8),
                Text('New category'),
              ],
            ),
          ),
        ],
        onChanged: (value) async {
          if (value == _addCategoryValue) {
            await _promptNewCategory();
            return;
          }
          setState(() {
            categoryId = value;
            categoryManuallyChosen = true;
          });
        },
      ),
    ];
  }

  List<Widget> _transferFields() {
    return [
      DropdownButtonFormField<String>(
        key: const Key('fromAccountDropdown'),
        initialValue: fromAccountId,
        decoration: const InputDecoration(labelText: 'From account'),
        items: [
          for (final account in widget.accounts)
            DropdownMenuItem(value: account.id, child: Text(account.name)),
        ],
        onChanged: (value) => setState(() => fromAccountId = value),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const Key('toAccountDropdown'),
        initialValue: toAccountId,
        decoration: const InputDecoration(labelText: 'To account'),
        items: [
          for (final account in widget.accounts)
            DropdownMenuItem(value: account.id, child: Text(account.name)),
        ],
        onChanged: (value) => setState(() => toAccountId = value),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: amountController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Amount sent',
          prefixText: '${_accountById(fromAccountId)?.currencyCode ?? ''} ',
          hintText: '0.00',
        ),
        validator: (value) =>
            value == null || value.trim().isEmpty ? 'Enter an amount' : null,
      ),
      ..._rateField(
        key: const Key('sentRateField'),
        controller: sentRateController,
        accountId: fromAccountId,
      ),
      if (_transferCrossesCurrencies) ...[
        const SizedBox(height: 12),
        TextFormField(
          controller: receivedAmountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Amount received',
            prefixText: '${_accountById(toAccountId)?.currencyCode ?? ''} ',
            hintText: '0.00',
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Enter what actually arrived'
              : null,
        ),
      ],
      ..._rateField(
        key: const Key('receivedRateField'),
        controller: receivedRateController,
        accountId: toAccountId,
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: titleController,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Title (optional)',
          hintText: 'Transfer',
        ),
      ),
    ];
  }

  static const _addCategoryValue = '__add_category__';

  Future<void> _promptNewCategory() async {
    final draft = await showDialog<CategoryDraft>(
      context: context,
      builder: (context) => const CategoryEditDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }
    final created = await widget.onAddCategory(draft.name, draft.iconKey);
    if (!mounted || created == null) {
      return;
    }
    setState(() {
      categories = [...categories, created];
      categoryId = created.id;
      categoryManuallyChosen = true;
    });
  }

  void _submit() {
    if (!formKey.currentState!.validate()) {
      return;
    }
    if (mode == _EntryMode.transfer) {
      if (fromAccountId == null ||
          toAccountId == null ||
          fromAccountId == toAccountId) {
        return;
      }
      Navigator.pop(
        context,
        TransferDraft(
          fromAccountId: fromAccountId!,
          toAccountId: toAccountId!,
          sentAmount: amountController.text.trim(),
          receivedAmount: _transferCrossesCurrencies
              ? receivedAmountController.text.trim()
              : null,
          title: titleController.text.trim().isEmpty
              ? 'Transfer'
              : titleController.text.trim(),
          sentRate: _needsRate(fromAccountId)
              ? sentRateController.text.trim()
              : null,
          receivedRate: _needsRate(toAccountId)
              ? receivedRateController.text.trim()
              : null,
        ),
      );
      return;
    }
    if (accountId == null) {
      return;
    }
    Navigator.pop(
      context,
      TransactionDraft(
        title: titleController.text,
        amount: amountController.text.trim(),
        kind: mode == _EntryMode.income ? EntryKind.income : EntryKind.expense,
        accountId: accountId!,
        categoryId: categoryId,
        rate: _needsRate(accountId) ? rateController.text.trim() : null,
      ),
    );
  }
}
