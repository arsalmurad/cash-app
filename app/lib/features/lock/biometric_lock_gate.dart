import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../../data/storage/lock_preference.dart';

/// Gates [child] behind a biometric prompt when the user has turned the
/// lock on. `local_auth` has no web implementation, so on web this always
/// shows [child] directly rather than a lock screen nobody could pass (see
/// `docs/DECISIONS.md`) — Phase 1's brief calls for "local-only
/// persistence, biometric lock", and a lock that can't be satisfied on one
/// platform is worse than no lock on that platform.
class BiometricLockGate extends StatefulWidget {
  const BiometricLockGate({
    required this.child,
    this.auth,
    this.preferenceStore,
    super.key,
  });

  final Widget child;
  final LocalAuthentication? auth;
  final LockPreferenceStore? preferenceStore;

  @override
  State<BiometricLockGate> createState() => _BiometricLockGateState();
}

class _BiometricLockGateState extends State<BiometricLockGate>
    with WidgetsBindingObserver {
  late final LocalAuthentication _auth = widget.auth ?? LocalAuthentication();
  late final LockPreferenceStore _preferenceStore =
      widget.preferenceStore ?? LockPreferenceStore();

  bool _loadingPreference = true;
  bool _lockEnabled = false;
  bool _unlocked = false;
  bool _authenticating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock whenever the app returns from the background, so a stolen or
    // borrowed unlocked device can't be resumed straight into the ledger.
    if (state == AppLifecycleState.resumed && _lockEnabled && !kIsWeb) {
      setState(() => _unlocked = false);
    }
  }

  Future<void> _load() async {
    final enabled = kIsWeb ? false : await _preferenceStore.readEnabled();
    if (!mounted) {
      return;
    }
    setState(() {
      _lockEnabled = enabled;
      _loadingPreference = false;
    });
  }

  Future<void> _authenticate() async {
    setState(() {
      _authenticating = true;
      _error = null;
    });
    try {
      final authenticated = await _auth.authenticate(
        localizedReason: 'Unlock your ledger',
        options: const AuthenticationOptions(biometricOnly: false),
      );
      if (!mounted) {
        return;
      }
      setState(() => _unlocked = authenticated);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _authenticating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingPreference) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_lockEnabled || _unlocked) {
      return widget.child;
    }
    return _LockScreen(
      authenticating: _authenticating,
      error: _error,
      onUnlock: _authenticate,
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({
    required this.authenticating,
    required this.error,
    required this.onUnlock,
  });

  final bool authenticating;
  final String? error;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline_rounded, size: 56),
              const SizedBox(height: 16),
              Text(
                'Private Ledger is locked',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('Unlock to see your accounts and activity.'),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: authenticating ? null : onUnlock,
                icon: const Icon(Icons.fingerprint_rounded),
                label: Text(authenticating ? 'Checking…' : 'Unlock'),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether the biometric lock can be offered at all on this device: never on
/// web, and only when the platform reports a usable biometric/device
/// credential setup.
Future<bool> isBiometricLockSupported({LocalAuthentication? auth}) async {
  if (kIsWeb) {
    return false;
  }
  final localAuth = auth ?? LocalAuthentication();
  return localAuth.isDeviceSupported();
}
