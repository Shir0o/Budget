import 'package:budget_sync/budget_sync.dart';
import 'package:flutter/material.dart';

import 'services.dart';
import 'theme.dart';
import 'widgets.dart';

/// The Google account this device syncs through, with Connect Google Drive
/// when there is none. Encrypted sync and Join a budget both show it, because
/// neither can reach Drive without it.
///
/// [onChanged] gets the account's email, or null, once it is known and after
/// every connect or disconnect.
class DriveAccountCard extends StatefulWidget {
  const DriveAccountCard({
    super.key,
    required this.services,
    required this.onChanged,
  });

  final AppServices services;
  final ValueChanged<String?> onChanged;

  @override
  State<DriveAccountCard> createState() => _DriveAccountCardState();
}

class _DriveAccountCardState extends State<DriveAccountCard> {
  String? _account;
  String? _problem;
  var _loaded = false;
  var _busy = false;

  DriveSignIn get _signIn => widget.services.driveSignIn;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = await _signIn.account();
    if (!mounted) return;
    setState(() {
      _account = account;
      _loaded = true;
    });
    widget.onChanged(account);
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    String? account;
    String? problem;
    try {
      // The browser or Google's sheet covers the app; don't lock behind it.
      account = await widget.services.keepUnlocked(_signIn.connect);
    } on DriveException catch (error) {
      problem = error.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _account = account;
      _problem = problem;
    });
    widget.onChanged(account);
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await _signIn.disconnect();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _account = null;
      _problem = null;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final problem = _problem;
    return CardBox(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          const Text(
            'Google account',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          if (!_loaded)
            const Hint('Checking…')
          else if (!_signIn.available)
            const Text(
              'Google sign-in isn’t set up in this build of Budget, so it '
              'can’t reach Drive.',
              key: ValueKey('drive-unavailable'),
              style: TextStyle(fontSize: 14, color: Palette.problemText),
            )
          else if (account != null) ...[
            Text(
              account,
              key: const ValueKey('drive-account'),
              style: const TextStyle(fontSize: 14, color: Palette.inkSoft),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('drive-disconnect'),
                onPressed: _busy ? null : _disconnect,
                child: const Text('Use another account'),
              ),
            ),
          ] else ...[
            const Text(
              'Connect the Google account whose Drive holds this budget. '
              'Budget asks only for its own hidden folder, never your files.',
              style: TextStyle(
                fontSize: 14,
                color: Palette.inkSoft,
                height: 1.45,
              ),
            ),
            if (problem != null)
              Text(
                problem,
                key: const ValueKey('drive-problem'),
                style: const TextStyle(
                  fontSize: 13,
                  color: Palette.problemText,
                ),
              ),
            FilledButton(
              key: const ValueKey('connect-drive'),
              onPressed: _busy ? null : _connect,
              child: Text(_busy ? 'Connecting…' : 'Connect Google Drive'),
            ),
          ],
        ],
      ),
    );
  }
}
