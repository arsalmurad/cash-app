import 'dart:math';

/// Generates a new, globally-unique-enough actor ID for a fresh installation.
/// Callers must persist the result via `EventStore.writeActorId` and reuse it
/// on every later launch — see that interface for why it must never change.
String generateActorId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
