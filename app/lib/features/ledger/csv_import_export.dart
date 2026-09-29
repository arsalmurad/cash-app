import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows exported CSV text with a copy-to-clipboard button. There is no
/// native file save here (see `docs/DECISIONS.md`): copying to the
/// clipboard needs no platform-specific file picker, so it works
/// identically on phone, tablet, and web.
class ExportCsvDialog extends StatelessWidget {
  const ExportCsvDialog({required this.csv, super.key});

  final String csv;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export CSV'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: SelectableText(csv, style: const TextStyle(fontFamily: 'monospace')),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: csv));
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

/// Collects pasted CSV text to import. There is no native file picker here
/// for the same reason as [ExportCsvDialog]: pasting works identically on
/// every platform this app targets without a platform-specific dependency.
class ImportCsvDialog extends StatefulWidget {
  const ImportCsvDialog({super.key});

  @override
  State<ImportCsvDialog> createState() => _ImportCsvDialogState();
}

class _ImportCsvDialogState extends State<ImportCsvDialog> {
  final _controller = TextEditingController();

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
        child: TextField(
          key: const Key('importCsvField'),
          controller: _controller,
          maxLines: 10,
          minLines: 6,
          decoration: const InputDecoration(
            hintText: 'title,amount,kind,account,category\nGroceries,12.34,expense,Everyday,Food',
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
