/// Everything in `budget_sync` that runs without `dart:io`, such as in a
/// JavaScript build for the cloud MCP server: the Drive calls take any
/// [DriveTransport], and `HttpDriveTransport` stays in `budget_sync.dart`.
library;

export 'src/drive.dart';
export 'src/envelope.dart';
export 'src/in_memory_drive.dart';
export 'src/merge.dart';
export 'src/pairing.dart';
export 'src/recovery_phrase.dart';
export 'src/segment.dart';
export 'src/sync_book.dart';
export 'src/sync_client.dart';
