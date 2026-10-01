import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/blob_store_io.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/data/storage/event_store_io.dart';
import 'package:private_ledger/data/storage/sqlite_store.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  group(
    'real SQLite storage',
    () {
      late Directory directory;
      late PathProviderPlatform previousPaths;
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      });
      setUp(() async {
        directory = await Directory.systemTemp.createTemp('cash-sqlite-test-');
        previousPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(directory.path);
      });
      tearDown(() async {
        PathProviderPlatform.instance = previousPaths;
        await directory.delete(recursive: true);
      });

      test('default stores use Rust SQLite and retain legacy logs', () async {
        await IoEventStore('ledger').appendFrame(Uint8List.fromList([1, 2]));
        final store = EventStore('ledger');
        expect(store, isA<SqliteEventStore>());
        expect(await store.readLog(), [1, 2]);
        await store.appendFrame(Uint8List.fromList([3]));
        await IoEventStore('ledger').appendFrame(Uint8List.fromList([99]));
        expect(await EventStore('ledger').readLog(), [1, 2, 3]);
        expect(await IoEventStore('ledger').readLog(), [1, 2, 99]);
        expect(
          await File('${directory.path}/cash-app.v1.sqlite').exists(),
          isTrue,
        );
      });

      test('stale log writers cannot overwrite newer frames', () async {
        final one = EventStore('ledger');
        final two = EventStore('ledger');
        await one.readLog();
        await two.readLog();
        await one.appendFrame(Uint8List.fromList([1]));
        await expectLater(
          two.appendFrame(Uint8List.fromList([2])),
          throwsA(
            predicate(
              (Object error) => error.toString().contains('another instance'),
            ),
          ),
        );
        expect(await EventStore('ledger').readLog(), [1]);
      });

      test(
        'document revisions reject stale ratchets and retain tombstones',
        () async {
          final one = BlobStore('household');
          final two = BlobStore('household');
          await one.read();
          await two.read();
          await one.write(Uint8List.fromList([1, 2, 3]));
          await expectLater(
            two.write(Uint8List.fromList([99])),
            throwsA(
              predicate(
                (Object error) => error.toString().contains('another instance'),
              ),
            ),
          );
          expect(await BlobStore('household').read(), [1, 2, 3]);
          await one.delete();
          await IoBlobStore('household').write(Uint8List.fromList([77]));
          expect(await BlobStore('household').read(), isNull);
        },
      );

      test(
        'actor identity migrates without changing or deleting its source',
        () async {
          await IoDeviceIdentity().writeActorId('legacy-device');
          final identity = DeviceIdentity();
          expect(await identity.readActorId(), 'legacy-device');
          expect(await DeviceIdentity().readActorId(), 'legacy-device');
          await expectLater(
            identity.writeActorId('different-device'),
            throwsStateError,
          );
          expect(await IoDeviceIdentity().readActorId(), 'legacy-device');
        },
      );

      test('damaged database is reported and never replaced', () async {
        await EventStore('ledger').readLog();
        final database = File('${directory.path}/cash-app.v1.sqlite');
        await database.writeAsBytes([1, 2, 3], flush: true);
        await expectLater(EventStore('ledger').readLog(), throwsA(anything));
        expect(await database.readAsBytes(), [1, 2, 3]);
      });
    },
    skip: libraryPath == null
        ? 'set RUST_LIB_PATH to the built Rust library'
        : false,
  );
}
