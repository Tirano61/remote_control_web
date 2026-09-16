import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/remote_session/data/datasources/remote_sessions_remote_data_source.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';

import '../../../support/recording_api.dart';

/// Response bodies copied verbatim from
/// `docs/backend/ENDPOINTS.md` -> "Remote sessions — Web".
const String sessionResponseBody = '''
{
  "id": "3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10",
  "supportRequestId": "8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77",
  "status": "CONNECTING",
  "createdAt": "2026-03-11T09:33:41.000Z",
  "connectedAt": null,
  "endedAt": null,
  "endedBy": null,
  "device": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "publicId": "384-729-142",
    "name": "Tablet Tolva 01",
    "isOnline": true
  },
  "technician": {
    "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "name": "Ana Torres"
  }
}
''';

const String currentWithSessionBody = '''
{
  "remoteSession": {
    "id": "3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10",
    "supportRequestId": "8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77",
    "status": "CONNECTING",
    "createdAt": "2026-03-11T09:33:41.000Z",
    "connectedAt": null,
    "endedAt": null,
    "endedBy": null,
    "device": {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "publicId": "384-729-142",
      "name": "Tablet Tolva 01",
      "isOnline": true
    },
    "technician": {
      "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
      "name": "Ana Torres"
    }
  }
}
''';

const String currentWithoutSessionBody = '{ "remoteSession": null }';

/// `POST /remote-sessions/:id/activate` — the same session object, moved to
/// `ACTIVE` with the `connectedAt` the backend stamped.
const String activatedResponseBody = '''
{
  "id": "3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10",
  "supportRequestId": "8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77",
  "status": "ACTIVE",
  "createdAt": "2026-03-11T09:33:41.000Z",
  "connectedAt": "2026-03-11T09:35:12.000Z",
  "endedAt": null,
  "endedBy": null,
  "device": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "publicId": "384-729-142",
    "name": "Tablet Tolva 01",
    "isOnline": true
  },
  "technician": {
    "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "name": "Ana Torres"
  }
}
''';

const String closedResponseBody = '''
{
  "id": "3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10",
  "supportRequestId": "8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77",
  "status": "CLOSED",
  "createdAt": "2026-03-11T09:33:41.000Z",
  "connectedAt": null,
  "endedAt": "2026-03-11T09:51:02.000Z",
  "endedBy": "TECHNICIAN",
  "device": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "publicId": "384-729-142",
    "name": "Tablet Tolva 01",
    "isOnline": true
  },
  "technician": {
    "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "name": "Ana Torres"
  }
}
''';

({RemoteSessionsRemoteDataSource dataSource, RecordingAdapter adapter})
buildDataSource({
  String baseUrl = 'http://localhost:3000',
  int statusCode = 200,
  String body = '{}',
}) {
  final (:client, :adapter) = buildRecordingClient(
    baseUrl: baseUrl,
    statusCode: statusCode,
    body: body,
  );
  return (
    dataSource: RemoteSessionsRemoteDataSourceImpl(apiClient: client),
    adapter: adapter,
  );
}

const String supportRequestId = '8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77';
const String sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';

