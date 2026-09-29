import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:private_ledger/data/storage/lock_preference.dart';
import 'package:private_ledger/features/lock/lock_settings_dialog.dart';

class _FakeLocalAuthPlatform extends LocalAuthPlatform {
  _FakeLocalAuthPlatform({this.supported = true});

  bool supported;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async => true;

  @override
  Future<bool> isDeviceSupported() async => supported;

  @override
  Future<bool> deviceSupportsBiometrics() async => supported;
}

class _FakeLockPreferenceStore implements LockPreferenceStore {
  bool enabled = false;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;
}

void main() {
  testWidgets('shows an unsupported message when the device has no lock', (
    tester,
  ) async {
    LocalAuthPlatform.instance = _FakeLocalAuthPlatform(supported: false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LockSettingsDialog(
            preferenceStore: _FakeLockPreferenceStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('does not support'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('toggling the switch persists the preference', (tester) async {
    LocalAuthPlatform.instance = _FakeLocalAuthPlatform(supported: true);
    final preferenceStore = _FakeLockPreferenceStore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LockSettingsDialog(preferenceStore: preferenceStore),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SwitchListTile), findsOneWidget);
    final initial = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(initial.value, isFalse);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    final toggled = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggled.value, isTrue);
  });
}
