import 'package:budget/screens/possible_transfer_screen.dart';
import 'package:budget_core/budget_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A synthetic budget with Checking and a Visa card, and the two bank sides
/// of one made-up card payment.
BudgetEngine _engine() {
  final engine = BudgetEngine(
    log: InMemoryEventLog(),
    deviceId: 'test-device',
    actor: Actor.userAndroid,
  );
  engine.execute(const CreateBudget(name: 'Home'));
  String account(String name, AccountType type) =>
      (engine.execute(
            AddAccount(
              name: name,
              type: type,
              startingBalance: const Money(100000),
              asOf: CivilDate(2026, 11, 1),
            ),
          ) as Accepted).events.first.payload['accountId']
          as String;
  final checking = account('Checking', AccountType.checking);
  final visa = account('Visa', AccountType.creditCard);
  engine.execute(
    ImportBankTransactions(
      entries: [
        BankEntry(
          accountId: checking,
          bankId: 'c-1',
          date: CivilDate(2026, 11, 10),
          amount: const Money(-25000),
          description: 'Card payment',
        ),
        BankEntry(
          accountId: visa,
          bankId: 'v-1',
          date: CivilDate(2026, 11, 12),
          amount: const Money(25000),
          description: 'Payment received',
        ),
      ],
    ),
  );
  return engine;
}

void main() {
  testWidgets('linking a possible transfer makes one transfer', (tester) async {
    final engine = _engine();
    expect(engine.state.proposedTransfers, hasLength(1));

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PossibleTransferScreen(engine: engine),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Card payment'), findsOneWidget);
    expect(find.text('Payment received'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('link-transfer')));
    await tester.pumpAndSettle();

    expect(engine.state.proposedTransfers, isEmpty);
    expect(engine.state.transactions.where((t) => t.isTransfer), hasLength(2));
    // The last link closes the screen.
    expect(find.byType(PossibleTransferScreen), findsNothing);
  });
}
