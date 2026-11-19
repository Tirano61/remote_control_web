import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_session/data/storage/browser_pending_remote_session_close_store.dart';

void main() {
  const id = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
  const other = '5a6b7c8d-1111-4222-8333-944455556666';
  final now = DateTime.utc(2026, 11, 19, 10);

  group('PendingRemoteSessionCloseCodec', () {
    test('round-trips ids and the moment FINALIZAR was pressed', () {
      final raw = PendingRemoteSessionCloseCodec.encode({id: now}, now);

      expect(PendingRemoteSessionCloseCodec.decode(raw, now), {id: now});
    });

    test('stores the session id and a timestamp, nothing else', () {
      final raw = PendingRemoteSessionCloseCodec.encode({id: now}, now);
      final decoded = jsonDecode(raw) as List;

      expect(decoded, hasLength(1));
      expect((decoded.single as Map).keys.toSet(), {'id', 'at'});
    });

    test('expired entries are forgotten', () {
      final old = now.subtract(
        PendingRemoteSessionCloseCodec.maxAge + const Duration(minutes: 1),
      );
      final raw = PendingRemoteSessionCloseCodec.encode({
        id: old,
        other: now,
      }, old);

      expect(PendingRemoteSessionCloseCodec.decode(raw, now).keys, [other]);
    });

    test('only the newest entries are kept', () {
      final entries = <String, DateTime>{
        for (var i = 0; i < 12; i++)
          '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}': now
              .subtract(Duration(minutes: i)),
      };

      final kept = PendingRemoteSessionCloseCodec.decode(
        PendingRemoteSessionCloseCodec.encode(entries, now),
        now,
      );

      expect(kept, hasLength(PendingRemoteSessionCloseCodec.maxEntries));
      expect(kept.keys, contains('00000000-0000-4000-8000-000000000000'));
      expect(
        kept.keys,
        isNot(contains('00000000-0000-4000-8000-000000000011')),
      );
    });

    test('anything that is not a list of {uuid, int} is ignored', () {
      for (final raw in [
        null,
        '',
        'not json',
        '{"id":"$id"}',
        '[1, "x", null]',
        '[{"id":"not-a-uuid","at":1}]',
        '[{"id":"$id","at":"yesterday"}]',
        '[{"id":"$id"}]',
      ]) {
        expect(PendingRemoteSessionCloseCodec.decode(raw, now), isEmpty);
      }
    });

    test('a valid entry survives junk next to it', () {
      final raw = jsonEncode([
        {'id': 'eyJhbGciOi.token.like', 'at': now.millisecondsSinceEpoch},
        {'id': id, 'at': now.millisecondsSinceEpoch},
      ]);

      expect(PendingRemoteSessionCloseCodec.decode(raw, now).keys, [id]);
    });
  });
}
