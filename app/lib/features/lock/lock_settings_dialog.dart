import 'package:flutter/material.dart';

import '../../data/storage/lock_preference.dart';
import 'biometric_lock_gate.dart';

/// Lets the user turn the biometric lock on or off. Shown from
/// `LedgerScreen`'s overflow menu rather than a dedicated settings screen,
/// since it's the only app-level preference this app currently has.
class LockSettingsDialog extends StatefulWidget {
  const LockSettingsDialog({this.preferenceStore, super.key});

  final LockPreferenceStore? preferenceStore;

  @override
  State<LockSettingsDialog> createState() => _LockSettingsDialogState();
}

class _LockSettingsDialogState extends State<LockSettingsDialog> {
  late final LockPreferenceStore _preferenceStore =
      widget.preferenceStore ?? LockPreferenceStore();
  bool _loading = true;
  bool _supported = false;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final supported = await isBiometricLockSupported();
      final enabled = await _preferenceStore.readEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        _supported = supported;
        _enabled = enabled;
        _loading = false;
      });
    } catch (_) {
      // Treat a failure to read either as "unsupported": there is nothing
      // useful to offer the user if we can't tell whether the lock works.
      if (!mounted) {
        return;
      }
      setState(() {
        _supported = false;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Screen lock'),
      content: SizedBox(
        width: 360,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_supported)
                    const Text(
                      'This device or browser does not support a biometric '
                      'or passcode lock.',
                    )
                  else
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Require unlock to open the ledger'),
                      value: _enabled,
                      onChanged: (value) async {
                        await _preferenceStore.writeEnabled(value);
                        if (!mounted) {
                          return;
                        }
                        setState(() => _enabled = value);
                      },
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
