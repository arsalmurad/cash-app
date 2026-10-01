import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

enum CsvSaveResult { saved, downloadRequested, cancelled }

abstract class CsvFiles {
  Future<String?> pick();
  Future<CsvSaveResult> save(String csv);
}

class PlatformCsvFiles implements CsvFiles {
  const PlatformCsvFiles();
  static const maxImportBytes = 5 * 1024 * 1024;

  @override
  Future<String?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      dialogTitle: 'Choose a transaction CSV',
    );
    if (file == null) return null;
    return decodeCsvStream(file.readAsByteStream());
  }

  @override
  Future<CsvSaveResult> save(String csv) async {
    final uri = await FilePicker.saveFile(
      fileName: 'private-ledger-transactions.csv',
      bytes: Uint8List.fromList(utf8.encode(csv)),
      mimeType: 'text/csv',
      dialogTitle: 'Save transaction CSV',
    );
    // The pinned web plugin returns null even after requesting a download.
    // A browser download request is not evidence that a file reached disk.
    if (kIsWeb) return CsvSaveResult.downloadRequested;
    return uri == null ? CsvSaveResult.cancelled : CsvSaveResult.saved;
  }
}

/// Bound even streams whose platform did not report a length. No selected
/// path, file name or bytes are sent to a server by this adapter.
Future<String> decodeCsvStream(
  Stream<List<int>> chunks, {
  int maxBytes = PlatformCsvFiles.maxImportBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in chunks) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('Choose a CSV smaller than 5 MB.');
    }
    bytes.add(chunk);
  }
  final String text;
  try {
    text = utf8.decode(bytes.takeBytes());
  } on FormatException {
    throw const FormatException(
      'This file is not UTF-8. Export it as UTF-8 CSV and try again.',
    );
  }
  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}
