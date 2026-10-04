import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/ledger/category_edit_dialog.dart';
import 'package:private_ledger/features/ledger/category_presets.dart';
import 'package:private_ledger/theme.dart';

const iconLabels = {
  'shopping_cart': 'Shopping cart icon',
  'restaurant': 'Dining icon',
  'directions_car': 'Car icon',
  'home': 'Home icon',
  'attach_money': 'Money icon',
  'shopping_bag': 'Shopping bag icon',
  'flight': 'Travel icon',
  'fitness_center': 'Fitness icon',
  'pets': 'Pets icon',
  'school': 'Education icon',
  'movie': 'Entertainment icon',
  'local_hospital': 'Health icon',
};

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('named icon choices fit $size, $brightness, 2x text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: ledgerTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(
                body: CategoryEditDialog(
                  initialName: 'Household supplies',
                  initialIconKey: 'restaurant',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final key in availableCategoryIconKeys) {
            expect(
              find.widgetWithIcon(ChoiceChip, categoryIcon(key)).hitTestable(),
              findsOneWidget,
            );
          }
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets(
    'every icon choice has a distinct accessible name and selected state',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ledgerTheme(Brightness.light),
            home: const Scaffold(
              body: CategoryEditDialog(
                initialName: 'Groceries',
                initialIconKey: 'restaurant',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(availableCategoryIconKeys.toSet(), iconLabels.keys.toSet());
        for (final entry in iconLabels.entries) {
          final chip = find.widgetWithIcon(ChoiceChip, categoryIcon(entry.key));
          final node = tester.getSemantics(chip);
          expect(node.label, entry.value);
          expect(
            node.flagsCollection.isSelected,
            entry.key == 'restaurant' ? Tristate.isTrue : Tristate.isFalse,
          );
        }
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'choosing an icon saves its original stable key rather than the display label',
    (tester) async {
      CategoryDraft? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: ledgerTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showDialog<CategoryDraft>(
                    context: context,
                    builder: (_) => const CategoryEditDialog(
                      initialName: 'Holiday',
                      initialIconKey: 'restaurant',
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithIcon(ChoiceChip, Icons.flight_outlined));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithIcon(ChoiceChip, Icons.flight_outlined),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(saved?.name, 'Holiday');
      expect(saved?.iconKey, 'flight');
    },
  );
}
