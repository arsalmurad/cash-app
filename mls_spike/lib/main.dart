import 'package:flutter/material.dart';
import 'package:mls_spike/src/rust/api/mls.dart';
import 'package:mls_spike/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MlsSpikeApp());
}

class MlsSpikeApp extends StatelessWidget {
  const MlsSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenMLS bridge spike',
      home: const SpikeScreen(),
    );
  }
}

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key});

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  bool running = false;
  String result = 'Run the MLS group, add, and remove checks.';

  Future<void> runSpike() async {
    setState(() {
      running = true;
      result = 'Creating group...';
    });
    try {
      final spike = await createGroup();
      if (mounted) setState(() => result = 'Adding member...');
      final beforeRemoval = await addMember(spike: spike);
      if (mounted) setState(() => result = 'Removing member...');
      final afterRemoval = await removeMemberAndVerify(spike: spike);
      spike.dispose();
      if (mounted) {
        setState(() {
          result =
              'Before removal decrypt: $beforeRemoval\n'
              'After removal decrypt rejected: $afterRemoval';
        });
      }
    } catch (error) {
      if (mounted) setState(() => result = 'Spike failed: $error');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OpenMLS bridge spike')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(result, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: running ? null : runSpike,
              child: const Text('Run spike'),
            ),
          ],
        ),
      ),
    );
  }
}
