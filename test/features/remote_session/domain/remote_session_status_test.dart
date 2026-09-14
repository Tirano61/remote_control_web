import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_session/data/models/remote_session_dto.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';

void main() {
  group('RemoteSessionStatus', () {
    test('parses the documented values', () {
      expect(
        RemoteSessionStatus.fromWire('CONNECTING'),
        RemoteSessionStatus.connecting,
      );
      expect(
        RemoteSessionStatus.fromWire('ACTIVE'),
        RemoteSessionStatus.active,
      );
      expect(
        RemoteSessionStatus.fromWire('CLOSED'),
        RemoteSessionStatus.closed,
      );
      expect(
        RemoteSessionStatus.known.map((status) => status.wireValue),
        ['CONNECTING', 'ACTIVE', 'CLOSED'],
      );
    });

    test('CONNECTING and ACTIVE are the live ones', () {
      expect(RemoteSessionStatus.connecting.isLive, isTrue);
      expect(RemoteSessionStatus.active.isLive, isTrue);
      expect(RemoteSessionStatus.closed.isLive, isFalse);
    });

    test('an unknown future value is preserved and never live', () {
      final status = RemoteSessionStatus.fromWire('SUSPENDED');

      expect(status.wireValue, 'SUSPENDED');
      expect(status.isKnown, isFalse);
      expect(status.isUnknown, isTrue);
      // This is the rule that keeps the console safe: nothing it does not
      // understand keeps an assistance view alive.
      expect(status.isLive, isFalse);
    });

    test('descriptions are the ones shown to the technician', () {
      expect(
        RemoteSessionStatus.connecting.description,
        'Conectando con el dispositivo...',
      );
      expect(RemoteSessionStatus.active.description, 'Asistencia en curso');
    });
  });

  group('RemoteSessionEndedBy', () {
    test('parses the documented values, SYSTEM included', () {
      expect(
        RemoteSessionEndedBy.fromWire('TECHNICIAN'),
        RemoteSessionEndedBy.technician,
      );
      expect(
        RemoteSessionEndedBy.fromWire('DEVICE'),
        RemoteSessionEndedBy.device,
      );
      expect(
        RemoteSessionEndedBy.fromWire('SYSTEM'),
        RemoteSessionEndedBy.system,
      );
    });

    test('an unknown value does not crash the client', () {
      final endedBy = RemoteSessionEndedBy.fromWire('OPERATOR');

      expect(endedBy.wireValue, 'OPERATOR');
      expect(endedBy.isKnown, isFalse);
    });
  });

  group('RemoteSessionDto', () {
    test('an unknown status arrives without crashing and is not live', () {
      final session = RemoteSessionDto.fromJson(const {
        'id': 'a',
        'supportRequestId': 'b',
        'status': 'PAUSED',
        'createdAt': '2026-03-11T09:33:41.000Z',
      });

      expect(session.status.wireValue, 'PAUSED');
      expect(session.isLive, isFalse);
      expect(session.device, isNull);
      expect(session.technician, isNull);
    });

    test('the device label falls back to the readable id', () {
      final session = RemoteSessionDto.fromJson(const {
        'id': 'a',
        'supportRequestId': 'b',
        'status': 'CONNECTING',
        'createdAt': '2026-03-11T09:33:41.000Z',
        'device': {
          'id': 'd',
          'publicId': '132-491-092',
          'name': null,
          'isOnline': true,
        },
      });

      expect(session.deviceLabel, '132-491-092');
      expect(session.devicePublicId, '132-491-092');
    });

    test('the envelope key is the documented one', () {
      expect(RemoteSessionDto.currentEnvelopeKey, 'remoteSession');
    });
  });
}
