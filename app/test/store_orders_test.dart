import 'dart:convert';
import 'dart:typed_data';

import 'package:budget/screens/store_orders_screen.dart';
import 'package:budget/services.dart';
import 'package:budget_core/budget_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Issue 4. Every order, item and amount here is made up.
const _csv = '''
Date,Order,Item,Amount
11/05/2026,W-1,Paper towels,12.48
11/05/2026,W-1,Bananas,1.52
''';

BudgetEngine _engine() {
  final engine = BudgetEngine(
    log: InMemoryEventLog(),
    deviceId: 'test-device',
    actor: Actor.userAndroid,
  );
  engine.execute(const CreateBudget(name: 'Home'));
  engine.execute(
    AddAccount(
      name: 'Checking',
      type: AccountType.checking,
      startingBalance: const Money(100000),
      asOf: CivilDate(2026, 11, 1),
    ),
  );
  engine.execute(
    ImportBankTransactions(
      entries: [
        BankEntry(
          accountId: engine.state.accounts.single.id,
          bankId: 'b-1',
          date: CivilDate(2026, 11, 6),
          amount: const Money(-1400),
          description: 'WALMART SUPERCENTER',
        ),
      ],
    ),
  );
  return engine;
}

Future<(BudgetEngine, AppServices)> _open(WidgetTester tester) async {
  final engine = _engine();
  final services = AppServices.inMemory();
  (services.loader as InMemoryFileLoader).next = Uint8List.fromList(
    utf8.encode(_csv),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: StoreOrdersScreen(engine: engine, services: services),
    ),
  );
  await tester.tap(find.text('Walmart'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('store-choose-file')));
  await tester.pumpAndSettle();
  return (engine, services);
}

Transaction _line(BudgetEngine engine) => engine.state.transactions.singleWhere(
  (t) => t.payee == 'WALMART SUPERCENTER',
);

void main() {
  testWidgets('splitting a matched order keeps every line unreviewed', (
    tester,
  ) async {
    final (engine, _) = await _open(tester);
    expect(find.text('1 orders read · 1 match a bank line'), findsOneWidget);
    expect(find.text('Paper towels'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('store-split')));
    await tester.pumpAndSettle();

    final transaction = _line(engine);
    expect(
      [for (final l in transaction.lines) l.memo],
      ['Paper towels', 'Bananas'],
    );
    expect(transaction.lines.every((l) => !l.reviewed), isTrue);
    expect(transaction.lines.every((l) => l.category == null), isTrue);
    expect(find.text('1 orders read · 0 match a bank line'), findsOneWidget);
  });

  testWidgets('adding item names only sets the memo', (tester) async {
    final (engine, _) = await _open(tester);

    await tester.tap(find.byKey(const ValueKey('store-add-names')));
    await tester.pumpAndSettle();

    final transaction = _line(engine);
    expect(transaction.memo, 'Paper towels; Bananas');
    expect(transaction.lines, hasLength(1));
    expect(transaction.lines.single.reviewed, isFalse);
  });
}
