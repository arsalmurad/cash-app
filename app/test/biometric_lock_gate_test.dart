import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:private_ledger/data/storage/lock_preference.dart';
import 'package:private_ledger/features/lock/biometric_lock_gate.dart';

class _FakeLocalAuthPlatform extends LocalAuthPlatform {
  _FakeLocalAuthPlatform({this.authenticateResult = true});

  bool authenticateResult;
  int authenticateCalls = 0;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authenticateCalls += 1;
    return authenticateResult;
  }

  @override
  Future<bool> isDeviceSupported() async => true;

  @override
  Future<bool> deviceSupportsBiometrics() async => true;
}

class _FakeLockPreferenceStore implements LockPreferenceStore {
  _FakeLockPreferenceStore({this.enabled = false});

  bool enabled;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;
}

void main() {
  testWidgets('shows the child directly when the lock is not enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricLockGate(
          preferenceStore: _FakeLockPreferenceStore(enabled: false),
          child: const Text('unlocked content'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('unlocked content'), findsOneWidget);
    expect(find.text('Private Ledger is locked'), findsNothing);
  });

  testWidgets('shows a lock screen and unlocks after successful authentication', (
    tester,
  ) async {
    LocalAuthPlatform.instance = _FakeLocalAuthPlatform(
      authenticateResult: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BiometricLockGate(
          preferenceStore: _FakeLockPreferenceStore(enabled: true),
          child: const Text('unlocked content'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Private Ledger is locked'), findsOneWidget);
    expect(find.text('unlocked content'), findsNothing);

    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('unlocked content'), findsOneWidget);
    expect(find.text('Private Ledger is locked'), findsNothing);
  });

  testWidgets('stays locked when authentication fails', (tester) async {
    LocalAuthPlatform.instance = _FakeLocalAuthPlatform(
      authenticateResult: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BiometricLockGate(
          preferenceStore: _FakeLockPreferenceStore(enabled: true),
          child: const Text('unlocked content'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Private Ledger is locked'), findsOneWidget);
    expect(find.text('unlocked content'), findsNothing);
  });
}
