// Run with the existing generated Cargokit runner's package configuration.
// This verifies compiler selection/commands, not native runtime acceptance.
import 'dart:io';

import '../app/rust_builder/cargokit/build_tool/lib/src/builder.dart';
import '../app/rust_builder/cargokit/build_tool/lib/src/cargo.dart';
import '../app/rust_builder/cargokit/build_tool/lib/src/options.dart';
import '../app/rust_builder/cargokit/build_tool/lib/src/rustup.dart';
import '../app/rust_builder/cargokit/build_tool/lib/src/target.dart';
import '../app/rust_builder/cargokit/build_tool/lib/src/util.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final options = CargokitCrateOptions.load(manifestDir: '$root/rust/api');
  var cases = 0;
  for (final configuration in BuildConfiguration.values) {
    for (final installed in [true, false]) {
      final commands = <TestRunCommandArgs>[];
      testRunCommandOverride = (command) {
        commands.add(command);
        check(command.executable == 'rustup', 'Unexpected executable');
        final args = command.arguments;
        if (args.join(' ') == 'toolchain list') {
          return TestRunCommandResult(
            stdout:
                'stable-x86_64-unknown-linux-gnu (default)\n'
                '${installed ? '1.98.1-x86_64-unknown-linux-gnu\n' : ''}',
          );
        }
        if (args.take(2).join(' ') == 'target list') {
          return TestRunCommandResult(stdout: 'x86_64-unknown-linux-gnu\n');
        }
        if (args.take(2).join(' ') == 'toolchain install') {
          check(args.last == '1.98.1', 'Must install only the exact pin');
          return TestRunCommandResult();
        }
        if (args.first == 'run') return TestRunCommandResult();
        throw StateError('Unexpected Rustup operation: $args');
      };
      try {
        final builder = RustBuilder(
          target: Target(rust: 'x86_64-unknown-linux-gnu'),
          environment: BuildEnvironment(
            configuration: configuration,
            crateOptions: options,
            targetTempDir: '/synthetic-target',
            manifestDir: '$root/rust/api',
            crateInfo: CrateInfo(packageName: 'rust_lib_cash_app'),
            isAndroid: false,
          ),
        );
        builder.prepare(Rustup());
        await builder.build();
        final build = commands.singleWhere((c) => c.arguments.first == 'run');
        check(
          build.arguments[1] ==
              (installed ? '1.98.1-x86_64-unknown-linux-gnu' : '1.98.1'),
          'A moving stable channel must never replace the compiler pin',
        );
        check(build.arguments.contains('--locked'), 'Locked Cargo resolution');
        final installs = commands
            .where((c) => c.arguments.take(2).join(' ') == 'toolchain install')
            .length;
        check(
          installs == (installed ? 0 : 1),
          'Reuse an installed numeric pin',
        );
        cases++;
      } finally {
        testRunCommandOverride = null;
      }
    }
  }
  print('Cargokit compiler selection: $cases cases passed.');
}
