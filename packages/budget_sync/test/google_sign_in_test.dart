import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_sync/budget_sync.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

/// Answers Google's token, about and revoke endpoints with made-up values.
final class _FakeGoogle implements DriveTransport {
  final requests = <({Uri uri, Map<String, String> form})>[];
  var refreshAnswer = 200;
  var refreshError = 'invalid_grant';
  var issued = 0;

  @override
  Future<DriveResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Uint8List? body,
  }) async {
    final form = body == null
        ? <String, String>{}
        : Uri.splitQueryString(utf8.decode(body));
    requests.add((uri: uri, form: form));
    if (uri.path == '/token') {
      if (form['grant_type'] == 'refresh_token' && refreshAnswer != 200) {
        return _json(refreshAnswer, {'error': refreshError});
      }
      issued++;
      return _json(200, {
        'access_token': 'access-$issued',
        'expires_in': 3600,
        if (form['grant_type'] == 'authorization_code')
          'refresh_token': 'refresh-1',
      });
    }
    if (uri.path == '/drive/v3/about') {
      expect(headers['authorization'], startsWith('Bearer access-'));
      return _json(200, {
        'user': {'emailAddress': 'sam@example.com'},
      });
    }
    if (uri.path == '/revoke') return _json(200, {});
    return _json(404, {});
  }

  static DriveResponse _json(int status, Object body) => DriveResponse(
    status: status,
    body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  );
}

/// Plays the browser: follows the sign-in page straight back to the app's
/// loopback address, as Google does after the person agrees.
Future<void> Function(Uri) _browser({
  Map<String, String> answer = const {'code': 'code-1'},
  List<Uri>? opened,
  bool favicon = false,
}) => (uri) async {
  opened?.add(uri);
  final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
  final client = HttpClient();
  try {
    if (favicon) {
      final stray = await client.getUrl(redirect.replace(path: '/favicon.ico'));
      final response = await stray.close();
      expect(response.statusCode, 404);
      await response.drain<void>();
    }
    final request = await client.getUrl(
      redirect.replace(
        queryParameters: {...answer, 'state': uri.queryParameters['state']!},
      ),
    );
    await (await request.close()).drain<void>();
  } finally {
    client.close();
  }
};

void main() {
  late _FakeGoogle google;
  late InMemorySignInStore store;
  var now = DateTime.utc(2026, 11, 27, 9);

  GoogleDesktopSignIn signIn(Future<void> Function(Uri) browser) =>
      GoogleDesktopSignIn(
        clientId: 'desktop-client',
        clientSecret: 'desktop-secret',
        store: store,
        transport: google,
        openBrowser: browser,
        now: () => now,
      );

  setUp(() {
    google = _FakeGoogle();
    store = InMemorySignInStore();
    now = DateTime.utc(2026, 11, 27, 9);
  });

  test('connect asks only for the app folder and keeps the account', () async {
    final opened = <Uri>[];
    final auth = signIn(_browser(opened: opened, favicon: true));

    expect(await auth.account(), isNull);
    expect(await auth.accessToken(), isNull);
    expect(await auth.connect(), 'sam@example.com');

    final page = opened.single;
    expect(page.host, 'accounts.google.com');
    expect(page.queryParameters['scope'], driveAppDataScope);
    expect(
      page.queryParameters['redirect_uri'],
      startsWith('http://127.0.0.1:'),
    );
    expect(page.queryParameters['code_challenge_method'], 'S256');

    // The code is exchanged with the verifier whose hash the page carried.
    final exchange = google.requests.firstWhere(
      (r) => r.form['grant_type'] == 'authorization_code',
    );
    expect(exchange.form['code'], 'code-1');
    final hash = await Sha256().hash(
      utf8.encode(exchange.form['code_verifier']!),
    );
    expect(
      base64Url.encode(hash.bytes).replaceAll('=', ''),
      page.queryParameters['code_challenge'],
    );

    expect(await auth.account(), 'sam@example.com');
    expect(store.values[GoogleDesktopSignIn.refreshTokenKey], 'refresh-1');
    expect(await auth.accessToken(), 'access-1');
  });

  test('refreshes the token only when it is about to expire', () async {
    final auth = signIn(_browser());
    await auth.connect();

    now = now.add(const Duration(minutes: 50));
    expect(await auth.accessToken(), 'access-1');
    now = now.add(const Duration(minutes: 9, seconds: 30));
    expect(await auth.accessToken(), 'access-2');
    expect(
      google.requests.last.form,
      containsPair('refresh_token', 'refresh-1'),
    );

    // A new launch has no token in memory and refreshes straight away.
    expect(await signIn(_browser()).accessToken(), 'access-3');
  });

  test('a revoked sign-in leaves the device disconnected', () async {
    await signIn(_browser()).connect();
    google.refreshAnswer = 400;

    expect(await signIn(_browser()).accessToken(), isNull);
    expect(store.values, isEmpty);
  });

  test('another refusal is an error and keeps the sign-in', () async {
    await signIn(_browser()).connect();
    google
      ..refreshAnswer = 401
      ..refreshError = 'invalid_client';

    await expectLater(
      signIn(_browser()).accessToken(),
      throwsA(isA<DriveException>()),
    );
    expect(store.values, isNotEmpty);
  });

  test('cancelling in the browser keeps nothing', () async {
    final auth = signIn(_browser(answer: const {'error': 'access_denied'}));

    await expectLater(
      auth.connect(),
      throwsA(
        isA<DriveException>().having(
          (e) => e.message,
          'message',
          'Google sign-in was cancelled.',
        ),
      ),
    );
    expect(store.values, isEmpty);
  });

  test('gives up when the browser never comes back', () async {
    final auth = GoogleDesktopSignIn(
      clientId: 'desktop-client',
      clientSecret: 'desktop-secret',
      store: store,
      transport: google,
      openBrowser: (_) async {},
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(auth.connect(), throwsA(isA<DriveException>()));
    expect(store.values, isEmpty);
  });

  test('disconnect forgets the account and revokes it', () async {
    final auth = signIn(_browser());
    await auth.connect();

    await auth.disconnect();

    expect(store.values, isEmpty);
    expect(await auth.accessToken(), isNull);
    final revoke = google.requests.last;
    expect(revoke.uri.path, '/revoke');
    expect(revoke.form['token'], 'refresh-1');
  });
}
