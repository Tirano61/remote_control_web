import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/support/data/datasources/support_remote_data_source.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';

import '../../../support/recording_api.dart';

/// Response bodies copied verbatim from
/// `docs/backend/ENDPOINTS.md` → "Support requests — Web".
const String queueResponseBody = '''
[
  {
    "id": "8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77",
    "deviceId": "550e8400-e29b-41d4-a716-446655440000",
    "status": "WAITING",
    "technicianId": null,
    "technician": null,
    "createdAt": "2026-03-11T09:30:00.000Z",
    "assignedAt": null,
    "respondedAt": null,
    "closedAt": null,
    "device": {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "publicId": "384-729-142",
      "name": "Tablet Tolva 01",
      "manufacturer": "Samsung",
      "model": "SM-X210",
      "isOnline": true
    }
  }
]
''';

const String assignedResponseBody = '''
{
  "id": "8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77",
  "deviceId": "550e8400-e29b-41d4-a716-446655440000",
  "status": "ASSIGNED",
  "technicianId": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  "technician": {
    "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "name": "Ana Torres"
  },
  "createdAt": "2026-03-11T09:30:00.000Z",
  "assignedAt": "2026-03-11T09:31:12.000Z",
  "respondedAt": null,
  "closedAt": null,
  "device": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "publicId": "384-729-142",
    "name": "Tablet Tolva 01",
    "manufacturer": "Samsung",
    "model": "SM-X210",
    "isOnline": true
  }
}
''';

({SupportRemoteDataSource dataSource, RecordingAdapter adapter})
buildDataSource({
  String baseUrl = 'http://localhost:3000',
  int statusCode = 200,
  String body = '[]',
}) {
  final (:client, :adapter) = buildRecordingClient(
    baseUrl: baseUrl,
    statusCode: statusCode,
    body: body,
  );
  return (
    dataSource: SupportRemoteDataSourceImpl(apiClient: client),
    adapter: adapter,
  );
}

