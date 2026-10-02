import 'dart:math';

/// Generates a new, globally-unique-enough actor ID for a fresh installation.
/// Callers must persist the result via `EventStore.writeActorId` and reuse it
/// on every later launch — see that interface for why it must never change.
String generateActorId() => generateOpaqueId();

/// A fresh 128-bit random identifier, independent of wall-clock resolution,
/// clock rollback, mutation queues and process-local counters.
String generateOpaqueId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
