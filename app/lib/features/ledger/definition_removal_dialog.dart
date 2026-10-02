import 'package:flutter/material.dart';

/// Removes a definition, never a money transaction or saved history.
class DefinitionRemovalDialog extends StatelessWidget {
  const DefinitionRemovalDialog({
    required this.kind,
    required this.name,
    super.key,
  });

  final String kind;
  final String name;

  bool get _isRecurring => kind == 'recurring rule';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_isRecurring ? 'Stop recurring rule?' : 'Remove $kind?'),
    content: Text(
      _isRecurring
          ? 'Stop future reminders for "$name". Transactions already recorded stay in your ledger.'
          : 'Remove "$name" from your $kind list. Your transactions and balances stay unchanged.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(_isRecurring ? 'Keep recurring rule' : 'Keep $kind'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(_isRecurring ? 'Stop recurring rule' : 'Remove $kind'),
      ),
    ],
  );
}
