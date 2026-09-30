import 'package:flutter/material.dart';

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
    super.key,
  });

  final String? relayUrl;
  final bool busy;
  final Future<void> Function(String url) onSaveRelay;
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  final VoidCallback onRestore;

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
          onPressed: widget.busy || widget.relayUrl == null
              ? null
              : widget.onCreate,
          icon: const Icon(Icons.home_work_outlined),
          label: const Text('Create a household'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('join'),
          onPressed: widget.busy ? null : widget.onJoin,
          icon: const Icon(Icons.group_add_outlined),
          label: const Text('Join a household'),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          key: const Key('restore'),
          onPressed: widget.busy ? null : widget.onRestore,
          icon: const Icon(Icons.settings_backup_restore_rounded),
          label: const Text('Restore from a backup'),
        ),
      ],
    );
  }
}
