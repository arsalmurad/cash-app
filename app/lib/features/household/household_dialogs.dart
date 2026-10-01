import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A block of text people must copy exactly (a code, a phrase, a number).
class _CopyBlock extends StatelessWidget {
  const _CopyBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)
                    ?.showSnackBar(const SnackBar(content: Text('Copied')));
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy'),
          ),
        ),
      ],
    );
  }
}

/// Step 1 and 3 of joining, for the person being invited: show the join
/// request to hand to the inviter, then take the invite they send back.
class JoinDialog extends StatefulWidget {
  const JoinDialog({
    required this.prepareRequest,
    required this.join,
    super.key,
  });

  final Future<String?> Function() prepareRequest;
  final Future<bool> Function(String invite) join;

  @override
  State<JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<JoinDialog> {
  final inviteController = TextEditingController();
  late final Future<String?> request = widget.prepareRequest();
  bool joining = false;
  String? error;

  @override
  void dispose() {
    inviteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (inviteController.text.trim().isEmpty) {
      setState(() => error = 'Paste the invite you received');
      return;
    }
    setState(() {
      joining = true;
      error = null;
    });
    final joined = await widget.join(inviteController.text);
    if (!mounted) {
      return;
    }
    if (joined) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        joining = false;
        error = "Couldn't join with that invite. Check it and try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join a household'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '1. Send this join request to the person inviting you, by any '
              'messenger. It is not secret, but do not post it publicly.',
            ),
            const SizedBox(height: 12),
            FutureBuilder<String?>(
              future: request,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final code = snapshot.data;
                if (code == null) {
                  return const Text(
                    "Couldn't create a join request on this device.",
                  );
                }
                return _CopyBlock(text: code);
              },
            ),
            const SizedBox(height: 16),
            const Text('2. They will send back an invite. Paste it here.'),
            const SizedBox(height: 8),
            TextField(
              key: const Key('inviteField'),
              controller: inviteController,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Invite',
                hintText: 'cashinv1:…',
                errorText: error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: joining ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('joinSubmit'),
          onPressed: joining ? null : _submit,
          child: Text(joining ? 'Joining…' : 'Join'),
        ),
      ],
    );
  }
}

/// For an existing member: paste the newcomer's join request, get the
/// invite to send back.
class InviteDialog extends StatefulWidget {
  const InviteDialog({
    required this.createInvite,
    this.initialInvite,
    super.key,
  });

  final Future<String?> Function(String joinRequest) createInvite;
  final String? initialInvite;

  @override
  State<InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<InviteDialog> {
  final requestController = TextEditingController();
  String? invite;
  bool working = false;
  String? error;

  @override
  void initState() {
    super.initState();
    invite = widget.initialInvite;
  }

  @override
  void dispose() {
    requestController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (requestController.text.trim().isEmpty) {
      setState(() => error = 'Paste their join request');
      return;
    }
    setState(() {
      working = true;
      error = null;
    });
    final created = await widget.createInvite(requestController.text);
    if (!mounted) {
      return;
    }
    setState(() {
      working = false;
      invite = created;
      error = created == null ? "Couldn't add them. Check the request." : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final created = invite;
    return AlertDialog(
      title: const Text('Invite someone'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (created == null) ...[
              const Text(
                'Ask them to choose "Join a household" and send you their '
                'join request. Paste it here.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('requestField'),
                controller: requestController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Their join request',
                  hintText: 'cashkp1:…',
                  errorText: error,
                ),
              ),
            ] else ...[
              const Text(
                'They are added. Send them this invite; it works once and '
                'expires in a week. Then compare safety numbers with them '
                '(the shield next to their name) to be sure nobody swapped '
                'a key.',
              ),
              const SizedBox(height: 12),
              _CopyBlock(text: created),
            ],
          ],
        ),
      ),
      actions: [
        if (created != null)
          TextButton(
            onPressed: working ? null : () => setState(() => invite = null),
            child: const Text('Invite someone else'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(created == null ? 'Cancel' : 'Done'),
        ),
        if (created == null)
          FilledButton(
            key: const Key('inviteSubmit'),
            onPressed: working ? null : _submit,
            child: Text(working ? 'Adding…' : 'Add to household'),
          ),
      ],
    );
  }
}

/// The safety number shared with one member: both people compare it aloud
/// or on screen; a mismatch means someone substituted a key.
class SafetyNumberDialog extends StatelessWidget {
  const SafetyNumberDialog({
    required this.memberLabel,
    required this.number,
    super.key,
  });

