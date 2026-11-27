import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_core/budget_core.dart';
import 'package:budget_simplefin/budget_simplefin.dart';
import 'package:budget_sync/budget_sync.dart';
import 'package:budget_store/budget_store.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:local_auth/local_auth.dart';
import 'package:workmanager/workmanager.dart';

import 'budget_library.dart';
import 'services.dart';

// The real services: secure storage, the system file dialog and
// local_auth. Only `main.dart` uses these; tests use the in-memory ones.

/// The Keychain for keys and the device id. The data protection keychain
/// needs a `keychain-access-groups` entitlement, which ad-hoc and Developer
/// ID builds do not carry, so every write fails with -34018 and the app dies
/// before its first frame. The login keychain needs no entitlement and the
/// bundled `budget-mcp` can read the same items (ticket 13).
const deviceSecureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

/// WorkManager's names for the 6-hourly bank fetch (ticket 10).
const bankSyncTask = 'budget.bankSync';
const bankSyncUniqueName = 'budget.bankSync.periodic';

/// Android's WorkManager, arranging a fetch at most every 6 hours (ticket
/// 10). Android starts the work in its own isolate, so
/// `bankSyncDispatcher` rebuilds the device's services from secure storage
/// when it fires.
///
/// macOS has no background fetch in this ticket: bank sync there runs by
/// hand while the app is open, so this arranges nothing.
final class WorkManagerBankSyncScheduler implements BankSyncScheduler {
  const WorkManagerBankSyncScheduler();

  @override
  Future<void> schedule() async {
    if (!Platform.isAndroid) return;
    await Workmanager().registerPeriodicTask(
      bankSyncUniqueName,
      bankSyncTask,
      frequency: FetchSchedule.interval,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    await Workmanager().cancelByUniqueName(bankSyncUniqueName);
  }
}

/// The person's Actor on this platform, so history and the sync manifest
/// name the right device.
Actor userActorFor(String operatingSystem) =>
    operatingSystem == 'macos' ? Actor.userMac : Actor.userAndroid;

final class SecureBudgetKeyStore implements BudgetKeyStore {
  const SecureBudgetKeyStore(this._storage);

  final FlutterSecureStorage _storage;

  /// Where the key lives, next to nothing else.
  static String _name(String budgetId) => 'budget-key:$budgetId';

  @override
  Future<BudgetKey> keyFor(String budgetId) async {
    final existing = await _storage.read(key: _name(budgetId));
    if (existing != null) return BudgetKey.fromHex(existing);
    final key = BudgetKey.generate();
    await _storage.write(key: _name(budgetId), value: key.toHex());
    return key;
  }

  @override
  Future<BudgetKey?> existingKey(String budgetId) async {
    final existing = await _storage.read(key: _name(budgetId));
    return existing == null ? null : BudgetKey.fromHex(existing);
  }

  @override
  Future<void> writeKey(String budgetId, BudgetKey key) =>
      _storage.write(key: _name(budgetId), value: key.toHex());
}

final class SecureDevicePrefs implements DevicePrefs {
  const SecureDevicePrefs(this._storage);

  final FlutterSecureStorage _storage;

  static const _appLock = 'app-lock-enabled';
  static const _lastBackup = 'last-backup';
  static const _budgetIds = 'budget-ids';
  static const _lastBudgetId = 'last-budget-id';
  static const _simpleFin = 'simplefin-book';

  @override
  Future<bool> readAppLockEnabled() async =>
      await _storage.read(key: _appLock) == 'true';

  @override
  Future<void> writeAppLockEnabled(bool enabled) =>
      _storage.write(key: _appLock, value: '$enabled');

  @override
  Future<CivilDate?> readLastBackup() async {
    final iso = await _storage.read(key: _lastBackup);
    return iso == null ? null : CivilDate.parse(iso);
  }

  @override
  Future<void> writeLastBackup(CivilDate date) =>
      _storage.write(key: _lastBackup, value: date.toIso());

