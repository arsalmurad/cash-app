import 'package:flutter/material.dart';

import '../../data/rust/api/shared.dart' show HouseholdOverview;
import 'household_pane.dart' show memberLabel;

/// Shown when this device is in no household: choose the relay, then create
/// a household, join one by invite, or restore from a backup.
class HouseholdSetupPane extends StatefulWidget {
  const HouseholdSetupPane({
    required this.relayUrl,
    required this.busy,
    required this.onSaveRelay,
    required this.onCreate,
    required this.onJoin,
    required this.onRestore,
    this.recoveryOverview,
    this.recoveryJoined = false,
    this.onFinishRecovery,
    super.key,
  });

  final String? relayUrl;
  final bool busy;
  final Future<void> Function(String url) onSaveRelay;
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  final VoidCallback onRestore;
  final HouseholdOverview? recoveryOverview;
  final bool recoveryJoined;
  final VoidCallback? onFinishRecovery;

  @override
  State<HouseholdSetupPane> createState() => _HouseholdSetupPaneState();
}

class _HouseholdSetupPaneState extends State<HouseholdSetupPane> {
  late final TextEditingController relayController = TextEditingController(
    text: widget.relayUrl ?? '',
  );

  @override
  void dispose() {
    relayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.recoveryOverview case final recovered?) ...[
          Text('Backup history saved', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Ask a household member to remove ${memberLabel(recovered.memberId)} (the old device), then invite this replacement. Your safety number will change. No messages will be sent using the old keys.',
          ),
          const SizedBox(height: 8),
          const Text(
            'If nobody can invite you, keep your encrypted backup as an archive. Forgetting this copy does not recover the old household’s messaging keys.',
          ),
          ExpansionTile(
            title: Text('Saved history · ${recovered.balanceLabel}'),
            children: [
              for (final transaction in recovered.transactions)
                ListTile(
                  title: Text(transaction.title),
                  subtitle: Text(transaction.amountLabel),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        Text('Share expenses', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'A household keeps your private ledger private: you publish only '
          'the shared expenses you choose. Everything is end-to-end '
          'encrypted; the relay that carries it sees only ciphertext.',
        ),
        const SizedBox(height: 24),
        Text('Relay', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          key: const Key('relayField'),
          controller: relayController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Relay address',
            hintText: 'https://relay.example.workers.dev',
            suffixIcon: IconButton(
              key: const Key('saveRelay'),
              tooltip: 'Save relay address',
              onPressed: widget.busy
                  ? null
                  : () => widget.onSaveRelay(relayController.text),
              icon: const Icon(Icons.check_rounded),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('create'),
          onPressed:
              widget.busy ||
                  widget.relayUrl == null ||
                  widget.recoveryOverview != null
              ? null
              : widget.onCreate,
          icon: const Icon(Icons.home_work_outlined),
          label: const Text('Create a household'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('join'),
          onPressed: widget.busy
              ? null
              : widget.recoveryJoined
              ? widget.onFinishRecovery
              : widget.onJoin,
          icon: const Icon(Icons.group_add_outlined),
          label: Text(
            widget.recoveryJoined
                ? 'Sync to finish recovery'
                : 'Join a household',
          ),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          key: const Key('restore'),
          onPressed: widget.busy || widget.recoveryOverview != null
              ? null
              : widget.onRestore,
          icon: const Icon(Icons.settings_backup_restore_rounded),
          label: const Text('Restore from a backup'),
        ),
      ],
    );
  }
}
