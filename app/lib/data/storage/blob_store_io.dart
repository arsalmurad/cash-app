import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'blob_store.dart';

BlobStore createBlobStore(String name) => IoBlobStore(name);

/// Native blob storage: one file per name in the app's private support
/// directory, replaced by writing a temporary file and renaming it over the
/// old one (a rename within one directory is atomic on every native
/// platform this app targets).
class IoBlobStore implements BlobStore {
  IoBlobStore(this.name);

  final String name;

  Future<File> _file({bool temporary = false}) async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/blob-$name.v1${temporary ? '.tmp' : ''}');
  }

  @override
  Future<Uint8List?> read() async {
    final file = await _file();
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  @override
  Future<void> write(Uint8List value) async {
    final temporary = await _file(temporary: true);
    await temporary.writeAsBytes(value, flush: true);
    await temporary.rename((await _file()).path);
  }

  @override
  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) {
      await file.delete();
    }
  }
}
