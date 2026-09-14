import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/features/technician_realtime/data/realtime_contract.dart';
import 'package:remote_control_web/features/technician_realtime/data/technician_realtime_client_impl.dart';

import '../../support/console_test_doubles.dart';
import '../../support/realtime_test_doubles.dart';

const String secretToken = 'eyJhbGciOiJIUzI1NiJ9.SUPER-SECRET-JWT.signature';

void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';

  test('a full realtime lifecycle never prints the User JWT', () async {
    final factory = RecordingGatewayFactory();
    final client = TechnicianRealtimeClientImpl(
      config: const AppConfig(backendBaseUrl: 'http://localhost:3000'),
      tokenProvider: InMemoryUserTokenProvider(secretToken),
      gatewayFactory: factory.call,
    );

    final printed = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };

    await runZoned(
      () async {
        await client.connect();
        final gateway = factory.last;
        // The handshake really does carry the token...
        expect(await gateway.currentAuth(), {'token': secretToken});

        gateway.completeHandshake();
        final pending = client.joinRemoteSession(sessionId);
        gateway.answerAck({'joined': true, 'remoteSessionId': sessionId});
        await pending;
        gateway.emitServerEvent(
          TechnicianRealtimeContract.remoteSessionClosedEvent,
          {'remoteSessionId': sessionId, 'endedBy': 'DEVICE'},
        );
        gateway.dropConnection();
        gateway.reportConnectError({'message': 'Unauthorized'});
        await client.disconnect();
        await client.dispose();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    debugPrint = originalDebugPrint;

    final output = printed.join('\n');
    // ...and it never shows up anywhere else.
    expect(output, isNot(contains(secretToken)));
    expect(output, isNot(contains('Authorization')));
    expect(output, isNot(contains('token')));

    // What may be logged: operational facts and safe identifiers.
    expect(output, contains('socket connected'));
    expect(output, contains('socket disconnected'));
    expect(output, contains('join requested $sessionId'));
    expect(output, contains('join accepted $sessionId'));
    expect(output, contains('remote-session:closed received $sessionId'));
  });
}
