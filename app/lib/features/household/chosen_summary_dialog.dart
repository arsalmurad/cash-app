import 'package:flutter/material.dart';

import '../../data/rust/api/ledger.dart';

typedef PrepareChosenSummary = Future<SummaryPreview> Function(
  DateTimeRange range,
  bool income,
  bool expenses,
);

/// Selection and review are distinct steps. Previewing cannot publish anything.
class ChosenSummaryDialog extends StatefulWidget {
  const ChosenSummaryDialog({
    required this.prepare,
    required this.publish,
    this.now,
    super.key,
  });
  final PrepareChosenSummary prepare;
  final Future<bool> Function() publish;
  final DateTime? now;

  @override
  State<ChosenSummaryDialog> createState() => _ChosenSummaryDialogState();
}

class _ChosenSummaryDialogState extends State<ChosenSummaryDialog> {
  late DateTimeRange range;
  bool income = false;
  bool expenses = false;
  bool updated = false;
  bool busy = false;
  SummaryPreview? preview;
  String? error;

  @override
  void initState() {
    super.initState();
    final now = widget.now ?? DateTime.now();
    range = DateTimeRange(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month, now.day),
    );
  }

  Future<void> _chooseDates() async {
    final next = await showDateRangePicker(
      context: context,
      initialDateRange: range,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (next != null && mounted) setState(() => range = next);
  }

  Future<void> _prepare() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await widget.prepare(range, income, expenses);
      if (mounted) {
        setState(() {
          preview = next;
          updated = false;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = 'Could not prepare totals. $failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _publish() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final shared = await widget.publish();
      if (!mounted) return;
      if (shared) {
        Navigator.pop(context, true);
      } else {
        setState(
          () => error = 'Sharing could not be confirmed. Check the household before retrying.',
        );
      }
    } catch (failure) {
      if (mounted) {
        setState(() => error = 'Sharing could not be confirmed. $failure');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final period =
        '${localizations.formatMediumDate(range.start)} – '
        '${localizations.formatMediumDate(range.end)}';
    final current = preview;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          current == null ? 'Choose totals to share' : 'Review shared snapshot',
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (current == null) ...[
                const Text(
                  'Only the totals you select and this date range will be shared. '
                  'Private transaction details stay on your device.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: busy ? null : _chooseDates,
                  icon: const Icon(Icons.date_range),
                  label: Text(period),
                ),
                const Text(
                  'Dates use this device’s time zone, including both selected days.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Income total'),
                  value: income,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => income = value ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expense total'),
                  value: expenses,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => expenses = value ?? false),
                ),
              ] else ...[
                const Text('Share with this household:'),
                SelectableText(current.groupId),
                const SizedBox(height: 12),
                Text(period),
                const Text('Device-local dates · frozen reporting rates'),
                if (current.incomeLabel != null) ...[
                  const SizedBox(height: 12),
                  const Text('Income total'),
                  Text(current.incomeLabel!),
                ],
                if (current.expensesLabel != null) ...[
                  const SizedBox(height: 12),
                  const Text('Expense total'),
                  Text(current.expensesLabel!),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Household members can keep a copy. You cannot take this snapshot back. '
                  'Later private changes will not update it. It does not change the shared balance.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Older apps cannot read summaries. Ask everyone to update before sharing.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Everyone in this household has updated to the summary-capable app.',
                  ),
                  value: updated,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => updated = value ?? false),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (busy) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, false),
            child: const Text('Keep private'),
          ),
          if (current != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      preview = null;
                      updated = false;
                      error = null;
                    }),
              child: const Text('Change selection'),
            ),
          FilledButton(
            onPressed: busy
                ? null
                : current == null
                ? (income || expenses ? _prepare : null)
                : (updated ? _publish : null),
            child: Text(
              current == null ? 'Preview totals' : 'Share these totals',
            ),
          ),
        ],
      ),
    );
  }
}
