import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/data/remote_control_channel_codec.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';

/// The touch session messages, as `remote_control_device` reads them
/// (`docs/CONTROL_CHANNEL.md`, Touch sessions).
void main() {
  Map<String, dynamic> decode(RemoteControlCommand command) =>
      jsonDecode(RemoteControlChannelCodec.encode(command))
          as Map<String, dynamic>;

  test('touch_hold: no seq, the touch and where it went down', () {
    expect(
      RemoteControlChannelCodec.encode(
        const RemoteTouchHoldCommand(
          id: 'hold-7',
          touch: 't-7',
          point: NormalizedRemotePoint(0.41, 0.52),
        ),
      ),
      '{"v":1,"type":"touch_hold","id":"hold-7","touch":"t-7","x":0.41,"y":0.52}',
    );
  });

  test('touch_move: the touch, its seq and where the finger goes', () {
    expect(
      RemoteControlChannelCodec.encode(
        const RemoteTouchMoveCommand(
          id: 'mv-12',
          touch: 't-7',
          seq: 12,
          point: NormalizedRemotePoint(0.43, 0.55),
        ),
      ),
      '{"v":1,"type":"touch_move","id":"mv-12","touch":"t-7","seq":12,'
      '"x":0.43,"y":0.55}',
    );
  });

  test('touch_release: the touch, its seq and where it is lifted', () {
    expect(
      RemoteControlChannelCodec.encode(
        const RemoteTouchReleaseCommand(
          id: 'rel-40',
          touch: 't-7',
          seq: 40,
          point: NormalizedRemotePoint(0.6, 0.7),
        ),
      ),
      '{"v":1,"type":"touch_release","id":"rel-40","touch":"t-7","seq":40,'
      '"x":0.6,"y":0.7}',
    );
  });

  test('touch_cancel: the touch and its seq, and no coordinates', () {
    final frame = decode(
      const RemoteTouchCancelCommand(id: 'cxl-41', touch: 't-7', seq: 41),
    );

    expect(frame, {
      'v': 1,
      'type': 'touch_cancel',
      'id': 'cxl-41',
      'touch': 't-7',
      'seq': 41,
    });
  });

  test('the seq is an integer on the wire', () {
    final frame = decode(
      const RemoteTouchMoveCommand(
        id: 'mv-1',
        touch: 't-1',
        seq: 1,
        point: NormalizedRemotePoint(0, 1),
      ),
    );

    expect(frame['seq'], isA<int>());
    expect(frame['x'], 0);
    expect(frame['y'], 1);
  });

  test('nothing else goes on the wire', () {
    for (final command in const <RemoteControlCommand>[
      RemoteTouchHoldCommand(
        id: 'hold-1',
        touch: 't-1',
        point: NormalizedRemotePoint(0.5, 0.5),
      ),
      RemoteTouchMoveCommand(
        id: 'mv-2',
        touch: 't-1',
        seq: 1,
        point: NormalizedRemotePoint(0.5, 0.5),
      ),
      RemoteTouchReleaseCommand(
        id: 'rel-3',
        touch: 't-1',
        seq: 2,
        point: NormalizedRemotePoint(0.5, 0.5),
      ),
      RemoteTouchCancelCommand(id: 'cxl-4', touch: 't-1', seq: 3),
    ]) {
      final frame = decode(command);
      for (final key in const [
        'durationMs',
        'startX',
        'endX',
        'pointer',
        'button',
        'text',
        'frame',
      ]) {
        expect(frame.containsKey(key), isFalse, reason: '$command $key');
      }
    }
  });

  test('what gets printed is the ids, never a coordinate', () {
    const move = RemoteTouchMoveCommand(
      id: 'mv-2',
      touch: 't-1',
      seq: 1,
      point: NormalizedRemotePoint(0.123456, 0.654321),
    );
    expect(move.toString(), 'RemoteTouchMoveCommand(mv-2, t-1, seq 1)');
    expect(move.toString(), isNot(contains('0.12')));
  });

  group('acks', () {
    test('touch_ended is a known error', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"mv-7-12","ok":false,"error":"touch_ended"}',
        ),
        const RemoteControlAck(
          commandId: 'mv-7-12',
          error: RemoteControlError.touchEnded,
        ),
      );
    });

    test('a hold confirmed', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"hold-7","ok":true}',
        ),
        const RemoteControlAck(commandId: 'hold-7'),
      );
    });

    test('a hold an older tablet does not know', () {
      expect(
        RemoteControlChannelCodec.decodeAck(
          '{"v":1,"type":"ack","id":"hold-7","ok":false,'
          '"error":"unsupported_command"}',
        ),
        const RemoteControlAck(
          commandId: 'hold-7',
          error: RemoteControlError.unsupportedCommand,
        ),
      );
    });
  });

  group('kinds', () {
    test('ids and log names', () {
      expect(RemoteCommandKind.touchHold.idPrefix, 'hold');
      expect(RemoteCommandKind.touchMove.idPrefix, 'mv');
      expect(RemoteCommandKind.touchRelease.idPrefix, 'rel');
      expect(RemoteCommandKind.touchCancel.idPrefix, 'cxl');
      expect(RemoteCommandKind.touchHold.logName, 'touch_hold');
      expect(RemoteCommandKind.touchMove.logName, 'touch_move');
      expect(RemoteCommandKind.touchRelease.logName, 'touch_release');
      expect(RemoteCommandKind.touchCancel.logName, 'touch_cancel');
    });

    test('only the release settles the screen', () {
      expect(RemoteCommandKind.touchHold.settlesScreen, isFalse);
      expect(RemoteCommandKind.touchMove.settlesScreen, isFalse);
      expect(RemoteCommandKind.touchRelease.settlesScreen, isTrue);
      expect(RemoteCommandKind.touchCancel.settlesScreen, isFalse);
    });

    test('long_press is still there', () {
      expect(
        RemoteControlChannelCodec.encode(
          const RemoteLongPressCommand(
            id: 'long-1',
            point: NormalizedRemotePoint(0.5, 0.25),
          ),
        ),
        '{"v":1,"type":"long_press","id":"long-1","x":0.5,"y":0.25}',
      );
    });
  });
}
