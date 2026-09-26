import 'package:flutter/material.dart';

import '../../data/rust/api/goals.dart';
import '../../data/rust/api/ledger.dart';

/// Shows every goal's current progress. Progress is computed fresh by the
/// Rust core each time (see `goal_progress`), so this widget is purely
/// presentational.
class GoalsPane extends StatelessWidget {
  const GoalsPane({required this.goals, super.key});

  final List<GoalView> goals;

  @override
  Widget build(BuildContext context) {
    if (goals.isEmpty) {
      return const _EmptyGoals();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: goals.length,
      itemBuilder: (context, index) => _GoalCard(goal: goals[index]),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal});

  final GoalView goal;

  @override
  Widget build(BuildContext context) {
    final percent = goal.percentComplete.toInt();
    final theme = Theme.of(context);
    // A save goal is doing well the closer it is to (or past) its target; a
    // spend goal is doing well the *further* it stays under its cap, so
    // "over" means the opposite thing for each kind.
    final isOver = goal.isSave ? false : percent > 100;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  goal.isSave
                      ? Icons.savings_outlined
                      : Icons.trending_down_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(goal.name, style: theme.textTheme.titleMedium),
                ),
                Text(
                  goal.isSave ? 'Save' : 'Spend',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (percent / 100).clamp(0, 1).toDouble(),
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: isOver ? theme.colorScheme.error : theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${goal.progressLabel} of ${goal.targetLabel}'),
                Text(
                  '$percent%',
                  style: TextStyle(
                    color: isOver ? theme.colorScheme.error : null,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyGoals extends StatelessWidget {
  const _EmptyGoals();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('No goals yet. Tap Add to set a saving or spending goal.'),
      ),
    );
  }
}

class GoalDraft {
  const GoalDraft({
    required this.name,
    required this.kind,
    required this.targetAmount,
    this.linkedAccountId,
  });

  final String name;
  final GoalKind kind;
  final String targetAmount;
  final String? linkedAccountId;
}

class NewGoalDialog extends StatefulWidget {
  const NewGoalDialog({required this.accounts, super.key});

  final List<AccountView> accounts;

  @override
  State<NewGoalDialog> createState() => _NewGoalDialogState();
}

class _NewGoalDialogState extends State<NewGoalDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _targetController = TextEditingController();
  GoalKind _kind = GoalKind.save;
  String? _linkedAccountId;

  @override
  void initState() {
    super.initState();
    _linkedAccountId = widget.accounts.isNotEmpty
        ? widget.accounts.first.id
        : null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New goal'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) =>
                    (value == null || value.trim().isEmpty)
                    ? 'Enter a name'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<GoalKind>(
                key: const Key('goalKindDropdown'),
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: const [
                  DropdownMenuItem(
                    value: GoalKind.save,
                    child: Text('Save toward a target'),
                  ),
                  DropdownMenuItem(
                    value: GoalKind.spend,
                    child: Text('Spend under a cap'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => _kind = value ?? GoalKind.save),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _targetController,
                decoration: const InputDecoration(labelText: 'Target amount'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) =>
                    (value == null || value.trim().isEmpty)
                    ? 'Enter a target'
                    : null,
              ),
              if (_kind == GoalKind.save) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('goalAccountDropdown'),
                  initialValue: _linkedAccountId,
                  decoration: const InputDecoration(labelText: 'Account'),
                  items: [
                    for (final account in widget.accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(account.name),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _linkedAccountId = value),
                  validator: (value) => (_kind == GoalKind.save && value == null)
                      ? 'Choose an account'
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(
      GoalDraft(
        name: _nameController.text,
        kind: _kind,
        targetAmount: _targetController.text.trim(),
        linkedAccountId: _kind == GoalKind.save ? _linkedAccountId : null,
      ),
    );
  }
}
