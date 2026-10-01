import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Browser-only setup/unlock. No key is adopted until the user has saved the
/// generated phrase; loading/validation errors remain actionable on this pane.
class VaultPane extends StatefulWidget {
  const VaultPane({
    required this.hasCiphertext,
    required this.generatePhrase,
    required this.unlock,
    this.error,
    this.recover,
    super.key,
  });
  final bool hasCiphertext;
  final Future<String?> Function() generatePhrase;
  final Future<bool> Function(String phrase) unlock;
  final String? error;
  final VoidCallback? recover;
  @override
  State<VaultPane> createState() => _VaultPaneState();
}

class _VaultPaneState extends State<VaultPane> {
  final input = TextEditingController();
  String? generated;
  bool saved = false;
  bool working = false;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() => working = true);
    final phrase = await widget.generatePhrase();
    if (!mounted) return;
    setState(() {
      generated = phrase;
      saved = false;
      working = false;
    });
  }

  Future<void> _unlock() async {
    final phrase = widget.hasCiphertext ? input.text.trim() : generated;
    if (phrase == null || phrase.isEmpty) return;
    setState(() => working = true);
    await widget.unlock(phrase);
    if (mounted) setState(() => working = false);
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    shrinkWrap: true,
    children: [
      Text(
        widget.hasCiphertext
            ? 'Unlock this browser’s household'
            : 'Protect this browser’s household',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      const Text(
        'Household keys are encrypted here. This website does not save '
        'the unlock phrase; you will need it after each reload. Your private ledger is separate.',
      ),
      const SizedBox(height: 16),
      if (widget.hasCiphertext)
        TextField(
          key: const Key('vaultPhrase'),
          controller: input,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: '24-word unlock phrase'),
        )
      else ...[
        if (generated == null)
          FilledButton(
            onPressed: working ? null : _generate,
            child: const Text('Create unlock phrase'),
          )
        else ...[
          SelectableText(generated!, key: const Key('generatedVaultPhrase')),
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: generated!)),
            icon: const Icon(Icons.copy),
            label: const Text('Copy unlock phrase'),
          ),
          const Text(
            'Save it somewhere private. Do not send it with an invite. '
            'Lose it and this browser’s copy cannot be opened; you will need an encrypted backup or a fresh invite.',
          ),
          CheckboxListTile(
            value: saved,
            onChanged: working
                ? null
                : (value) => setState(() => saved = value!),
            title: const Text('I saved this phrase privately'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ],
      if (widget.error != null) ...[
        const SizedBox(height: 12),
        Text(widget.error!, key: const Key('vaultError')),
      ],
      const SizedBox(height: 16),
      if (widget.hasCiphertext || generated != null)
        FilledButton(
          key: const Key('vaultUnlock'),
          onPressed: working || (!widget.hasCiphertext && !saved)
              ? null
              : _unlock,
          child: Text(
            working
                ? 'Opening…'
                : widget.hasCiphertext
                ? 'Unlock household'
                : 'Encrypt and continue',
          ),
        ),
      if (widget.hasCiphertext && widget.recover != null)
        TextButton(
          onPressed: working ? null : widget.recover,
          child: const Text('Restore an encrypted backup'),
        ),
    ],
  );
}
