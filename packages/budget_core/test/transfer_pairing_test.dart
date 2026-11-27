import 'package:budget_core/budget_core.dart';
import 'package:test/test.dart';

// Issue 3: the two bank-imported sides of a transfer or card payment are
// proposed as one transfer, and a person links them. Every amount and name
// here is made up.

final _nov1 = CivilDate(2026, 11, 1);
final _nov = CalendarMonth(2026, 11);

List<Event> _accepted(CommandResult result) {
  expect(result, isA<Accepted>());
  return (result as Accepted).events;
}

Rejection _rejected(CommandResult result) {
  expect(result, isA<Rejected>());
  return (result as Rejected).reason;
}

/// A budget with Checking, a Visa card and a Savings account.
final class _Budget {
  _Budget() {
    run(const CreateBudget(name: 'Home'));
    checking = _account('Checking', AccountType.checking, 100000);
    savings = _account('Savings', AccountType.savings, 0);
    visa = _account('Visa', AccountType.creditCard, 0);
  }

  final log = InMemoryEventLog();
  late final String checking;
  late final String savings;
  late final String visa;

  String _account(String name, AccountType type, int cents) =>
      run(
            AddAccount(
              name: name,
              type: type,
              startingBalance: Money(cents),
              asOf: _nov1,
            ),
          ).first.payload['accountId']
          as String;

  BudgetEngine engine([Actor actor = Actor.userAndroid]) => BudgetEngine(
    log: log,
    deviceId: 'device-a',
    actor: actor,
    nowMs: () => DateTime(2026, 11, 20, 9).millisecondsSinceEpoch,
  );

  BudgetState get state => BudgetState.replay(log.readAll());

  CommandResult execute(Command command, [Actor actor = Actor.userAndroid]) =>
      engine(actor).execute(command);

  List<Event> run(Command command, [Actor actor = Actor.userAndroid]) =>
      _accepted(execute(command, actor));

  /// One fetch of [entries] across every account.
  void fetch(List<BankEntry> entries) => run(
    ImportBankTransactions(
      entries: entries,
      fetchedAccounts: [checking, savings, visa],
    ),
  );

  BankEntry entry(
    String accountId,
    String bankId,
    int cents,
    int day, {
    String payee = 'Payment',
    bool pending = false,
  }) => BankEntry(
    accountId: accountId,
    bankId: bankId,
    date: CivilDate(2026, 11, day),
    amount: Money(cents),
    description: payee,
    pending: pending,
  );

  Transaction bankLine(String accountId, String bankId) =>
      state.bankTransaction(accountId, bankId)!;
}

