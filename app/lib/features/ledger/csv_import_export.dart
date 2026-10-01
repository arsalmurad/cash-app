import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'csv_files.dart';

/// Export is explicit plaintext file/clipboard access, never cloud sync.
class ExportCsvDialog extends StatefulWidget {
  const ExportCsvDialog({
    required this.csv,
    this.files = const PlatformCsvFiles(),
    super.key,
  });

  final String csv;
  final CsvFiles files;

  @override
  State<ExportCsvDialog> createState() => _ExportCsvDialogState();
}

class _ExportCsvDialogState extends State<ExportCsvDialog> {
  bool _saving = false;
  String? _message;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final saved = await widget.files.save(widget.csv);
      if (mounted) {
        setState(
          () => _message = switch (saved) {
            CsvSaveResult.saved => 'CSV saved. Keep it somewhere you trust.',
            CsvSaveResult.downloadRequested =>
              'Download requested. Check your browser’s downloads.',
            CsvSaveResult.cancelled => null,
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Could not save the CSV. Try another location or copy it instead.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export CSV'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CSV contains readable financial data. Save or copy it only somewhere you trust. This transaction export excludes transfers and is not a full backup.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                widget.csv,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_alt_rounded),
          label: Text(_saving ? 'Saving…' : 'Save CSV'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _saving
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: widget.csv));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  }
                },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}

/// Choose a file or paste; neither action writes events until Import is chosen.
class ImportCsvDialog extends StatefulWidget {
  const ImportCsvDialog({this.files = const PlatformCsvFiles(), super.key});
  final CsvFiles files;

  @override
  State<ImportCsvDialog> createState() => _ImportCsvDialogState();
}

class _ImportCsvDialogState extends State<ImportCsvDialog> {
  final _controller = TextEditingController();
  bool _picking = false;
  String? _error;

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final text = await widget.files.pick();
      if (mounted && text != null) _controller.text = text;
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException ? error.message : 'Could not open the CSV. Choose another file or paste its text.',
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import CSV'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose a UTF-8 CSV up to 5 MB, or paste its text. Review it before importing.',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _picking ? null : _pick,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(_picking ? 'Opening…' : 'Choose CSV'),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_error!),
                ),
              TextField(
                enabled: !_picking,
                key: const Key('importCsvField'),
                controller: _controller,
                maxLines: 10,
                minLines: 6,
                decoration: const InputDecoration(
                  labelText: 'CSV to review',
                  hintText: 'title,amount,kind,account,category\nGroceries,12.34,expense,Everyday,Food',
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _picking || _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
