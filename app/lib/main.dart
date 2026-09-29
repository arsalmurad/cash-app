import 'package:flutter/material.dart';

import 'data/rust/frb_generated.dart';
import 'features/ledger/ledger_controller.dart';
import 'features/ledger/ledger_screen.dart';
import 'features/lock/biometric_lock_gate.dart';

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

  @override
  void initState() {
    super.initState();
    controller = LedgerController()..initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Private Ledger',
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: BiometricLockGate(child: LedgerScreen(controller: controller)),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF176B5B),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
