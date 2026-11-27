import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'drive.dart';

/// The only scope sync asks Google for: the hidden app data folder
/// (ADR 0002). It can't see any of the person's own Drive files.
const driveAppDataScope = 'https://www.googleapis.com/auth/drive.appdata';

/// Where a sign-in keeps what it must remember between launches: the refresh
/// token and the account's email address. The app backs it with the
/// Keychain or Android Keystore; tests keep it in memory.
abstract interface class SignInStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class InMemorySignInStore implements SignInStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The Google account Drive answers for, read with the app data scope
/// (`about.get` accepts it), so sign-in needs no email or profile scope.
Future<String> driveAccountEmail(DriveTransport transport, String token) async {
  final response = await transport.send(
    method: 'GET',
    uri: Uri.https('www.googleapis.com', '/drive/v3/about', {
      'fields': 'user(emailAddress)',
    }),
    headers: {'authorization': 'Bearer $token'},
  );
  if (response.status != 200) {
    throw DriveException('Google Drive answered ${response.status}');
  }
  final body = jsonDecode(utf8.decode(response.body)) as Map;
  final email = (body['user'] as Map?)?['emailAddress'];
  if (email is! String || email.isEmpty) {
    throw const DriveException('Google didn’t say which account signed in');
  }
  return email;
}

/// Google sign-in for the Mac: OAuth 2.0 for installed apps, with PKCE and a
/// loopback redirect to `127.0.0.1` (Google's desktop flow). The browser
/// shows Google's own page; the app never sees the password.
///
/// It keeps the refresh token in [store] and hands sync a fresh access token
/// when the old one is about to expire.
final class GoogleDesktopSignIn implements DriveAccess {
  GoogleDesktopSignIn({
    required this.clientId,
    required this.clientSecret,
    required this.store,
    required this.transport,
    required this.openBrowser,
    DateTime Function()? now,
    this.timeout = const Duration(minutes: 5),
  }) : _now = now ?? DateTime.now;

  /// A "Desktop app" OAuth client in the app's Google Cloud project, passed
  /// in at build time. Google says a desktop client's secret can't be kept
  /// secret and doesn't treat it as one; PKCE is what protects the code.
  final String clientId;
  final String clientSecret;

  final SignInStore store;
  final DriveTransport transport;

  /// Opens [Uri] in the person's browser.
  final Future<void> Function(Uri uri) openBrowser;

  /// How long to wait for the person to finish in the browser.
  final Duration timeout;

  final DateTime Function() _now;

  static const refreshTokenKey = 'google-refresh-token';
  static const accountKey = 'google-account';

  static final _authorize = Uri.https(
    'accounts.google.com',
    '/o/oauth2/v2/auth',
  );
  static final _token = Uri.https('oauth2.googleapis.com', '/token');
  static final _revoke = Uri.https('oauth2.googleapis.com', '/revoke');

  String? _accessToken;
  DateTime? _expiresAt;

  /// The connected account's email, or null when this device isn't
  /// connected.
  Future<String?> account() => store.read(accountKey);

