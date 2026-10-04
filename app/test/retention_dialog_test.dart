import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/retention_codes.dart';
import 'package:private_ledger/features/household/retention_dialog.dart';

final _request = encodeRetentionRequest(Uint8List.fromList([1, 2, 3]));
final _approval = encodeRetentionConsent(Uint8List.fromList([4, 5, 6]));

Future<void> _open(
  WidgetTester tester, {
  Future<String?> Function()? prepare,
  Future<String?> Function(String)? approve,
  Future<bool> Function(String, List<String>)? reclaim,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => RetentionDialog(
                prepare: prepare ?? () async => _request,
                approve: approve ?? (_) async => _approval,
                reclaim: reclaim ?? (_, _) async => true,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('complete request and approval codes have accessible labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final request = encodeRetentionRequest(Uint8List(1024));
      final approval = encodeRetentionConsent(Uint8List(1024));
      await _open(
        tester,
        prepare: () async => request,
        approve: (_) async => approval,
      );
      await _tap(tester, 'Prepare request');
      await tester.ensureVisible(find.text(request));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(request), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Request code'),
        request,
      );
      await _tap(tester, 'Review approval');
      await _tap(tester, 'Approve deletion');
      await tester.ensureVisible(find.text(approval));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(approval), findsOneWidget);
      expect(find.text(approval), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'labels, targets, contrast and keyboard close at 200 percent phone text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      try {
        var signed = false;
        await _open(
          tester,
          scale: 2,
          prepare: () async {
            signed = true;
            return _request;
          },
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        var reachedClose = false;
        for (var i = 0; i < 20; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final button = FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<TextButton>();
          if (button?.child is Text &&
              (button!.child as Text).data == 'Close') {
            reachedClose = true;
            break;
          }
        }
        expect(reachedClose, true);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(RetentionDialog), findsNothing);
        expect(signed, false);
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets('opening and cancelling sign nothing', (tester) async {
    var calls = 0;
    await _open(
      tester,
      prepare: () async {
        calls++;
        return _request;
      },
    );
    expect(calls, 0);
    await _tap(tester, 'Close');
    expect(calls, 0);
    expect(find.byType(RetentionDialog), findsNothing);
  });

  testWidgets('approval requires confirmation and copies exact returned code', (
    tester,
  ) async {
    final seen = <String>[];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _open(
      tester,
      approve: (code) async {
        seen.add(code);
        return _approval;
      },
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Request code'),
      _request,
    );
    await _tap(tester, 'Review approval');
    expect(seen, isEmpty);
    await _tap(tester, 'Keep relay copies');
    expect(seen, isEmpty);
    await _tap(tester, 'Review approval');
    await _tap(tester, 'Approve deletion');
    expect(seen, [_request]);
    await _tap(tester, 'Copy approval code');
    expect(copied, _approval);
    await tester.enterText(
      find.widgetWithText(TextField, 'Request code'),
      '${_request}x',
    );
    await tester.pump();
    expect(find.text('Copy approval code'), findsNothing);
  });

  testWidgets('deletion asks first; renewed request clears prior approvals', (
    tester,
  ) async {
    final seen = <List<String>>[];
    var requests = 0;
    await _open(
      tester,
      prepare: () async {
        requests++;
        return _request;
      },
      reclaim: (request, codes) async {
        expect(request, _request);
        seen.add(codes);
        return true;
      },
    );
    await _tap(tester, 'Prepare request');
    await tester.enterText(
      find.widgetWithText(TextField, 'Approval codes'),
      _approval,
    );
    await _tap(tester, 'Prepare new request');
    expect(requests, 2);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Approval codes'))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Approval codes'),
      '\n$_approval\n',
    );
    await _tap(tester, 'Review deletion');
    expect(seen, isEmpty);
    await _tap(tester, 'Keep relay copies');
    expect(seen, isEmpty);
    await _tap(tester, 'Review deletion');
    await _tap(tester, 'Delete relay copies');
    expect(seen, [
      [_approval],
    ]);
    expect(find.byType(RetentionDialog), findsNothing);
  });

  testWidgets('malformed request and failed deletion are not success', (
    tester,
  ) async {
    var called = false;
    await _open(
      tester,
      approve: (_) async {
        called = true;
        return _approval;
      },
      reclaim: (_, _) async => false,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Request code'),
      'cashbk1:private-backup',
    );
    await _tap(tester, 'Review approval');
    expect(called, false);
    expect(find.text('Approve deletion?'), findsNothing);
    await _tap(tester, 'Prepare request');
    await _tap(tester, 'Review deletion');
    await _tap(tester, 'Delete relay copies');
    expect(
      find.textContaining('some copies may already be deleted'),
      findsOneWidget,
    );
    expect(find.byType(RetentionDialog), findsOneWidget);
  });

  testWidgets('busy work disables controls and enlarged phone text scrolls', (
    tester,
  ) async {
    final waiting = Completer<String?>();
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, scale: 2, prepare: () => waiting.future);
    await tester.ensureVisible(find.text('Prepare request'));
    await tester.tap(find.text('Prepare request'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Prepare request'),
          )
          .onPressed,
      isNull,
    );
    waiting.complete(_request);
    await tester.pumpAndSettle();
    await _tap(tester, 'Copy request code');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Close');
  });
}