  final String memberLabel;
  final String number;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Safety number with $memberLabel'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ask them to open the same screen and compare these numbers, in '
            'person or on a call. If they match, your messages are private '
            'to the two of you. If not, do not trust this household.',
          ),
          const SizedBox(height: 12),
          _CopyBlock(text: number),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('They match'),
        ),
      ],
    );
  }
}

/// New shared expense: a title and an amount in the household currency.
class ExpenseDialog extends StatefulWidget {
  const ExpenseDialog({super.key});

  @override
  State<ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends State<ExpenseDialog> {
  final formKey = GlobalKey<FormState>();
  final titleController = TextEditingController();
  final amountController = TextEditingController();

  @override
  void dispose() {
    titleController.dispose();
    amountController.dispose();
    super.dispose();
  }

  void _submit() {
    if (formKey.currentState!.validate()) {
      Navigator.pop(context, (
        title: titleController.text.trim(),
        amount: amountController.text.trim(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a shared expense'),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('expenseTitle'),
              controller: titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Title'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a title'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('expenseAmount'),
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount',
                hintText: '0.00',
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter an amount'
                  : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('expenseSubmit'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// A single amount field, for changing an existing expense.
class AmountDialog extends StatefulWidget {
  const AmountDialog({required this.title, this.initial = '', super.key});

  final String title;
  final String initial;

  @override
  State<AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<AmountDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = controller.text.trim();
    if (text.isNotEmpty) {
      Navigator.pop(context, text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('amountField'),
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Amount'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('amountSubmit'),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The recovery phrase and the sealed backup to store. Shown once.
class BackupDialog extends StatelessWidget {
  const BackupDialog({required this.phrase, required this.backup, super.key});

  final String phrase;
  final String backup;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Back up this household'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '1. Write these 24 words on paper and keep them somewhere '
              'safe. Do not photograph them or store them on this phone. '
              'There is no reset: without them a lost phone cannot be '
              'restored.',
            ),
            const SizedBox(height: 12),
            _CopyBlock(text: phrase),
            const SizedBox(height: 16),
            const Text(
              '2. Store this backup anywhere (a note, your cloud drive, an '
              'email to yourself). It is unreadable without the words.',
            ),
            const SizedBox(height: 12),
            _CopyBlock(text: backup),
            const SizedBox(height: 8),
            const Text(
              'Restoring recovers saved history, not old messaging keys. '
              'Ask another household member to remove the old device, then '
              'invite the replacement. Its safety number will change. '
              'Without another member, keep the backup as a read-only archive.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('I have saved both'),
        ),
      ],
    );
  }
}

/// Restores a household from the 24 words and a backup code.
class RestoreDialog extends StatefulWidget {
  const RestoreDialog({required this.restore, super.key});

  final Future<bool> Function(String phrase, String backup) restore;

  @override
  State<RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<RestoreDialog> {
  final phraseController = TextEditingController();
  final backupController = TextEditingController();
  bool working = false;
  String? error;

  @override
  void dispose() {
    phraseController.dispose();
    backupController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      working = true;
      error = null;
    });
    final restored = await widget.restore(
      phraseController.text,
      backupController.text,
    );
    if (!mounted) {
      return;
    }
    if (restored) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        working = false;
        error = "Couldn't restore. Check the words and the backup code.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore from a backup'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your saved history will be recovered with fresh device keys. Another household member must remove the old device and invite this replacement before it can sync or send.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('phraseField'),
              controller: phraseController,
              minLines: 2,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Your 24 words'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('backupField'),
              controller: backupController,
              minLines: 2,
              maxLines: 4,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Backup code',
                hintText: 'cashbk1:…',
                errorText: error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: working ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('restoreSubmit'),
          onPressed: working ? null : _submit,
          child: Text(working ? 'Restoring…' : 'Restore'),
        ),
      ],
    );
  }
}
