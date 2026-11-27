import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:budget_core/budget_core.dart';
import 'package:budget_migration/budget_migration.dart';
import 'package:test/test.dart';

// Issue 4. Every order, item and amount here is made up.

/// The columns of Amazon's order history export that matter, plus a few it
/// also has.
const _amazonCsv = '''
"Website","Order ID","Order Date","Currency","Unit Price","Total Owed","Quantity","Order Status","Ship Date","Product Name"
"Amazon.com","111-0000001-0000001","2026-11-02T18:32:10Z","USD","10.00","10.83","1","Closed","2026-11-03T09:00:00Z","Sample Notebook, 3-pack"
"Amazon.com","111-0000001-0000001","2026-11-02T18:32:10Z","USD","5.00","10.83","2","Closed","2026-11-03T09:00:00Z","Blue Pens"
"Amazon.com","111-0000001-0000001","2026-11-02T18:32:10Z","USD","20.00","21.65","1","Closed","2026-11-06T09:00:00Z","Desk Lamp"
"Amazon.com","111-0000002-0000002","2026-11-04T10:00:00Z","USD","8.00","8.66","1","Cancelled","Not Available","Cancelled Thing"
''';

/// A simple CSV for any store.
const _simpleCsv = '''
Date,Order,Item,Amount
11/05/2026,W-1,Paper towels,12.48
11/05/2026,W-1,Bananas,1.52
''';

final class _Budget {
  _Budget() {
    engine.execute(const CreateBudget(name: 'Home'));
    engine.execute(
      AddAccount(
        name: 'Card',
        type: AccountType.checking,
        startingBalance: const Money(100000),
        asOf: CivilDate(2026, 11, 1),
      ),
    );
    account = engine.state.accounts.single.id;
  }

  final engine = BudgetEngine(
    log: InMemoryEventLog(),
    deviceId: 'test',
    actor: Actor.userAndroid,
  );
  late final String account;

  void bank(String id, String payee, int cents, int day) => engine.execute(
    ImportBankTransactions(
      entries: [
        BankEntry(
          accountId: account,
          bankId: id,
          date: CivilDate(2026, 11, day),
          amount: Money(cents),
          description: payee,
        ),
      ],
    ),
  );
}

void main() {
  group('readStoreOrders', () {
    test('groups Amazon rows by order and shipment, skipping cancelled', () {
      final charges = readStoreOrders(utf8.encode(_amazonCsv), Store.amazon);

      // Two shipments plus the whole order.
      expect(charges, hasLength(3));
      expect(charges[0].date, CivilDate(2026, 11, 3));
      expect(charges[0].total, const Money(2166));
      expect(
        [for (final item in charges[0].items) item.name],
        ['Sample Notebook, 3-pack', 'Blue Pens ×2'],
      );
      expect(charges[1].date, CivilDate(2026, 11, 6));
      expect(charges[1].total, const Money(2165));
      expect(charges[2].date, CivilDate(2026, 11, 2));
      expect(charges[2].total, const Money(4331));
    });

    test('reads the CSV inside Amazon’s zip', () {
      final archive = Archive()
        ..add(
          ArchiveFile.bytes(
            'Retail.OrderHistory.1/Retail.OrderHistory.1.csv',
            utf8.encode(_amazonCsv),
          ),
        );
      final zip = ZipEncoder().encodeBytes(archive);

      expect(readStoreOrders(zip, Store.amazon), hasLength(3));
    });

    test('reads a simple date, order, item, amount CSV', () {
      final charges = readStoreOrders(utf8.encode(_simpleCsv), Store.walmart);

      expect(charges, hasLength(1));
      expect(charges.single.total, const Money(1400));
      expect(charges.single.date, CivilDate(2026, 11, 5));
    });

    test('refuses a file without the columns it needs', () {
      expect(
        () => readStoreOrders(utf8.encode('a,b\n1,2\n'), Store.amazon),
        throwsA(isA<StoreOrdersException>()),
      );
    });
  });

  group('matchStoreOrders', () {
    test('matches each shipment to the bank line with its amount', () {
      final budget = _Budget()
        ..bank('b-1', 'AMZN Mktp US*2K4AB', -2166, 4)
        ..bank('b-2', 'Amazon.com*9ZZ11', -2165, 8)
        ..bank('b-3', 'Corner Bistro', -2166, 4);
      final charges = readStoreOrders(utf8.encode(_amazonCsv), Store.amazon);

      final matches = matchStoreOrders(budget.engine.state, charges);

      expect(matches, hasLength(2));
      final byBank = {for (final m in matches) m.transaction.bankId: m};
      expect(byBank['b-1']!.memo(), 'Sample Notebook, 3-pack; Blue Pens ×2');
      expect(byBank['b-2']!.memo(), 'Desk Lamp');
    });

    test('leaves out a line outside the date window', () {
      final budget = _Budget()..bank('b-1', 'AMZN Mktp US', -2165, 20);
      final charges = readStoreOrders(utf8.encode(_amazonCsv), Store.amazon);

      expect(matchStoreOrders(budget.engine.state, charges), isEmpty);
    });

    test('split lines sum to the bank line and stay Unreviewed', () {
      final budget = _Budget()..bank('b-1', 'WALMART.COM 800-555', -1400, 6);
      final charges = readStoreOrders(utf8.encode(_simpleCsv), Store.walmart);
      final match = matchStoreOrders(budget.engine.state, charges).single;

      final result = budget.engine.execute(
        EditTransaction(
          transactionId: match.transaction.id,
          memo: match.memo(),
          lines: match.splitLines(),
        ),
      );

      expect(result, isA<Accepted>());
      final edited = budget.engine.state.transaction(match.transaction.id)!;
      expect(edited.memo, 'Paper towels; Bananas');
      expect(edited.lines, hasLength(2));
      expect(edited.lines.map((line) => line.memo), [
        'Paper towels',
        'Bananas',
      ]);
      expect(edited.lines.every((line) => !line.reviewed), isTrue);
      expect(budget.engine.state.reviewQueue, hasLength(2));
    });
  });
}