  /// Opens Google's sign-in page and waits for the browser to come back to
  /// the loopback address. Returns the account's email address.
  Future<String> connect() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}';
      final verifier = _randomString(64);
      final state = _randomString(32);
      // Listen before the browser opens, so a fast answer isn't missed.
      final answer = _awaitCode(server, state);
      await openBrowser(
        _authorize.replace(
          queryParameters: {
            'client_id': clientId,
            'redirect_uri': redirect,
            'response_type': 'code',
            'scope': driveAppDataScope,
            'code_challenge': await _challenge(verifier),
            'code_challenge_method': 'S256',
            'state': state,
            // A refresh token, so sync keeps working after an hour.
            'access_type': 'offline',
            'prompt': 'consent',
          },
        ),
      );
      final code = await answer.timeout(
        timeout,
        onTimeout: () =>
            throw const DriveException('Google sign-in timed out. Try again.'),
      );
      final Map<String, Object?> tokens;
      try {
        tokens = await _post(_token, {
          'client_id': clientId,
          'client_secret': clientSecret,
          'code': code,
          'code_verifier': verifier,
          'grant_type': 'authorization_code',
          'redirect_uri': redirect,
        });
      } on _Refused catch (refused) {
        throw refused.asDriveException;
      }
      final refresh = tokens['refresh_token'];
      if (refresh is! String || refresh.isEmpty) {
        throw const DriveException('Google didn’t keep this device signed in');
      }
      _keep(tokens);
      final email = await driveAccountEmail(transport, _accessToken!);
      await store.write(refreshTokenKey, refresh);
      await store.write(accountKey, email);
      return email;
    } finally {
      await server.close(force: true);
    }
  }

  /// Forgets the sign-in on this device and asks Google to revoke it. The
  /// files in Drive stay where they are.
  Future<void> disconnect() async {
    final refresh = await store.read(refreshTokenKey);
    _accessToken = null;
    _expiresAt = null;
    await store.delete(refreshTokenKey);
    await store.delete(accountKey);
    if (refresh == null) return;
    try {
      await transport.send(
        method: 'POST',
        uri: _revoke,
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: _form({'token': refresh}),
      );
    } on Object {
      // Offline: the device has forgotten it either way, and the person can
      // remove the app at myaccount.google.com/permissions.
    }
  }

  @override
  Future<String?> accessToken() async {
    final token = _accessToken;
    final expiresAt = _expiresAt;
    if (token != null &&
        expiresAt != null &&
        _now().isBefore(expiresAt.subtract(const Duration(minutes: 1)))) {
      return token;
    }
    final refresh = await store.read(refreshTokenKey);
    if (refresh == null) return null;
    final Map<String, Object?> tokens;
    try {
      tokens = await _post(_token, {
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      });
    } on _Refused catch (refused) {
      if (refused.error != 'invalid_grant') throw refused.asDriveException;
      // Revoked or expired: this device has to connect again.
      await store.delete(refreshTokenKey);
      await store.delete(accountKey);
      return null;
    }
    _keep(tokens);
    return _accessToken;
  }

  void _keep(Map<String, Object?> tokens) {
    final token = tokens['access_token'];
    if (token is! String || token.isEmpty) {
      throw const DriveException('Google sign-in didn’t return a token');
    }
    final seconds = tokens['expires_in'];
    _accessToken = token;
    _expiresAt = _now().add(Duration(seconds: seconds is int ? seconds : 3600));
  }

  Future<Map<String, Object?>> _post(
    Uri uri,
    Map<String, String> fields,
  ) async {
    final response = await transport.send(
      method: 'POST',
      uri: uri,
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: _form(fields),
    );
    Map<String, Object?> body;
    try {
      body = (jsonDecode(utf8.decode(response.body)) as Map)
          .cast<String, Object?>();
    } on FormatException {
      body = const {};
    }
    if (response.status != 200) {
      final error = body['error'];
      if (error is String) throw _Refused(error);
      throw DriveException('Google sign-in answered ${response.status}');
    }
    return body;
  }

  /// Answers the browser's requests until one carries [state], then returns
  /// its code. Anything else, like a favicon, gets a 404.
  static Future<String> _awaitCode(HttpServer server, String state) async {
    await for (final request in server) {
      final query = request.uri.queryParameters;
      if (query['state'] != state) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      final code = query['code'];
      final error = query['error'];
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_page(code != null));
      await request.response.close();
      if (code != null) return code;
      throw DriveException(
        error == 'access_denied'
            ? 'Google sign-in was cancelled.'
            : 'Google sign-in failed: ${error ?? 'no code'}',
      );
    }
    throw const DriveException('Google sign-in was cancelled.');
  }

  static String _page(bool ok) =>
      '<!doctype html><meta charset="utf-8"><title>Budget</title>'
      '<body style="font:16px -apple-system,sans-serif;margin:3em">'
      '<p>${ok ? 'Google Drive is connected. You can close this tab and go back to Budget.' : 'Google Drive wasn’t connected. You can close this tab and try again in Budget.'}</p>';

  static Uint8List _form(Map<String, String> fields) => Uint8List.fromList(
    utf8.encode(
      fields.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}='
                '${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&'),
    ),
  );

  static Future<String> _challenge(String verifier) async {
    final hash = await Sha256().hash(utf8.encode(verifier));
    return base64Url.encode(hash.bytes).replaceAll('=', '');
  }

  static const _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static String _randomString(int length) {
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        _unreserved.codeUnitAt(random.nextInt(_unreserved.length)),
    ]);
  }
}

/// Google's token endpoint said no, with an OAuth error code.
final class _Refused implements Exception {
  const _Refused(this.error);

  final String error;

  DriveException get asDriveException =>
      DriveException('Google sign-in was refused: $error');
}
