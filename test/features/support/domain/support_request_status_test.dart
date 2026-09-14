import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';

import '../../../support/console_test_doubles.dart';

void main() {
  group('parsing', () {
    test('every documented value is recognised', () {
      const wire = [
        'WAITING',
        'ASSIGNED',
        'ACCEPTED',
        'REJECTED',
        'CANCELLED',
        'COMPLETED',
      ];

      for (final value in wire) {
        final status = SupportRequestStatus.fromWire(value);
        expect(status.isKnown, isTrue, reason: value);
        expect(status.wireValue, value);
      }
    });

    test('an unknown future value is preserved and grants nothing', () {
      final status = SupportRequestStatus.fromWire('ESCALATED');

      expect(status.wireValue, 'ESCALATED');
      expect(status.isKnown, isFalse);
      expect(status.isAssignable, isFalse);
      expect(status.isActive, isFalse);
      expect(status.isTerminal, isFalse);
    });

    test('the wire value round-trips as the status query parameter', () {
      expect(
        SupportRequestStatus.fromWire('WAITING'),
        SupportRequestStatus.waiting,
      );
      expect(SupportRequestStatus.waiting.wireValue, 'WAITING');
    });
  });

  group('transitions', () {
    test('only WAITING may be assigned', () {
      for (final status in SupportRequestStatus.known) {
        expect(
          status.isAssignable,
          status == SupportRequestStatus.waiting,
          reason: status.wireValue,
        );
      }
    });

    test('WAITING, ASSIGNED and ACCEPTED are the active states', () {
      expect(SupportRequestStatus.active, [
        SupportRequestStatus.waiting,
        SupportRequestStatus.assigned,
        SupportRequestStatus.accepted,
      ]);
      expect(SupportRequestStatus.accepted.isTerminal, isFalse);
    });

    test('REJECTED, CANCELLED and COMPLETED are terminal', () {
      expect(SupportRequestStatus.rejected.isTerminal, isTrue);
      expect(SupportRequestStatus.cancelled.isTerminal, isTrue);
      expect(SupportRequestStatus.completed.isTerminal, isTrue);
    });
  });

  group('wording', () {
    test('each state explains what the technician is waiting for', () {
      expect(SupportRequestStatus.waiting.description, 'Esperando técnico');
      expect(
        SupportRequestStatus.assigned.description,
        'Esperando autorización del usuario',
      );
      expect(
        SupportRequestStatus.accepted.description,
        'Usuario autorizó la asistencia',
      );
      expect(
        SupportRequestStatus.rejected.description,
        'Usuario rechazó la asistencia',
      );
      expect(
        SupportRequestStatus.cancelled.description,
        'Solicitud cancelada',
      );
      expect(
        SupportRequestStatus.completed.description,
        'Asistencia finalizada',
      );
    });
  });

  group('SupportRequest', () {
    test('ACCEPTED does not imply a remote session exists', () {
      final request = buildSupportRequest(
        status: SupportRequestStatus.accepted,
        technician: technicianId,
      );

      expect(request.isActive, isTrue);
      expect(request.isTerminal, isFalse);
      expect(request.isAssignedTo(technicianId), isTrue);
    });

    test('an offline device hides the action but not the request', () {
      final request = buildSupportRequest(isDeviceOnline: false);

      expect(request.isWaiting, isTrue);
      expect(request.isDeviceOnline, isFalse);
      expect(request.looksAssignable, isFalse);
    });

    test('isAssignedTo is false for another technician', () {
      final request = buildSupportRequest(
        status: SupportRequestStatus.assigned,
        technician: 'somebody-else',
      );

      expect(request.isAssignedTo(technicianId), isFalse);
    });

    test('a request with no technician belongs to nobody', () {
      expect(buildSupportRequest().isAssignedTo(technicianId), isFalse);
      expect(buildSupportRequest().isAssignedTo(''), isFalse);
    });

    test('the device name falls back to the readable id', () {
      final request = buildSupportRequest(
        device: buildSupportDevice(name: null),
      );

      expect(request.deviceLabel, '132-491-092');
    });
  });
}