void main() {
  group('proposedTransfers', () {
    test('a card payment from checking is proposed once posted', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -25000, 10),
        budget.entry(budget.visa, 'v-1', 25000, 12),
      ]);

      final proposals = budget.state.proposedTransfers;
      expect(proposals, hasLength(1));
      expect(proposals.single.outflow.bankId, 'c-1');
      expect(proposals.single.inflow.bankId, 'v-1');
    });

    test('pending lines, far-apart dates and unequal amounts are left out', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -25000, 10, pending: true),
        budget.entry(budget.visa, 'v-1', 25000, 11),
        budget.entry(budget.checking, 'c-2', -4000, 1),
        budget.entry(budget.savings, 's-2', 4000, 9),
        budget.entry(budget.checking, 'c-3', -3000, 10),
        budget.entry(budget.savings, 's-3', 3100, 10),
      ]);

      expect(budget.state.proposedTransfers, isEmpty);
    });

    test('lines in the same account are never a pair', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -2000, 10),
        budget.entry(budget.checking, 'c-2', 2000, 10, payee: 'Refund'),
      ]);

      expect(budget.state.proposedTransfers, isEmpty);
    });

    test('a line someone already reviewed is no longer proposed', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -2000, 10),
        budget.entry(budget.savings, 's-1', 2000, 10),
      ]);
      final line = budget.bankLine(budget.checking, 'c-1');
      final group = budget
          .run(const CreateCategoryGroup(name: 'Everyday'))
          .single;
      final category =
          budget
                  .run(
                    CreateCategory(
                      groupId: group.payload['categoryGroupId'] as String,
                      name: 'Groceries',
                    ),
                  )
                  .single
                  .payload['categoryId']
              as String;
      budget.run(
        ReviewLine(
          transactionId: line.id,
          lineId: line.lines.single.id,
          category: category,
          business: const Personal(),
        ),
      );

      expect(budget.state.proposedTransfers, isEmpty);
    });

    test('each line pairs once, with the closest date', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -5000, 10),
        budget.entry(budget.savings, 's-1', 5000, 14),
        budget.entry(budget.savings, 's-2', 5000, 11),
      ]);

      final proposals = budget.state.proposedTransfers;
      expect(proposals, hasLength(1));
      expect(proposals.single.inflow.bankId, 's-2');
    });
  });

  group('LinkTransfer', () {
    test(
      'turns the two bank lines into one transfer that keeps both sides',
      () {
        final budget = _Budget();
        budget.fetch([
          budget.entry(budget.checking, 'c-1', -25000, 10, payee: 'VISA PMT'),
          budget.entry(budget.visa, 'v-1', 25000, 12, payee: 'THANK YOU'),
        ]);
        final out = budget.bankLine(budget.checking, 'c-1');
        final into = budget.bankLine(budget.visa, 'v-1');

        budget.run(LinkTransfer(outflowId: out.id, inflowId: into.id));

        final state = budget.state;
        final checkingSide = state.bankTransaction(budget.checking, 'c-1')!;
        final visaSide = state.bankTransaction(budget.visa, 'v-1')!;
        expect(checkingSide.isTransfer, isTrue);
        expect(checkingSide.transferTransactionId, visaSide.id);
        expect(visaSide.transferTransactionId, checkingSide.id);
        expect(checkingSide.date, CivilDate(2026, 11, 10));
        expect(visaSide.date, CivilDate(2026, 11, 12));
        expect(checkingSide.payee, 'VISA PMT');
        expect(checkingSide.cleared, ClearedStatus.cleared);
        expect(state.transaction(out.id), isNull);
        expect(state.reviewQueue, isEmpty);
        expect(state.proposedTransfers, isEmpty);
        expect(state.balance(budget.checking), const Money(75000));
        expect(state.balance(budget.visa), const Money(25000));
      },
    );

    test('a card payment spends the Card Payment Category like a hand-made '
        'transfer', () {
      final linked = _Budget();
      linked.fetch([
        linked.entry(linked.checking, 'c-1', -25000, 10),
        linked.entry(linked.visa, 'v-1', 25000, 10),
      ]);
      linked.run(
        LinkTransfer(
          outflowId: linked.bankLine(linked.checking, 'c-1').id,
          inflowId: linked.bankLine(linked.visa, 'v-1').id,
        ),
      );

      final byHand = _Budget();
      byHand.run(
        CreateTransfer(
          fromAccountId: byHand.checking,
          toAccountId: byHand.visa,
          amount: const Money(25000),
          date: CivilDate(2026, 11, 10),
        ),
      );

      Money payment(_Budget budget) => budget.state.available(
        budget.state.cardPaymentCategory(budget.visa)!.id,
        _nov,
      );
      expect(payment(linked), payment(byHand));
      expect(
        linked.state.readyToAssign(_nov),
        byHand.state.readyToAssign(_nov),
      );
    });

    test('a later fetch updates the linked sides in place', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -25000, 10),
        budget.entry(budget.visa, 'v-1', 25000, 10),
      ]);
      budget.run(
        LinkTransfer(
          outflowId: budget.bankLine(budget.checking, 'c-1').id,
          inflowId: budget.bankLine(budget.visa, 'v-1').id,
        ),
      );
      final before = budget.state.transactions.length;

      budget.fetch([
        budget.entry(budget.checking, 'c-1', -26000, 11),
        budget.entry(budget.visa, 'v-1', 25000, 10),
      ]);

      final state = budget.state;
      expect(state.transactions, hasLength(before));
      final checkingSide = state.bankTransaction(budget.checking, 'c-1')!;
      final visaSide = state.bankTransaction(budget.visa, 'v-1')!;
      expect(checkingSide.date, CivilDate(2026, 11, 11));
      // The pair still nets to zero.
      expect(checkingSide.amount, const Money(-26000));
      expect(visaSide.amount, const Money(26000));
    });

    test('is one group that reverts to the two bank lines', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -2000, 10),
        budget.entry(budget.savings, 's-1', 2000, 10),
      ]);
      final out = budget.bankLine(budget.checking, 'c-1');
      final into = budget.bankLine(budget.savings, 's-1');
      final group = budget
          .run(LinkTransfer(outflowId: out.id, inflowId: into.id))
          .first
          .groupId;

      budget.run(RevertGroup(groupId: group));

      final state = budget.state;
      expect(state.transaction(out.id), isNotNull);
      expect(state.transaction(into.id), isNotNull);
      expect(state.bankTransaction(budget.checking, 'c-1')!.id, out.id);
      expect(state.transactions.where((t) => t.isTransfer), isEmpty);
      expect(state.proposedTransfers, hasLength(1));
    });

    test('only a person links', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -2000, 10),
        budget.entry(budget.savings, 's-1', 2000, 10),
      ]);

      expect(
        _rejected(
          budget.execute(
            LinkTransfer(
              outflowId: budget.bankLine(budget.checking, 'c-1').id,
              inflowId: budget.bankLine(budget.savings, 's-1').id,
            ),
            const Actor.fromValue('mcp:test-client'),
          ),
        ),
        Rejection.personRequired,
      );
    });

    test('refuses lines that are not one transfer', () {
      final budget = _Budget();
      budget.fetch([
        budget.entry(budget.checking, 'c-1', -2000, 10),
        budget.entry(budget.checking, 'c-2', 2000, 10),
        budget.entry(budget.savings, 's-1', 2100, 10),
      ]);
      final out = budget.bankLine(budget.checking, 'c-1').id;

      expect(
        _rejected(
          budget.execute(
            LinkTransfer(
              outflowId: out,
              inflowId: budget.bankLine(budget.checking, 'c-2').id,
            ),
          ),
        ),
        Rejection.notATransferPair,
      );
      expect(
        _rejected(
          budget.execute(
            LinkTransfer(
              outflowId: out,
              inflowId: budget.bankLine(budget.savings, 's-1').id,
            ),
          ),
        ),
        Rejection.notATransferPair,
      );
    });
  });

  test('transferPartnersFor lists opposite lines in other accounts, closest '
      'first', () {
    final budget = _Budget();
    budget.fetch([
      budget.entry(budget.checking, 'c-1', -2000, 10),
      budget.entry(budget.savings, 's-1', 2000, 20),
      budget.entry(budget.visa, 'v-1', 2000, 11),
      budget.entry(budget.savings, 's-2', 1999, 10),
    ]);

    final partners = budget.state.transferPartnersFor(
      budget.bankLine(budget.checking, 'c-1'),
    );
    expect([for (final t in partners) t.bankId], ['v-1', 's-1']);
  });
}
