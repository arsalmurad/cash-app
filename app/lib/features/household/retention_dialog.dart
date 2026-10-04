import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'retention_codes.dart';

/// Explicit, short-lived consent. Opening or closing this dialog never signs
/// anything. Complete archives stay on devices; only relay copies are reclaimed.
class RetentionDialog extends StatefulWidget {
  const RetentionDialog({
    required this.prepare,
    required this.approve,
    required this.reclaim,
    super.key,
  });

  final Future<String?> Function() prepare;
  final Future<String?> Function(String) approve;
  final Future<bool> Function(String, List<String>) reclaim;

  @override
  State<RetentionDialog> createState() => _RetentionDialogState();
}

class _RetentionDialogState extends State<RetentionDialog> {
  final proposal = TextEditingController();
  final approvals = TextEditingController();
  String? request;
  String? approval;
  String? error;
  bool busy = false;
  bool confirming = false;

  @override
  void dispose() {
    proposal.dispose();
    approvals.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) {
        setState(() => error = 'Could not finish. $failure');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _prepare() => _perform(() async {
    // A renewed request must never keep approvals for its predecessor.
    setState(() {
      request = null;
      approvals.clear();
    });
    final code = await widget.prepare();
    if (code == null) {
      throw const FormatException(
        'Sync every device and confirm its saved history, then prepare a new request.',
      );
    }
    if (mounted) setState(() => request = code);
  });

  Future<bool> _confirm({required bool deleting}) async {
    setState(() => confirming = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              scrollable: true,
              title: Text(
                deleting ? 'Delete old relay copies?' : 'Approve deletion?',
              ),
              content: Text(
                deleting
                    ? 'Permanently deletes only the old relay copies covered by this request. '
                          'Saved household history stays on devices. An older backup may need '
                          'a fresh invitation and a current device to recover. Keep this device '
                          'and an encrypted backup available.'
                    : 'Allows the requesting device to permanently delete the acknowledged '
                          'old relay copies, if every current device approves. Your saved '
                          'history stays on this device. Older backups may need a fresh '
                          'invitation and a current device to recover.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep relay copies'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(
                    deleting ? 'Delete relay copies' : 'Approve deletion',
                  ),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  Future<void> _approve() => _perform(() async {
    final code = proposal.text;
    decodeRetentionRequest(code);
    setState(() => approval = null);
    if (!await _confirm(deleting: false) || !mounted) return;
    final result = await widget.approve(code);
    if (result == null) {
      throw const FormatException(
        'Check the request and sync. Ask for a new request if it expired or the household changed.',
      );
    }
    if (mounted) setState(() => approval = result);
  });

  Future<void> _reclaim() => _perform(() async {
    final code = request;
    if (code == null) return;
    if (approvals.text.length > 63 * 4097) {
      throw const FormatException('Too many approval codes.');
    }
    final codes = approvals.text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (codes.length > 63) {
      throw const FormatException('Too many approval codes.');
    }
    for (final value in codes) {
      decodeRetentionConsent(value);
    }
    if (!await _confirm(deleting: true) || !mounted) return;
    if (!await widget.reclaim(code, codes)) {
      throw const FormatException(
        'Deletion was not confirmed and some copies may already be deleted. '
        'Keep this device available. Retry with these codes while valid, or '
        'prepare a new request and collect new approvals.',
      );
    }
    if (mounted) Navigator.pop(context, true);
  });

  Widget _code(String code, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      TextButton.icon(
        onPressed: busy
            ? null
            : () async {
                try {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (mounted) {
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(SnackBar(content: Text('$label copied')));
                  }
                } catch (_) {
                  if (mounted) {
                    setState(
                      () => error =
                          'Copy failed. Select the code and copy it manually.',
                    );
                  }
                }
              },
        icon: const Icon(Icons.copy_outlined),
        label: Text('Copy $label'),
      ),
      SizedBox(
        height: 96,
        child: SingleChildScrollView(
          child: SelectableText(
            code,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ),
      const SizedBox(height: 12),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Manage relay copies'),
      content: SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Local development only; the relay operator must enable retention. '
              'Every current device must be synced and explicitly approve. '
              'Keep an encrypted backup and a current device available. '
              'This does not erase saved expenses or your private ledger.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Requests expire 50 seconds after preparation. Have all devices ready. '
              'You can prepare a new request at any time, then collect new approvals. '
              'Do not change household history during collection.',
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: busy ? null : _prepare,
              child: Text(
                request == null ? 'Prepare request' : 'Prepare new request',
              ),
            ),
            if (request != null) ...[
              const SizedBox(height: 12),
              _code(request!, 'request code'),
              const Text(
                'Send the request to every other device. Paste their approvals below, one complete code per line.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: approvals,
                enabled: !busy,
                minLines: 2,
                maxLines: 4,
                maxLength: 63 * 4097,
                decoration: const InputDecoration(
                  labelText: 'Approval codes',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: busy ? null : _reclaim,
                child: const Text('Review deletion'),
              ),
            ],
            const Divider(height: 32),
            const Text('Received a request from another device?'),
            const SizedBox(height: 8),
            TextField(
              controller: proposal,
              enabled: !busy,
              minLines: 2,
              maxLines: 4,
              maxLength: 4096,
              decoration: const InputDecoration(
                labelText: 'Request code',
                counterText: '',
              ),
              onChanged: (_) {
                if (approval != null) setState(() => approval = null);
              },
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: busy ? null : _approve,
              child: const Text('Review approval'),
            ),
            if (approval != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Send this approval back to the requesting device. It cannot authorize a different request.',
              ),
              _code(approval!, 'approval code'),
            ],
            if (busy && !confirming)
              const LinearProgressIndicator(
                semanticsLabel: 'Checking saved history and relay permissions',
              ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Semantics(liveRegion: true, child: Text(error!)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