void main() {
  group('GET /support-requests', () {
    test('uses GET on /support-requests with a Bearer User JWT', () async {
      final (:dataSource, :adapter) = buildDataSource(body: queueResponseBody);

      await dataSource.fetchRequests(token: 'user-jwt');

      final request = adapter.captured!;
      expect(request.method, 'GET');
      expect(request.uri.path, '/support-requests');
      expect(request.uri.toString(), 'http://localhost:3000/support-requests');
      expect(request.headers['Authorization'], 'Bearer user-jwt');
      expect(request.data, isNull);
    });

    test('sends no query parameter when no filter was asked for', () async {
      final (:dataSource, :adapter) = buildDataSource(body: queueResponseBody);

      await dataSource.fetchRequests(token: 'jwt');

      // Without `status` the backend returns every request; an empty or null
      // value must not be sent, an unknown one would be a 400.
      expect(adapter.captured!.uri.queryParameters, isEmpty);
      expect(adapter.captured!.uri.toString(), isNot(contains('?')));
    });

    test('sends the documented status query parameter when filtering', () async {
      final (:dataSource, :adapter) = buildDataSource(body: queueResponseBody);

      await dataSource.fetchRequests(
        token: 'jwt',
        status: SupportRequestStatus.waiting,
      );

      final request = adapter.captured!;
      expect(request.uri.path, '/support-requests');
      expect(request.uri.queryParameters, {'status': 'WAITING'});
      expect(
        request.uri.toString(),
        'http://localhost:3000/support-requests?status=WAITING',
      );
    });

    test('every documented status is sent with its exact wire value', () async {
      for (final status in SupportRequestStatus.known) {
        final (:dataSource, :adapter) = buildDataSource(body: '[]');

        await dataSource.fetchRequests(token: 'jwt', status: status);

        expect(adapter.captured!.uri.queryParameters['status'], status.wireValue);
      }

      expect(
        SupportRequestStatus.known.map((status) => status.wireValue),
        ['WAITING', 'ASSIGNED', 'ACCEPTED', 'REJECTED', 'CANCELLED', 'COMPLETED'],
      );
    });

    test('accepts the documented 200 array response shape', () async {
      final (:dataSource, adapter: _) = buildDataSource(body: queueResponseBody);

      final requests = await dataSource.fetchRequests(token: 'jwt');

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.id, '8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77');
      expect(request.deviceId, '550e8400-e29b-41d4-a716-446655440000');
      expect(request.status, SupportRequestStatus.waiting);
      expect(request.technicianId, isNull);
      expect(request.technician, isNull);
      expect(request.createdAt, DateTime.parse('2026-03-11T09:30:00.000Z'));
      expect(request.assignedAt, isNull);
      expect(request.respondedAt, isNull);
      expect(request.closedAt, isNull);
      // The device block only exists in the technician facing responses.
      expect(request.device, isNotNull);
      expect(request.device!.publicId, '384-729-142');
      expect(request.device!.model, 'SM-X210');
      expect(request.device!.isOnline, isTrue);
    });

    test('an unknown future status does not crash the client', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: '[{"id":"a","deviceId":"b","status":"ESCALATED",'
            '"createdAt":"2026-03-11T09:30:00.000Z"}]',
      );

      final request = (await dataSource.fetchRequests(token: 'jwt')).single;

      expect(request.status.wireValue, 'ESCALATED');
      expect(request.status.isKnown, isFalse);
      // An unrecognised state grants nothing.
      expect(request.status.isAssignable, isFalse);
      expect(request.status.isActive, isFalse);
    });

    test('surfaces 401, 403 and 400 as status codes', () async {
      for (final statusCode in [400, 401, 403]) {
        final (:dataSource, adapter: _) = buildDataSource(
          statusCode: statusCode,
          body: '{"message":"nope"}',
        );

        expect(
          () => dataSource.fetchRequests(token: 'jwt'),
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

  group('GET /support-requests/:id', () {
    test('uses GET on /support-requests/<uuid>', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: assignedResponseBody,
      );

      await dataSource.fetchRequest(
        id: '8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77',
        token: 'user-jwt',
      );

      final request = adapter.captured!;
      expect(request.method, 'GET');
      expect(
        request.uri.path,
        '/support-requests/8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77',
      );
      expect(request.uri.queryParameters, isEmpty);
      expect(request.headers['Authorization'], 'Bearer user-jwt');
      expect(request.data, isNull);
    });

    test('surfaces 404 for an unknown support request', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 404,
        body: '{"message":"Support request not found"}',
      );

      expect(
        () => dataSource.fetchRequest(id: 'x', token: 'jwt'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('POST /support-requests/:id/assign', () {
    test('uses POST on /support-requests/<uuid>/assign', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: assignedResponseBody,
      );

      await dataSource.assign(
        id: '8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77',
        token: 'user-jwt',
      );

      final request = adapter.captured!;
      expect(request.method, 'POST');
      expect(
        request.uri.path,
        '/support-requests/8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77/assign',
      );
      expect(request.headers['Authorization'], 'Bearer user-jwt');
    });

    test('sends an empty body and never a technicianId', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: assignedResponseBody,
      );

      await dataSource.assign(id: 'req-id', token: 'user-jwt');

      // The contract documents an empty body: technicianId is NOT accepted,
      // and forbidNonWhitelisted would answer 400 for any extra property.
      expect(adapter.captured!.data, isNull);
      expect(adapter.capturedBody ?? '', isEmpty);
      expect(adapter.capturedBody ?? '', isNot(contains('technicianId')));
      expect(adapter.capturedBody ?? '', isNot(contains('userId')));
    });

    test('the technician is never identified by the client', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: assignedResponseBody,
      );

      await dataSource.assign(id: 'req-id', token: 'user-jwt');

      final request = adapter.captured!;
      final wire =
          '${request.uri}${request.headers}${request.data}'
          '${adapter.capturedBody}';
      expect(wire, isNot(contains('technicianId')));
      expect(wire, isNot(contains('userId')));
      // Identity travels only in the Bearer token.
      expect(request.headers['Authorization'], 'Bearer user-jwt');
    });

    test('accepts the documented 200 response with technician and device', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: assignedResponseBody,
      );

      final request = await dataSource.assign(id: 'req-id', token: 'jwt');

      expect(request.status, SupportRequestStatus.assigned);
      expect(request.technicianId, '7c9e6679-7425-40de-944b-e07fc1f90ae7');
      expect(request.technician!.name, 'Ana Torres');
      expect(request.assignedAt, DateTime.parse('2026-03-11T09:31:12.000Z'));
      expect(request.device!.isOnline, isTrue);
    });

    test('surfaces 409 when the request is no longer WAITING', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 409,
        body: '{"message":"Support request is not WAITING"}',
      );

      expect(
        () => dataSource.assign(id: 'x', token: 'jwt'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
    });

    test('surfaces 409 when the device is offline', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 409,
        body: '{"message":"Device is offline"}',
      );

      // Both 409 reasons share the status code on purpose; the client must not
      // branch on the message string.
      expect(
        () => dataSource.assign(id: 'x', token: 'jwt'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
    });

    test('surfaces 400 for a malformed UUID', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 400,
        body: '{"message":"Validation failed (uuid is expected)"}',
      );

      expect(
        () => dataSource.assign(id: 'not-a-uuid', token: 'jwt'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 400),
        ),
      );
    });
  });

  group('base URL', () {
    test('support routes are mounted at the root, with no global prefix', () async {
      final (:dataSource, :adapter) = buildDataSource(
        baseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms/',
        body: queueResponseBody,
      );

      await dataSource.fetchRequests(token: 'jwt');

      expect(
        adapter.captured!.uri.toString(),
        'https://w4qb7jsw-3000.brs.devtunnels.ms/support-requests',
      );
    });
  });

  group('paths', () {
    const id = '8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77';

    test('are exactly the documented technician routes', () {
      expect(
        SupportRemoteDataSourceImpl.supportRequestsPath,
        '/support-requests',
      );
      expect(
        SupportRemoteDataSourceImpl.requestPath(id),
        '/support-requests/$id',
      );
      expect(
        SupportRemoteDataSourceImpl.assignPath(id),
        '/support-requests/$id/assign',
      );
      expect(SupportRemoteDataSourceImpl.statusQueryParameter, 'status');
    });

    test('the device-only routes have no builder in this data source', () {
      // `/support-requests/current`, `/accept`, `/reject` and `/cancel` are
      // protected with @DeviceAuth(): this application never holds a Device JWT
      // and must not be able to address them.
      const built = [
        SupportRemoteDataSourceImpl.supportRequestsPath,
      ];
      expect(built.single, isNot(endsWith('/current')));
      expect(SupportRemoteDataSourceImpl.assignPath(id), endsWith('/assign'));
      expect(
        SupportRemoteDataSourceImpl.assignPath(id),
        isNot(anyOf(contains('/accept'), contains('/reject'), contains('/cancel'))),
      );
    });
  });
}
