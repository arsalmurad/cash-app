import 'package:flutter/material.dart';

/// Asks for the exchange rate to freeze on an entry made without a form of
/// its own (e.g. recording a recurring occurrence on a foreign-currency
/// account). Pops the typed rate, or `null` if cancelled; the Rust core
/// validates and parses it.
class ExchangeRateDialog extends StatefulWidget {
  const ExchangeRateDialog({
    required this.sourceCurrencyCode,
    required this.reportingCurrencyCode,
    super.key,
  });

  final String sourceCurrencyCode;
  final String reportingCurrencyCode;

  @override
  State<ExchangeRateDialog> createState() => _ExchangeRateDialogState();
}

class _ExchangeRateDialogState extends State<ExchangeRateDialog> {
  final formKey = GlobalKey<FormState>();
  final rateController = TextEditingController();

  @override
  void dispose() {
    rateController.dispose();
    super.dispose();
  }

  void _submit() {
    if (formKey.currentState!.validate()) {
      Navigator.pop(context, rateController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exchange rate'),
      content: Form(
        key: formKey,
        child: TextFormField(
          controller: rateController,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Exchange rate',
            helperText:
                '${widget.reportingCurrencyCode} per 1 '
                '${widget.sourceCurrencyCode}, frozen on this entry',
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Enter the exchange rate'
              : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Use rate')),
      ],
    );
  }
}