void main() {
  group('POST /remote-sessions', () {
    test('uses POST on /remote-sessions with a Bearer User JWT', () async {
      final (:dataSource, :adapter) = buildDataSource(
        statusCode: 201,
        body: sessionResponseBody,
      );

      await dataSource.create(
        supportRequestId: supportRequestId,
        token: 'user-jwt',
      );

      final request = adapter.captured!;
      expect(request.method, 'POST');
      expect(request.uri.path, '/remote-sessions');
      expect(request.uri.toString(), 'http://localhost:3000/remote-sessions');
      expect(request.headers['Authorization'], 'Bearer user-jwt');
    });

    test('sends supportRequestId and nothing else', () async {
      final (:dataSource, :adapter) = buildDataSource(
        statusCode: 201,
        body: sessionResponseBody,
      );

      await dataSource.create(
        supportRequestId: supportRequestId,
        token: 'user-jwt',
      );

      // The contract is explicit: this is the only accepted field, and an extra
      // one is a 400 rather than an ignored property.
      expect(capturedJsonBody(adapter), {'supportRequestId': supportRequestId});
      final wire = adapter.capturedBody ?? '';
      expect(wire, contains('supportRequestId'));
      expect(wire, isNot(contains('technicianId')));
      expect(wire, isNot(contains('deviceId')));
      expect(wire, isNot(contains('userId')));
    });

    test('the technician is never identified by the client', () async {
      final (:dataSource, :adapter) = buildDataSource(
        statusCode: 201,
        body: sessionResponseBody,
      );

      await dataSource.create(
        supportRequestId: supportRequestId,
        token: 'user-jwt',
      );

      final captured = adapter.captured!;
      final wire =
          '${captured.uri}${captured.headers}${adapter.capturedBody}';
      expect(wire, isNot(contains('technicianId')));
      expect(wire, isNot(contains('userId')));
      // Identity travels only in the Bearer token.
      expect(captured.headers['Authorization'], 'Bearer user-jwt');
    });

    test('accepts the documented 201 response shape', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 201,
        body: sessionResponseBody,
      );

      final session = await dataSource.create(
        supportRequestId: supportRequestId,
        token: 'jwt',
      );

      expect(session.id, sessionId);
      expect(session.supportRequestId, supportRequestId);
      expect(session.status, RemoteSessionStatus.connecting);
      expect(session.createdAt, DateTime.parse('2026-03-11T09:33:41.000Z'));
      expect(session.connectedAt, isNull);
      expect(session.endedAt, isNull);
      expect(session.endedBy, isNull);
      expect(session.device!.publicId, '384-729-142');
      expect(session.device!.name, 'Tablet Tolva 01');
      expect(session.device!.isOnline, isTrue);
      expect(session.technician!.id, '7c9e6679-7425-40de-944b-e07fc1f90ae7');
      expect(session.technician!.name, 'Ana Torres');
      expect(session.isLive, isTrue);
    });

    test('surfaces 400, 401, 403, 404 and 409 as status codes', () async {
      for (final statusCode in [400, 401, 403, 404, 409]) {
        final (:dataSource, adapter: _) = buildDataSource(
          statusCode: statusCode,
          body: '{"message":"nope"}',
        );

        await expectLater(
          () => dataSource.create(supportRequestId: 'x', token: 'jwt'),
          throwsA(
            isA<HttpApiException>().having(
              (e) => e.statusCode,
              'status',
              statusCode,
            ),
          ),
        );
      }
    });
  });

  group('GET /remote-sessions/current', () {
    test('uses GET on /remote-sessions/current with no body or query', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: currentWithoutSessionBody,
      );

      await dataSource.fetchCurrent(token: 'user-jwt');

      final captured = adapter.captured!;
      expect(captured.method, 'GET');
      expect(captured.uri.path, '/remote-sessions/current');
      expect(
        captured.uri.toString(),
        'http://localhost:3000/remote-sessions/current',
      );
      expect(captured.uri.queryParameters, isEmpty);
      expect(captured.data, isNull);
      expect(captured.headers['Authorization'], 'Bearer user-jwt');
    });

    test('never sends a technicianId or userId', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: currentWithoutSessionBody,
      );

      await dataSource.fetchCurrent(token: 'jwt');

      final wire = '${adapter.captured!.uri}${adapter.capturedBody}';
      expect(wire, isNot(contains('technicianId')));
      expect(wire, isNot(contains('userId')));
    });

    test('reads the documented envelope with a live session', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: currentWithSessionBody,
      );

      final session = await dataSource.fetchCurrent(token: 'jwt');

      expect(session, isNotNull);
      expect(session!.id, sessionId);
      expect(session.status, RemoteSessionStatus.connecting);
      expect(session.isLive, isTrue);
    });

    test('having no live session is a 200 with null, not an error', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: currentWithoutSessionBody,
      );

      expect(await dataSource.fetchCurrent(token: 'jwt'), isNull);
    });

    test('a response without the envelope key is malformed', () async {
      final (:dataSource, adapter: _) = buildDataSource(body: '{}');

      expect(
        () => dataSource.fetchCurrent(token: 'jwt'),
        throwsA(isA<MalformedResponseApiException>()),
      );
    });

    test('surfaces 401 and 403 as status codes', () async {
      for (final statusCode in [401, 403]) {
        final (:dataSource, adapter: _) = buildDataSource(
          statusCode: statusCode,
          body: '{"message":"nope"}',
        );

        await expectLater(
          () => dataSource.fetchCurrent(token: 'jwt'),
          throwsA(
            isA<HttpApiException>().having(
              (e) => e.statusCode,
              'status',
              statusCode,
            ),
          ),
        );
      }
    });
  });

  group('POST /remote-sessions/:id/activate', () {
    test('uses POST on /remote-sessions/<uuid>/activate', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: activatedResponseBody,
      );

      await dataSource.activate(id: sessionId, token: 'user-jwt');

      final captured = adapter.captured!;
      expect(captured.method, 'POST');
      expect(captured.uri.path, '/remote-sessions/$sessionId/activate');
      expect(
        captured.uri.toString(),
        'http://localhost:3000/remote-sessions/$sessionId/activate',
      );
      expect(captured.uri.queryParameters, isEmpty);
      expect(captured.headers['Authorization'], 'Bearer user-jwt');
    });

    test('sends an empty body', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: activatedResponseBody,
      );

      await dataSource.activate(id: sessionId, token: 'jwt');

      expect(adapter.captured!.data, isNull);
      expect(adapter.capturedBody ?? '', isEmpty);
    });

    test('never sends status, connectedAt or any identity', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: activatedResponseBody,
      );

      await dataSource.activate(id: sessionId, token: 'jwt');

      final captured = adapter.captured!;
      final wire = '${captured.uri}${adapter.capturedBody}';
      expect(wire, isNot(contains('status')));
      expect(wire, isNot(contains('connectedAt')));
      expect(wire, isNot(contains('technicianId')));
      expect(wire, isNot(contains('userId')));
      expect(wire, isNot(contains('deviceId')));
      // Identity travels only in the Bearer token.
      expect(captured.headers['Authorization'], 'Bearer jwt');
    });

    test('accepts the documented 200 ACTIVE session', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: activatedResponseBody,
      );

      final session = await dataSource.activate(id: sessionId, token: 'jwt');

      expect(session.id, sessionId);
      expect(session.status, RemoteSessionStatus.active);
      expect(session.isActive, isTrue);
      expect(session.isLive, isTrue);
      expect(session.connectedAt, DateTime.parse('2026-03-11T09:35:12.000Z'));
      expect(session.endedAt, isNull);
      expect(session.endedBy, isNull);
    });

    test('surfaces 400, 401, 403, 404 and 409 as status codes', () async {
      for (final statusCode in [400, 401, 403, 404, 409]) {
        final (:dataSource, adapter: _) = buildDataSource(
          statusCode: statusCode,
          body: '{"message":"nope"}',
        );

        await expectLater(
          () => dataSource.activate(id: sessionId, token: 'jwt'),
          throwsA(
            isA<HttpApiException>().having(
              (e) => e.statusCode,
              'status',
              statusCode,
            ),
          ),
        );
      }
    });

    test('an already ACTIVE session answers 200, not an error', () async {
      // The backend documents the call as idempotent, which is what makes a
      // race between our own POST and a realtime echo harmless.
      final (:dataSource, adapter: _) = buildDataSource(
        body: activatedResponseBody,
      );

      final session = await dataSource.activate(id: sessionId, token: 'jwt');

      expect(session.status, RemoteSessionStatus.active);
    });
  });

  group('POST /remote-sessions/:id/close', () {
    test('uses POST on /remote-sessions/<uuid>/close', () async {
      final (:dataSource, :adapter) = buildDataSource(body: closedResponseBody);

      await dataSource.close(id: sessionId, token: 'user-jwt');

      final captured = adapter.captured!;
      expect(captured.method, 'POST');
      expect(captured.uri.path, '/remote-sessions/$sessionId/close');
      expect(captured.headers['Authorization'], 'Bearer user-jwt');
    });

    test('sends an empty body', () async {
      final (:dataSource, :adapter) = buildDataSource(body: closedResponseBody);

      await dataSource.close(id: sessionId, token: 'jwt');

      expect(adapter.captured!.data, isNull);
      expect(adapter.capturedBody ?? '', isEmpty);
    });

    test('accepts the documented 200 closed session', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: closedResponseBody,
      );

      final session = await dataSource.close(id: sessionId, token: 'jwt');

      expect(session.status, RemoteSessionStatus.closed);
      expect(session.endedBy, RemoteSessionEndedBy.technician);
      expect(session.endedAt, DateTime.parse('2026-03-11T09:51:02.000Z'));
      expect(session.isLive, isFalse);
    });

    test('surfaces 400, 401, 403, 404 and 409 as status codes', () async {
      for (final statusCode in [400, 401, 403, 404, 409]) {
        final (:dataSource, adapter: _) = buildDataSource(
          statusCode: statusCode,
          body: '{"message":"nope"}',
        );

        await expectLater(
          () => dataSource.close(id: sessionId, token: 'jwt'),
          throwsA(
            isA<HttpApiException>().having(
              (e) => e.statusCode,
              'status',
              statusCode,
            ),
          ),
        );
      }
    });
  });

  group('base URL', () {
    test('remote session routes are mounted at the root', () async {
      final (:dataSource, :adapter) = buildDataSource(
        baseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms/',
        body: currentWithoutSessionBody,
      );

      await dataSource.fetchCurrent(token: 'jwt');

      expect(
        adapter.captured!.uri.toString(),
        'https://w4qb7jsw-3000.brs.devtunnels.ms/remote-sessions/current',
      );
    });
  });

  group('paths', () {
    test('are exactly the documented technician routes', () {
      expect(
        RemoteSessionsRemoteDataSourceImpl.remoteSessionsPath,
        '/remote-sessions',
      );
      expect(
        RemoteSessionsRemoteDataSourceImpl.currentPath,
        '/remote-sessions/current',
      );
      expect(
        RemoteSessionsRemoteDataSourceImpl.activatePath(sessionId),
        '/remote-sessions/$sessionId/activate',
      );
      expect(
        RemoteSessionsRemoteDataSourceImpl.closePath(sessionId),
        '/remote-sessions/$sessionId/close',
      );
      expect(
        RemoteSessionsRemoteDataSourceImpl.supportRequestIdField,
        'supportRequestId',
      );
    });

    test('the device-only routes have no builder in this data source', () {
      // `/device/remote-sessions/...` is protected with @DeviceAuth(): this
      // application never holds a Device JWT and must not address it.
      expect(
        RemoteSessionsRemoteDataSourceImpl.currentPath,
        isNot(startsWith('/device')),
      );
      expect(
        RemoteSessionsRemoteDataSourceImpl.closePath(sessionId),
        isNot(contains('/device/')),
      );
      expect(
        RemoteSessionsRemoteDataSourceImpl.activatePath(sessionId),
        isNot(contains('/device/')),
      );
    });
  });
}

Map<String, dynamic> capturedJsonBody(RecordingAdapter adapter) =>
    adapter.captured!.data as Map<String, dynamic>;