  @override
  Future<List<String>> readBudgetIds() async {
    final joined = await _storage.read(key: _budgetIds);
    return joined == null || joined.isEmpty ? [] : joined.split(',');
  }

  @override
  Future<void> writeBudgetIds(List<String> ids) =>
      _storage.write(key: _budgetIds, value: ids.join(','));

  @override
  Future<String?> readLastBudgetId() => _storage.read(key: _lastBudgetId);

  @override
  Future<void> writeLastBudgetId(String id) =>
      _storage.write(key: _lastBudgetId, value: id);

  @override
  Future<CalendarMonth?> readAutomationMonth(String budgetId) async {
    final iso = await _storage.read(key: 'automation-month:$budgetId');
    return iso == null ? null : CalendarMonth.parse(iso);
  }

  @override
  Future<void> writeAutomationMonth(String budgetId, CalendarMonth month) =>
      _storage.write(key: 'automation-month:$budgetId', value: month.toIso());

  @override
  Future<SimpleFinBook> readSimpleFinBook() async {
    final json = await _storage.read(key: _simpleFin);
    if (json == null) return const SimpleFinBook();
    return SimpleFinBook.fromJson(
      (jsonDecode(json) as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<void> writeSimpleFinBook(SimpleFinBook book) =>
      _storage.write(key: _simpleFin, value: jsonEncode(book.toJson()));

  @override
  Future<SyncBook> readSyncBook(String budgetId) async {
    final json = await _storage.read(key: 'sync-book:$budgetId');
    if (json == null) return SyncBook.off;
    return SyncBook.fromJson((jsonDecode(json) as Map).cast<String, Object?>());
  }

  @override
  Future<void> writeSyncBook(String budgetId, SyncBook book) => _storage.write(
    key: 'sync-book:$budgetId',
    value: jsonEncode(book.toJson()),
  );
}

/// Secure storage for a Google sign-in's refresh token and account.
final class SecureSignInStore implements SignInStore {
  const SecureSignInStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The OAuth client ids this build was given with `--dart-define`. The repo
/// holds none (docs/setup/google-drive-sign-in.md).
const googleDesktopClientId = String.fromEnvironment(
  'GOOGLE_DESKTOP_CLIENT_ID',
);
const googleDesktopClientSecret = String.fromEnvironment(
  'GOOGLE_DESKTOP_CLIENT_SECRET',
);

/// The sign-in for this platform: Google's Authorization API on Android, the
/// browser with a loopback redirect on the Mac.
DriveSignIn platformDriveSignIn(FlutterSecureStorage storage) {
  final store = SecureSignInStore(storage);
  if (Platform.isAndroid) return AndroidDriveSignIn(store);
  if (Platform.isMacOS && googleDesktopClientId.isNotEmpty) {
    return DesktopDriveSignIn(
      GoogleDesktopSignIn(
        clientId: googleDesktopClientId,
        clientSecret: googleDesktopClientSecret,
        store: store,
        transport: const HttpDriveTransport(),
        openBrowser: (uri) async {
          final result = await Process.run('open', [uri.toString()]);
          if (result.exitCode != 0) {
            throw const DriveException('Couldn’t open the browser.');
          }
        },
      ),
    );
  }
  return const UnavailableDriveSignIn();
}

/// Android: Google Play services' Authorization API. Google matches the app
/// by its package name and signing certificate, so the build carries no
/// client id. The account's email is kept so later tokens come silently.
final class AndroidDriveSignIn implements DriveSignIn {
  AndroidDriveSignIn(this._store);

  final SignInStore _store;
  Future<void>? _ready;

  static const _accountKey = 'google-account';

  GoogleSignInPlatform get _google => GoogleSignInPlatform.instance;

  Future<void> _init() => _ready ??= _google.init(const InitParameters());

  @override
  bool get available => true;

  @override
  Future<String?> account() => _store.read(_accountKey);

  Future<String?> _token({String? email, required bool prompt}) async {
    await _init();
    try {
      final tokens = await _google.clientAuthorizationTokensForScopes(
        ClientAuthorizationTokensForScopesParameters(
          request: AuthorizationRequestDetails(
            scopes: const [driveAppDataScope],
            userId: null,
            email: email,
            promptIfUnauthorized: prompt,
          ),
        ),
      );
      return tokens?.accessToken;
    } on GoogleSignInException catch (error) {
      throw DriveException(switch (error.code) {
        GoogleSignInExceptionCode.canceled => 'Google sign-in was cancelled.',
        _ => 'Google sign-in failed: ${error.description ?? error.code.name}',
      });
    }
  }

  @override
  Future<String> connect() async {
    final token = await _token(prompt: true);
    if (token == null) {
      throw const DriveException('Google sign-in was cancelled.');
    }
    final email = await driveAccountEmail(const HttpDriveTransport(), token);
    await _store.write(_accountKey, email);
    return email;
  }

  @override
  Future<String?> accessToken() async {
    final email = await account();
    if (email == null) return null;
    return _token(email: email, prompt: false);
  }

  @override
  Future<void> disconnect() async {
    await _store.delete(_accountKey);
    try {
      await _init();
      await _google.disconnect(const DisconnectParams());
    } on Object {
      // Forgotten on this device either way; the person can also remove the
      // app at myaccount.google.com/permissions.
    }
  }
}

/// The Mac's browser sign-in.
final class DesktopDriveSignIn implements DriveSignIn {
  const DesktopDriveSignIn(this._google);

  final GoogleDesktopSignIn _google;

  @override
  bool get available => true;

  @override
  Future<String?> account() => _google.account();

  @override
  Future<String> connect() => _google.connect();

  @override
  Future<void> disconnect() => _google.disconnect();

  @override
  Future<String?> accessToken() => _google.accessToken();
}

/// A build without a Google OAuth client: sync says so instead of failing.
final class UnavailableDriveSignIn implements DriveSignIn {
  const UnavailableDriveSignIn();

  @override
  bool get available => false;

  @override
  Future<String?> account() async => null;

  @override
  Future<String> connect() => throw const DriveException(
    'Google sign-in isn’t set up in this build of Budget.',
  );

  @override
  Future<void> disconnect() async {}

  @override
  Future<String?> accessToken() async => null;
}

final class SystemFileSaver implements FileSaver {
  const SystemFileSaver();

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async =>
      await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
      ) !=
      null;
}

final class SystemFileLoader implements FileLoader {
  const SystemFileLoader();

  @override
  Future<Uint8List?> pick({required List<String> extensions}) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    return file?.readAsBytes();
  }
}

final class LocalAuthenticator implements Authenticator {
  LocalAuthenticator() : _auth = LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isSupported() => _auth.isDeviceSupported();

  @override
  Future<bool> authenticate({
    required String reason,
    required bool biometricOnly,
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: biometricOnly,
      );
    } on LocalAuthException {
      // Cancelled, locked out, or nothing enrolled: the person stays locked.
      return false;
    }
  }
}

/// One SQLCipher file per budget in [directory], each under its own store
/// key kept in secure storage.
final class SqlCipherBudgetStorage implements BudgetStorage {
  const SqlCipherBudgetStorage(this._storage, {required this.directory});

  final FlutterSecureStorage _storage;
  final String directory;

  @override
  Future<EventLog> openLog(String budgetId) async {
    final name = 'store-key:$budgetId';
    var keyHex = await _storage.read(key: name);
    if (keyHex == null) {
      keyHex = BudgetKey.generate().toHex();
      await _storage.write(key: name, value: keyHex);
    }
    return SqlCipherEventLog.open(
      '$directory/budget-$budgetId.db',
      keyHex: keyHex,
    );
  }
}
