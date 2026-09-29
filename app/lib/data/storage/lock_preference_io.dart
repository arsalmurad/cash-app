import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'lock_preference.dart';

LockPreferenceStore createLockPreferenceStore() => IoLockPreferenceStore();

class IoLockPreferenceStore implements LockPreferenceStore {
  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/ledger-lock-enabled.v1.txt');
  }

  @override
  Future<bool> readEnabled() async {
    final file = await _file();
    if (!await file.exists()) {
      return false;
    }
    return (await file.readAsString()).trim() == 'true';
  }

  @override
  Future<void> writeEnabled(bool enabled) async {
    final file = await _file();
    await file.writeAsString(enabled ? 'true' : 'false', flush: true);
  }
}
