import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/logging/debug_log.dart';
import '../../domain/storage/pending_remote_session_close_store.dart';

/// Browser backed [PendingRemoteSessionCloseStore].
///
/// On Flutter Web `shared_preferences` writes to `window.localStorage`, so an
/// entry survives an F5, a closed tab and a browser restart — the cases in
/// which a session finalized here could otherwise come back from a
/// `GET /remote-sessions/current` that still lists it.
///
/// What is written, and why it is acceptable in `localStorage`:
///
/// * the remote session UUID and the moment FINALIZAR was pressed. Nothing
///   else: no User JWT, no user id, no device id, no SDP, no ICE. A session id
///   is an operational identifier the backend never accepts as authorization
///   — every route is ownership scoped by the User JWT — so reading it gives
///   an attacker nothing to act with;
/// * entries expire after [maxAge] and at most [maxEntries] are kept. The
///   backend closes a session on its own once a side has been away from it
///   longer than its grace period, so an entry that old has nothing left to
///   protect;
/// * a corrupt or foreign value is ignored, never trusted.
class BrowserPendingRemoteSessionCloseStore
    implements PendingRemoteSessionCloseStore {
  BrowserPendingRemoteSessionCloseStore({
    SharedPreferencesAsync? preferences,
    DateTime Function()? now,
  }) : _preferences = preferences ?? SharedPreferencesAsync(),
       _now = now ?? DateTime.now;

  /// Storage key. Namespaced to avoid clashing with anything else on the origin.
  static const String storageKey =
      'remote_control_web.pending_remote_session_closes';

  static const Duration maxAge = PendingRemoteSessionCloseCodec.maxAge;
  static const int maxEntries = PendingRemoteSessionCloseCodec.maxEntries;

  final SharedPreferencesAsync _preferences;
  final DateTime Function() _now;

  @override
  Future<Set<String>> read() async => PendingRemoteSessionCloseCodec.decode(
    await _readRaw(),
    _now(),
  ).keys.toSet();

  @override
  Future<void> add(String remoteSessionId) async {
    final now = _now();
    final entries = PendingRemoteSessionCloseCodec.decode(await _readRaw(), now)
      ..[remoteSessionId] = now;
    await _write(entries, now);
  }

  @override
  Future<void> remove(String remoteSessionId) async {
    final now = _now();
    final entries = PendingRemoteSessionCloseCodec.decode(
      await _readRaw(),
      now,
    );
    if (entries.remove(remoteSessionId) == null) return;
    await _write(entries, now);
  }

  Future<String?> _readRaw() async {
    try {
      return await _preferences.getString(storageKey);
    } catch (_) {
      logDebug('pending remote session closes could not be read');
      return null;
    }
  }

  Future<void> _write(Map<String, DateTime> entries, DateTime now) async {
    try {
      if (entries.isEmpty) {
        await _preferences.remove(storageKey);
      } else {
        await _preferences.setString(
          storageKey,
          PendingRemoteSessionCloseCodec.encode(entries, now),
        );
      }
    } catch (_) {
      logDebug('pending remote session closes could not be written');
    }
  }
}

/// The stored format, kept apart so it can be tested without a browser:
///
/// ```json
/// [{ "id": "<remote session uuid>", "at": <milliseconds since epoch> }]
/// ```
abstract final class PendingRemoteSessionCloseCodec {
  static const Duration maxAge = Duration(hours: 12);
  static const int maxEntries = 8;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// Valid, unexpired entries, ignoring anything that is not.
  static Map<String, DateTime> decode(String? raw, DateTime now) {
    final entries = <String, DateTime>{};
    if (raw == null || raw.isEmpty) return entries;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return entries;
    }
    if (decoded is! List) return entries;
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = item['id'];
      final at = item['at'];
      if (id is! String || !_uuid.hasMatch(id) || at is! int) continue;
      final when = DateTime.fromMillisecondsSinceEpoch(at, isUtc: true);
      if (_isExpired(when, now)) continue;
      entries[id] = when;
    }
    return entries;
  }

  /// The newest [maxEntries] unexpired entries.
  static String encode(Map<String, DateTime> entries, DateTime now) {
    final kept =
        entries.entries
            .where(
              (entry) =>
                  _uuid.hasMatch(entry.key) && !_isExpired(entry.value, now),
            )
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return jsonEncode([
      for (final entry in kept.take(maxEntries))
        {'id': entry.key, 'at': entry.value.millisecondsSinceEpoch},
    ]);
  }

  static bool _isExpired(DateTime when, DateTime now) =>
      now.difference(when) > maxAge;
}
