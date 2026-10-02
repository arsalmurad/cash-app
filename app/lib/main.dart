import 'package:flutter/material.dart';

import 'data/rust/frb_generated.dart';
import 'features/household/household_controller.dart';
import 'features/ledger/ledger_controller.dart';
import 'features/ledger/ledger_screen.dart';
import 'features/lock/biometric_lock_gate.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const PrivateLedgerApp());
}

class PrivateLedgerApp extends StatefulWidget {
  const PrivateLedgerApp({super.key});

  @override
  State<PrivateLedgerApp> createState() => _PrivateLedgerAppState();
}

class _PrivateLedgerAppState extends State<PrivateLedgerApp> {
  late final LedgerController controller;
  late final HouseholdController household;

  @override
  void initState() {
    super.initState();
    controller = LedgerController()..initialize();
    household = HouseholdController()..initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    household.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Private Ledger',
      themeMode: ThemeMode.system,
      theme: ledgerTheme(Brightness.light),
      darkTheme: ledgerTheme(Brightness.dark),
      home: BiometricLockGate(
        child: LedgerScreen(controller: controller, household: household),
      ),
    );
  }
}
