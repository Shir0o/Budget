import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'drive.dart';

/// [DriveTransport] over `dart:io`, for Android and macOS.
final class HttpDriveTransport implements DriveTransport {
  const HttpDriveTransport({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;

  @override
  Future<DriveResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Uint8List? body,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      for (final MapEntry(:key, :value) in headers.entries) {
        request.headers.set(key, value);
      }
      if (body != null) request.add(body);
      final response = await request.close().timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      return DriveResponse(
        status: response.statusCode,
        body: bytes.takeBytes(),
      );
    } on TimeoutException {
      throw const DriveException('Google Drive timed out');
    } on SocketException {
      throw const DriveException('Couldn’t reach Google Drive');
    } finally {
      client.close();
    }
  }
}
