import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/core/network/dio_api_client.dart';
import 'package:remote_control_web/features/devices/data/datasources/devices_remote_data_source.dart';

import '../../../support/recording_api.dart';

/// Response bodies copied verbatim from
/// `docs/backend/ENDPOINTS.md` → "Devices administration — Web".
const String devicesResponseBody = '''
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "publicId": "384-729-142",
    "name": "Tablet Tolva 01",
    "manufacturer": "Samsung",
    "model": "SM-X210",
    "androidVersion": "14",
    "appVersion": "1.0.0",
    "isActive": true,
    "isOnline": true,
    "createdAt": "2026-03-11T09:14:02.000Z",
    "updatedAt": "2026-03-11T09:20:31.000Z"
  }
]
''';

const String deviceResponseBody = '''
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "publicId": "384-729-142",
  "name": "Tablet Tolva 01",
  "manufacturer": "Samsung",
  "model": "SM-X210",
  "androidVersion": "14",
  "appVersion": "1.0.0",
  "isActive": true,
  "isOnline": false,
  "createdAt": "2026-03-11T09:14:02.000Z",
  "updatedAt": "2026-03-11T09:20:31.000Z"
}
''';

({DevicesRemoteDataSource dataSource, RecordingAdapter adapter})
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
    dataSource: DevicesRemoteDataSourceImpl(apiClient: client),
    adapter: adapter,
  );
}

void main() {
  group('GET /devices', () {
    test('uses GET on /devices with a Bearer User JWT and no query', () async {
      final (:dataSource, :adapter) = buildDataSource(body: devicesResponseBody);

      await dataSource.fetchDevices(token: 'user-jwt');

      final request = adapter.captured!;
      expect(request.method, 'GET');
      expect(request.uri.path, '/devices');
      expect(request.uri.toString(), 'http://localhost:3000/devices');
      // The contract documents no body and no query parameters.
      expect(request.uri.queryParameters, isEmpty);
      expect(request.data, isNull);
      expect(request.headers['Authorization'], 'Bearer user-jwt');
    });

    test('accepts the documented 200 array response shape', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: devicesResponseBody,
      );

      final devices = await dataSource.fetchDevices(token: 'user-jwt');

      expect(devices, hasLength(1));
      final device = devices.single;
      expect(device.id, '550e8400-e29b-41d4-a716-446655440000');
      expect(device.publicId, '384-729-142');
      expect(device.name, 'Tablet Tolva 01');
      expect(device.manufacturer, 'Samsung');
      expect(device.model, 'SM-X210');
      expect(device.androidVersion, '14');
      expect(device.appVersion, '1.0.0');
      expect(device.isActive, isTrue);
      expect(device.isOnline, isTrue);
      expect(device.createdAt, DateTime.parse('2026-03-11T09:14:02.000Z'));
      expect(device.updatedAt, DateTime.parse('2026-03-11T09:20:31.000Z'));
    });

    test('accepts a device created with an empty body (null fields)', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: '[{"id":"a","publicId":"111-222-333","name":null,'
            '"manufacturer":null,"model":null,"androidVersion":null,'
            '"appVersion":null,"isActive":true,"isOnline":false,'
            '"createdAt":"2026-03-11T09:14:02.000Z",'
            '"updatedAt":"2026-03-11T09:14:02.000Z"}]',
      );

      final device = (await dataSource.fetchDevices(token: 'jwt')).single;

      expect(device.name, isNull);
      expect(device.model, isNull);
      expect(device.androidVersion, isNull);
      // The readable id is used when there is no name.
      expect(device.displayName, '111-222-333');
    });

    test('an empty list is a valid response', () async {
      final (:dataSource, adapter: _) = buildDataSource(body: '[]');

      expect(await dataSource.fetchDevices(token: 'jwt'), isEmpty);
    });

    test('surfaces 401 when the User JWT is missing or expired', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 401,
        body: '{"message":"Unauthorized"}',
      );

      expect(
        () => dataSource.fetchDevices(token: 'expired'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
    });

    test('surfaces 403 for a user without role admin/tecnico', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 403,
        body: '{"message":"Forbidden resource"}',
      );

      expect(
        () => dataSource.fetchDevices(token: 'jwt'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
    });

    test('rejects a 200 body that is not an array', () async {
      final (:dataSource, adapter: _) = buildDataSource(body: '{"id":"a"}');

      expect(
        () => dataSource.fetchDevices(token: 'jwt'),
        throwsA(isA<MalformedResponseApiException>()),
      );
    });

    test('rejects a row without isOnline', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: '[{"id":"a","publicId":"111-222-333","isActive":true}]',
      );

      expect(
        () => dataSource.fetchDevices(token: 'jwt'),
        throwsA(isA<MalformedResponseApiException>()),
      );
    });
  });

  group('GET /devices/:id', () {
    test('uses GET on /devices/<uuid> with a Bearer User JWT', () async {
      final (:dataSource, :adapter) = buildDataSource(body: deviceResponseBody);

      await dataSource.fetchDevice(
        id: '550e8400-e29b-41d4-a716-446655440000',
        token: 'user-jwt',
      );

      final request = adapter.captured!;
      expect(request.method, 'GET');
      expect(
        request.uri.path,
        '/devices/550e8400-e29b-41d4-a716-446655440000',
      );
      expect(request.headers['Authorization'], 'Bearer user-jwt');
      expect(request.data, isNull);
    });

    test('accepts the same object shape as one list element', () async {
      final (:dataSource, adapter: _) = buildDataSource(body: deviceResponseBody);

      final device = await dataSource.fetchDevice(id: 'x', token: 'jwt');

      expect(device.publicId, '384-729-142');
      // isOnline is presence, isActive is the persisted administrative state.
      expect(device.isOnline, isFalse);
      expect(device.isActive, isTrue);
    });

    test('surfaces 404 for an unknown device', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 404,
        body: '{"message":"Device not found"}',
      );

      expect(
        () => dataSource.fetchDevice(id: 'x', token: 'jwt'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });

  group('base URL', () {
    test('device routes are mounted at the root, with no global prefix', () async {
      final (:dataSource, :adapter) = buildDataSource(
        baseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms/',
        body: devicesResponseBody,
      );

      await dataSource.fetchDevices(token: 'jwt');

      expect(
        adapter.captured!.uri.toString(),
        'https://w4qb7jsw-3000.brs.devtunnels.ms/devices',
      );
    });
  });

  group('security', () {
    test('the token never leaks into the transport exception', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 401,
        body: '{"message":"Unauthorized"}',
      );

      try {
        await dataSource.fetchDevices(token: 'super-secret-jwt');
        fail('expected an HttpApiException');
      } on HttpApiException catch (exception) {
        expect(exception.toString(), isNot(contains('super-secret-jwt')));
        expect(exception.toString(), contains('401'));
      }
    });

    test('the shared client installs no interceptor of its own', () {
      // Request headers carry the User JWT and login bodies carry passwords,
      // so DioApiClient must never attach a logging interceptor.
      final dio = Dio();
      final before = dio.interceptors.length;

      DioApiClient(
        config: const AppConfig(backendBaseUrl: 'http://localhost:3000'),
        dio: dio,
      );

      expect(dio.interceptors.length, before);
      expect(dio.interceptors.whereType<LogInterceptor>(), isEmpty);
    });
  });
}
