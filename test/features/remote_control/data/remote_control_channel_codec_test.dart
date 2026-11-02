import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/data/remote_control_channel_codec.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';

/// The protocol agreed with `remote_control_device`, byte for byte where it
/// matters.
void main() {
  group('tap', () {
    test('produces exactly the fields of the protocol', () {
      expect(
        RemoteControlChannelCodec.encode(
          const RemoteTapCommand(
            id: 'tap-1',
            point: NormalizedRemotePoint(0.5, 0.25),
          ),
        ),
        '{"v":1,"type":"tap","id":"tap-1","x":0.5,"y":0.25}',
      );
    });
  });

  group('back', () {
    test('produces exactly the fields of the protocol', () {
      expect(
        RemoteControlChannelCodec.encode(const RemoteBackCommand(id: 'back-1')),
        '{"v":1,"type":"back","id":"back-1"}',
      );
    });

    test('its ack is read like any other', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"back-1","ok":true}',
        ),
        const RemoteControlAck(commandId: 'back-1'),
      );
    });
  });

  group('home', () {
    test('produces exactly the fields of the protocol', () {
      expect(
        RemoteControlChannelCodec.encode(const RemoteHomeCommand(id: 'home-1')),
        '{"v":1,"type":"home","id":"home-1"}',
      );
    });

    test('its ack is read like any other', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"home-1","ok":false,'
          '"error":"gesture_rejected"}',
        ),
        const RemoteControlAck(
          commandId: 'home-1',
          error: RemoteControlError.gestureRejected,
        ),
      );
    });
  });

  group('swipe', () {
    test('produces exactly the fields of the protocol', () {
      expect(
        RemoteControlChannelCodec.encode(
          RemoteSwipeCommand(
            id: 'swipe-1',
            start: const NormalizedRemotePoint(0.5, 0.8),
            end: const NormalizedRemotePoint(0.5, 0.2),
            durationMs: 350,
          ),
        ),
        '{"v":1,"type":"swipe","id":"swipe-1","startX":0.5,"startY":0.8,'
        '"endX":0.5,"endY":0.2,"durationMs":350}',
      );
    });

    test('the duration is an integer: the tablet refuses 350.0', () {
      final frame =
          jsonDecode(
                RemoteControlChannelCodec.encode(
                  RemoteSwipeCommand(
                    id: 'swipe-1',
                    start: const NormalizedRemotePoint(0, 0),
                    end: const NormalizedRemotePoint(1, 1),
                    durationMs: RemoteSwipeCommand.maxDurationMs,
                  ),
                ),
              )
              as Map<String, dynamic>;

      expect(frame['durationMs'], isA<int>());
      expect(frame['durationMs'], 2000);
    });

    test('its ack is read like any other', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"swipe-1","ok":false,'
          '"error":"gesture_rejected"}',
        ),
        const RemoteControlAck(
          commandId: 'swipe-1',
          error: RemoteControlError.gestureRejected,
        ),
      );
    });
  });

  group('a valid ack', () {
    test('ok: true is a success', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"tap-123","ok":true}',
        ),
        const RemoteControlAck(commandId: 'tap-123'),
      );
    });

    test('ok: true has no error, whatever else came along', () {
      final ack = RemoteControlChannelCodec.decodeAck(
        '{"v":1,"type":"ack","id":"tap-1","ok":true,"error":"gesture_rejected"}',
      );

      expect(ack!.isOk, isTrue);
      expect(ack.error, isNull);
    });

    const errors = {
      'accessibility_unavailable': RemoteControlError.accessibilityUnavailable,
      'session_not_active': RemoteControlError.sessionNotActive,
      'gesture_rejected': RemoteControlError.gestureRejected,
      'invalid_command': RemoteControlError.invalidCommand,
      'unsupported_command': RemoteControlError.unsupportedCommand,
    };

    errors.forEach((code, error) {
      test('ok: false with $code maps to its error', () {
        final ack = RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"tap-1","ok":false,"error":"$code"}',
        );

        expect(ack, RemoteControlAck(commandId: 'tap-1', error: error));
        expect(ack!.isOk, isFalse);
        expect(error.code, code);
      });
    });

    test('a code this version does not know is still a refusal', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"tap-1","ok":false,"error":"from_the_future"}',
        ),
        const RemoteControlAck(
          commandId: 'tap-1',
          error: RemoteControlError.unknown,
        ),
      );
    });
  });

  group('anything else is ignored, never thrown', () {
    const frames = {
      'broken JSON': '{"v":1,',
      'an empty frame': '',
      'not an object': '[1,2,3]',
      'a bare number': '1',
      'null': 'null',
      'no version': '{"type":"ack","id":"tap-1","ok":true}',
      'another version': '{"v":2,"type":"ack","id":"tap-1","ok":true}',
      'a version that is not a number':
          '{"v":"1","type":"ack","id":"tap-1","ok":true}',
      'no type': '{"v":1,"id":"tap-1","ok":true}',
      'another type': '{"v":1,"type":"tap","id":"tap-1","ok":true}',
      'no id': '{"v":1,"type":"ack","ok":true}',
      'an empty id': '{"v":1,"type":"ack","id":"","ok":true}',
      'an id that is not a string': '{"v":1,"type":"ack","id":7,"ok":true}',
      'no ok': '{"v":1,"type":"ack","id":"tap-1"}',
      'an ok that is not a bool':
          '{"v":1,"type":"ack","id":"tap-1","ok":"yes"}',
      'a refusal with no error': '{"v":1,"type":"ack","id":"tap-1","ok":false}',
      'a refusal whose error is not a string':
          '{"v":1,"type":"ack","id":"tap-1","ok":false,"error":3}',
    };

    frames.forEach((description, frame) {
      test(description, () {
        expect(RemoteControlChannelCodec.decodeAck(frame), isNull);
      });
    });
  });
}
