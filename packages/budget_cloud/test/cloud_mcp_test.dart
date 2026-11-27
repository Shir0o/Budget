import 'dart:convert';

import 'package:budget_cloud/budget_cloud.dart';
import 'package:budget_core/budget_core.dart';
import 'package:budget_mcp/tools.dart';
import 'package:budget_sync/core.dart';
import 'package:test/test.dart';

// ADR 0004. A synthetic budget: every name and amount is made up.

final class _Phone {
  _Phone() {
    engine.execute(const CreateBudget(name: 'Home'));
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
  }

  final log = InMemoryEventLog();
  late final engine = BudgetEngine(
    log: log,
    deviceId: 'phone',
    actor: Actor.userAndroid,
  );
  var book = SyncBook.off;

  Future<SyncOutcome> sync(DriveGateway drive, BudgetKey key) async {
    final outcome = await SyncClient(drive: drive)
        .sync(engine: engine, key: key, book: book);
    book = outcome.book;
    return outcome;
  }

  String get budgetId => engine.state.budget!.id;
  Transaction get bankLine =>
      engine.state.transactions.singleWhere((t) => t.bankId == 'b-1');
}

void main() {
  late InMemoryDrive drive;
  late BudgetKey key;
  late _Phone phone;

  setUp(() async {
    drive = InMemoryDrive();
    key = BudgetKey.generate();
    phone = _Phone();
    expect((await phone.sync(drive, key)).error, isNull);
  });

  CloudMcp cloud({
    McpMode mode = McpMode.readWrite,
    Set<String>? writeTools,
    BudgetKey? withKey,
  }) => CloudMcp(
    drive: drive,
    config: CloudConfig(
      pairing: PairingPayload(budgetId: phone.budgetId, key: withKey ?? key),
      mode: mode,
      writeTools: writeTools,
    ),
  );

  Map<String, Object?> body(ToolResult result) =>
      (jsonDecode(result.text) as Map).cast<String, Object?>();

  test('reads the budget the phone synced', () async {
    final result = await cloud(mode: McpMode.readOnly)
        .call('list_accounts', {'budgetId': phone.budgetId});

    expect(result.isError, isFalse);
    final accounts = body(result)['accounts'] as List;
    expect(accounts, hasLength(1));
    // Read-only never writes to Drive.
    expect(await _folders(drive, phone.budgetId), ['phone']);
  });

  test('lists read tools only when read-only', () {
    final names = [
      for (final tool in cloud(mode: McpMode.readOnly).toolList) tool['name'],
    ];
    expect(names, contains('get_month'));
    expect(names, isNot(contains('suggest_review')));
  });

  test('read-write lists only the allowed write tools', () {
    final names = {for (final tool in cloud().toolList) tool['name']};
    expect(names, containsAll(CloudConfig.defaultWriteTools));
    expect(names, isNot(contains('create_transaction')));
    expect(names, isNot(contains('assign')));
    expect(names.where((n) => '$n'.startsWith('delete')), isEmpty);
    expect(names, isNot(contains('mark_reviewed')));
  });

  test(
    'a suggestion syncs to the phone and the line stays Unreviewed',
    () async {
      final line = phone.bankLine;
      final groceries = phone.engine.state.categories.single.id;

      final result = await cloud().call('suggest_review', {
        'budgetId': phone.budgetId,
        'transactionId': line.id,
        'lineId': line.lines.single.id,
        'categoryId': groceries,
        'business': 'personal',
      }, client: 'Claude');

      expect(result.isError, isFalse, reason: result.text);
      expect(body(result)['actor'], 'mcp:Claude');
      expect(await _folders(drive, phone.budgetId), ['cloud-mcp', 'phone']);

      expect((await phone.sync(drive, key)).error, isNull);
      final synced = phone.bankLine.lines.single;
      expect(synced.category, groceries);
      expect(synced.reviewed, isFalse);
    },
  );

  test(
    'a second write takes the next segment and a revert undoes it',
    () async {
      final line = phone.bankLine;
      final groceries = phone.engine.state.categories.single.id;
      final server = cloud();
      final first = await server.call('update_transaction', {
        'budgetId': phone.budgetId,
        'transactionId': line.id,
        'memo': 'Weekly shop',
      });
      expect(first.isError, isFalse, reason: first.text);
      final second = await server.call('suggest_review', {
        'budgetId': phone.budgetId,
        'transactionId': line.id,
        'lineId': line.lines.single.id,
        'categoryId': groceries,
      });
      expect(second.isError, isFalse, reason: second.text);
      final revert = await server.call('revert_change', {
        'budgetId': phone.budgetId,
        'groupId': body(second)['groupId'],
      });
      expect(revert.isError, isFalse, reason: revert.text);

      expect(await _files(drive, phone.budgetId, 'cloud-mcp'), [
        'manifest.bin',
        'seg-000001.bin',
        'seg-000002.bin',
        'seg-000003.bin',
      ]);
      await phone.sync(drive, key);
      expect(phone.bankLine.memo, 'Weekly shop');
      expect(phone.bankLine.lines.single.category, isNull);
    },
  );

  test('refuses writes when read-only, and tools it doesn’t offer', () async {
    final readOnly = await cloud(mode: McpMode.readOnly)
        .call('suggest_review', {'budgetId': phone.budgetId});
    expect(body(readOnly)['error'], 'This server is read-only.');

    final notOffered = await cloud().call('assign', {
      'budgetId': phone.budgetId,
      'categoryId': 'x',
      'amountCents': 100,
    });
    expect(body(notOffered)['error'], 'This server doesn’t offer “assign”.');

    final never = await cloud().call('mark_reviewed', {});
    expect(notOffered.isError && never.isError, isTrue);
    expect('${body(never)['error']}', contains('can’t mark lines Reviewed'));
    expect(await _folders(drive, phone.budgetId), ['phone']);
  });

  test('a wrong Budget Key reads nothing', () async {
    final result = await cloud(withKey: BudgetKey.generate())
        .call('list_accounts', {'budgetId': phone.budgetId});
    expect(result.isError, isTrue);
  });

  test('parses the Worker settings', () {
    final code = PairingPayload(budgetId: 'b-1', key: key).code;
    final config = CloudConfig.parse(
      pairingCode: code,
      mode: 'read-write',
      writeTools: 'suggest_review, revert_change',
    );
    expect(config.mode, McpMode.readWrite);
    expect(config.writeTools, {'suggest_review', 'revert_change'});
    expect(config.deviceId, 'cloud-mcp');
    expect(CloudConfig.parse(pairingCode: code).mode, McpMode.readOnly);
    expect(
      () => CloudConfig.parse(pairingCode: code, mode: 'admin'),
      throwsArgumentError,
    );
    expect(
      () => CloudConfig.parse(pairingCode: 'nope'),
      throwsA(isA<SyncException>()),
    );
  });
}

Future<List<String>> _folders(DriveGateway drive, String budgetId) async {
  final budget = (await drive.list(null))
      .singleWhere((f) => f.name == budgetId);
  return [for (final f in await drive.list(budget.id)) f.name]..sort();
}

Future<List<String>> _files(
  DriveGateway drive,
  String budgetId,
  String device,
) async {
  final budget = (await drive.list(null))
      .singleWhere((f) => f.name == budgetId);
  final folder = (await drive.list(budget.id))
      .singleWhere((f) => f.name == device);
  return [for (final f in await drive.list(folder.id)) f.name]..sort();
}
