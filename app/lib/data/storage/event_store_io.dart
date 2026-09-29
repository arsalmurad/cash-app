import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'event_store.dart';

EventStore createEventStore(String name) => IoEventStore(name);

DeviceIdentity createDeviceIdentity() => IoDeviceIdentity();

/// Native-platform durable log storage: each named log is a plain file in
/// the app's sandboxed support directory (`path_provider`'s
/// `getApplicationSupportDirectory`), which survives restarts and app
/// updates but is private to this install, matching the local-first,
/// no-shared-login product boundary.
class IoEventStore implements EventStore {
  IoEventStore(this.name);

  final String name;

  Future<File> _logFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/ledger-$name.v1.log');
  }

  @override
  Future<Uint8List> readLog() async {
    final file = await _logFile();
    if (!await file.exists()) {
      return Uint8List(0);
    }
    return file.readAsBytes();
  }

  @override
  Future<void> appendFrame(Uint8List frame) async {
    final file = await _logFile();
    final sink = file.openWrite(mode: FileMode.append);
    sink.add(frame);
    await sink.flush();
    await sink.close();
  }
}

/// Native-platform actor ID storage, alongside the event log files.
class IoDeviceIdentity implements DeviceIdentity {
  Future<File> _actorIdFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/ledger-actor-id.v1.txt');
  }

  @override
  Future<String?> readActorId() async {
    final file = await _actorIdFile();
    if (!await file.exists()) {
      return null;
    }
    final id = (await file.readAsString()).trim();
    return id.isEmpty ? null : id;
  }

  @override
  Future<void> writeActorId(String actorId) async {
    final file = await _actorIdFile();
    await file.writeAsString(actorId, flush: true);
  }
}
