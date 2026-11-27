// Writes a made-up synced budget, as Google Drive's app data folder would
// hold it, for the Worker's smoke test (mcp/test/smoke.mjs). Every name and
// amount is made up. Run: dart run tool/smoke_fixture.dart <out.json> [n],
// n being how many extra made-up transactions to add, for timing.
import 'dart:convert';
import 'dart:io';

import 'package:budget_core/budget_core.dart';
import 'package:budget_sync/core.dart';

Future<void> main(List<String> args) async {
  final engine = BudgetEngine(
    log: InMemoryEventLog(),
    deviceId: 'phone',
    actor: Actor.userAndroid,
  );
  engine.execute(const CreateBudget(name: 'Sample'));
  engine.execute(
    AddAccount(
      name: 'Checking',
      type: AccountType.checking,
      startingBalance: const Money(100000),
      asOf: CivilDate(2026, 11, 1),
    ),
  );
  engine.execute(const CreateCategoryGroup(name: 'Everyday'));
  engine.execute(
    CreateCategory(
      groupId: engine.state.categoryGroups.single.id,
      name: 'Groceries',
    ),
  );
  engine.execute(
    ImportBankTransactions(
      entries: [
        BankEntry(
          accountId: engine.state.accounts.single.id,
          bankId: 'b-1',
          date: CivilDate(2026, 11, 10),
          amount: const Money(-2550),
          description: 'Corner Market',
        ),
      ],
    ),
  );
  final extra = args.length > 1 ? int.parse(args[1]) : 0;
  final account = engine.state.accounts.single.id;
  final category = engine.state.categories.single.id;
  for (var i = 0; i < extra; i++) {
    engine.execute(
      CreateTransaction(
        accountId: account,
        date: CivilDate(2024, 1, 1).addDays(i % 1000),
        payee: 'Shop ${i % 50}',
        amount: Money(-(100 + i % 900)),
        lines: [
          LineInput(
            amount: Money(-(100 + i % 900)),
            category: category,
            business: const Personal(),
          ),
        ],
      ),
    );
  }
  final drive = InMemoryDrive();
  final key = BudgetKey.generate();
  final outcome = await SyncClient(drive: drive)
      .sync(engine: engine, key: key, book: const SyncBook(enabled: true));
  if (outcome.error case final error?) throw StateError(error);

  final files = <Map<String, Object?>>[];
  Future<void> walk(String? parent) async {
    for (final entry in await drive.list(parent)) {
      files.add({
        'id': entry.id,
        'name': entry.name,
        'parent': parent ?? 'appDataFolder',
        'folder': entry.isFolder,
        if (!entry.isFolder)
          'bytes': base64.encode(await drive.download(entry.id)),
      });
      if (entry.isFolder) await walk(entry.id);
    }
  }

  await walk(null);
  final line = engine.state.transactions.singleWhere((t) => t.bankId == 'b-1');
  await File(args.first).writeAsString(
    jsonEncode({
      'pairingCode': PairingPayload(
        budgetId: engine.state.budget!.id,
        key: key,
      ).code,
      'budgetId': engine.state.budget!.id,
      'transactionId': line.id,
      'lineId': line.lines.single.id,
      'categoryId': engine.state.categories.single.id,
      'files': files,
    }),
  );
}
