import 'package:budget/app.dart';
import 'package:budget/budget_library.dart';
import 'package:budget/services.dart';
import 'package:budget/widgets.dart';
import 'package:budget_core/budget_core.dart';
import 'package:budget_sync/budget_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A synthetic budget called Home with one account.
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
      startingBalance: const Money(150000),
      asOf: today(),
    ),
  );
  return engine;
}

AppServices _services(InMemoryDriveSignIn signIn, [DriveGateway? drive]) =>
    AppServices(
      keys: InMemoryBudgetKeyStore(),
      prefs: InMemoryDevicePrefs(),
      saver: InMemoryFileSaver(),
      authenticator: FakeAuthenticator(),
      drive: drive ?? InMemoryDrive(),
      driveSignIn: signIn,
    );

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openSync(WidgetTester tester) async {
  await _tap(tester, find.byTooltip('Settings'));
  await _tap(tester, find.text('Encrypted sync'));
}

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).enabled;

void main() {
  testWidgets('sync waits for Google Drive to be connected', (tester) async {
    final signIn = InMemoryDriveSignIn(signedInAs: null);
    final services = _services(signIn);
    await tester.pumpWidget(BudgetApp(engine: _engine(), services: services));
    await _openSync(tester);

    expect(find.byKey(const ValueKey('drive-account')), findsNothing);
    expect(_enabled(tester, 'turn-on-sync'), isFalse);

    await _tap(tester, find.byKey(const ValueKey('connect-drive')));

    expect(signIn.connects, 1);
    expect(find.text('sam@example.com'), findsOneWidget);
    expect(_enabled(tester, 'turn-on-sync'), isTrue);
    expect((services.drive as InMemoryDrive).uploads, isEmpty);
  });

  testWidgets('a cancelled sign-in says so and changes nothing', (
    tester,
  ) async {
    final signIn = InMemoryDriveSignIn(signedInAs: null, connectsAs: null);
    await tester.pumpWidget(
      BudgetApp(engine: _engine(), services: _services(signIn)),
    );
    await _openSync(tester);

    await _tap(tester, find.byKey(const ValueKey('connect-drive')));

    expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    expect(await signIn.account(), isNull);
    expect(_enabled(tester, 'turn-on-sync'), isFalse);
  });

  testWidgets('a build without a Google client says sync can’t run', (
    tester,
  ) async {
    final signIn = InMemoryDriveSignIn(signedInAs: null, available: false);
    await tester.pumpWidget(
      BudgetApp(engine: _engine(), services: _services(signIn)),
    );
    await _openSync(tester);

    expect(find.byKey(const ValueKey('drive-unavailable')), findsOneWidget);
    expect(find.byKey(const ValueKey('connect-drive')), findsNothing);
    expect(_enabled(tester, 'turn-on-sync'), isFalse);
  });

  testWidgets('sync stops at a lapsed sign-in and resumes on connect', (
    tester,
  ) async {
    final signIn = InMemoryDriveSignIn();
    final services = _services(signIn);
    final engine = _engine();
    await tester.pumpWidget(BudgetApp(engine: engine, services: services));
    await _openSync(tester);
    await _tap(tester, find.byKey(const ValueKey('turn-on-sync')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    final drive = services.drive as InMemoryDrive;
    final uploaded = drive.uploads.length;
    expect(uploaded, greaterThan(0));

    await _tap(tester, find.byKey(const ValueKey('drive-disconnect')));

    expect(await signIn.account(), isNull);
    expect(_enabled(tester, 'sync-now'), isFalse);

    engine.execute(
      CreateTransaction(
        accountId: engine.state.accounts.single.id,
        date: today(),
        amount: const Money(-1250),
        payee: 'Corner Bakery',
        lines: const [LineInput(amount: Money(-1250))],
      ),
    );
    await _tap(tester, find.byKey(const ValueKey('connect-drive')));

    // Connecting again syncs straight away.
    expect(drive.uploads.length, greaterThan(uploaded));
    expect(_enabled(tester, 'sync-now'), isTrue);
  });

  testWidgets('joining a budget needs the Google account first', (
    tester,
  ) async {
    final draft = BudgetEngine(
      log: InMemoryEventLog(),
      deviceId: 'phone',
      actor: Actor.userAndroid,
    );
    final signIn = InMemoryDriveSignIn(signedInAs: null);
    final services = _services(signIn);
    await tester.pumpWidget(
      BudgetApp(
        library: BudgetLibrary.single(draft, prefs: services.prefs),
        services: services,
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('join-from-welcome')));

    expect(_enabled(tester, 'join-budget'), isFalse);

    await _tap(tester, find.byKey(const ValueKey('connect-drive')));

    expect(find.text('sam@example.com'), findsOneWidget);
    expect(_enabled(tester, 'join-budget'), isTrue);
  });
}
