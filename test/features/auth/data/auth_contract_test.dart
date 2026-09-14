import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/core/network/dio_api_client.dart';
import 'package:remote_control_web/features/auth/data/datasources/auth_remote_data_source.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_role.dart';

/// Captures the outgoing request and answers with a canned response, so the
/// exact wire format can be asserted against `docs/backend/ENDPOINTS.md`.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.statusCode = 200, this.body = '{}'});

  final int statusCode;
  final String body;
  RequestOptions? captured;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Response bodies copied from `docs/backend/ENDPOINTS.md`.
const String loginResponseBody = '''
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "email": "tecnico@example.com",
  "fullName": "Ana Torres",
  "roles": ["tecnico"],
  "isActive": true,
  "token": "<user jwt>"
}
''';

const String checkStatusResponseBody = '''
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "email": "tecnico@example.com",
  "fullName": "Ana Torres",
  "isActive": true,
  "roles": ["tecnico"],
  "created_at": "2026-03-11T09:14:02.000Z",
  "updated_at": "2026-03-11T09:14:02.000Z",
  "token": "<renewed user jwt>"
}
''';

({AuthRemoteDataSource dataSource, _RecordingAdapter adapter}) buildDataSource({
  String baseUrl = 'http://localhost:3000',
  int statusCode = 200,
  String body = '{}',
}) {
  final adapter = _RecordingAdapter(statusCode: statusCode, body: body);
  final dio = Dio()..httpClientAdapter = adapter;
  final client = DioApiClient(
    config: AppConfig(backendBaseUrl: baseUrl),
    dio: dio,
  );
  return (
    dataSource: AuthRemoteDataSourceImpl(apiClient: client),
    adapter: adapter,
  );
}

void main() {
  group('POST /auth/login', () {
    test('uses POST on /auth/login with only email and password', () async {
      final (:dataSource, :adapter) = buildDataSource(body: loginResponseBody);

      await dataSource.logIn(email: 'tecnico@example.com', password: 'Abc12345');

      final request = adapter.captured!;
      expect(request.method, 'POST');
      expect(request.uri.path, '/auth/login');
      expect(request.uri.toString(), 'http://localhost:3000/auth/login');
      expect(request.data, {
        'email': 'tecnico@example.com',
        'password': 'Abc12345',
      });
      // forbidNonWhitelisted on the backend rejects any extra property.
      expect((request.data as Map).keys, unorderedEquals(['email', 'password']));
      expect(request.headers[Headers.contentTypeHeader], contains('json'));
    });

    test('is a public endpoint: no Authorization header is sent', () async {
      final (:dataSource, :adapter) = buildDataSource(body: loginResponseBody);

      await dataSource.logIn(email: 'tecnico@example.com', password: 'Abc12345');

      expect(adapter.captured!.headers.containsKey('Authorization'), isFalse);
    });

    test('accepts the documented 200 response shape', () async {
      final (:dataSource, adapter: _) = buildDataSource(body: loginResponseBody);

      final session = await dataSource.logIn(
        email: 'tecnico@example.com',
        password: 'Abc12345',
      );

      expect(session.user.id, '550e8400-e29b-41d4-a716-446655440000');
      expect(session.user.email, 'tecnico@example.com');
      expect(session.user.fullName, 'Ana Torres');
      expect(session.user.isActive, isTrue);
      expect(session.user.roles, [UserRole.tecnico]);
      expect(session.token, '<user jwt>');
      // Login does not return the timestamps; check-status does.
      expect(session.user.createdAt, isNull);
      expect(session.user.updatedAt, isNull);
    });

    test('surfaces 401 for invalid credentials or an inactive user', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 401,
        body: '{"message":"Credentials are not valid"}',
      );

      expect(
        () => dataSource.logIn(email: 'a@b.com', password: 'Abc12345'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
    });

    test('surfaces 400 for a failed validation', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 400,
        body: '{"message":["password is not strong enough"]}',
      );

      expect(
        () => dataSource.logIn(email: 'a@b.com', password: 'weak'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 400),
        ),
      );
    });

    test('rejects a 200 response without a token', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: '{"id":"x","email":"a@b.com","fullName":"A","isActive":true,'
            '"roles":["tecnico"]}',
      );

      expect(
        () => dataSource.logIn(email: 'a@b.com', password: 'Abc12345'),
        throwsA(isA<MalformedResponseApiException>()),
      );
    });
  });

  group('GET /auth/check-status', () {
    test('uses GET on /auth/check-status with a Bearer User JWT', () async {
      final (:dataSource, :adapter) = buildDataSource(
        body: checkStatusResponseBody,
      );

      await dataSource.checkStatus(token: 'stored-user-jwt');

      final request = adapter.captured!;
      expect(request.method, 'GET');
      expect(request.uri.path, '/auth/check-status');
      expect(request.headers['Authorization'], 'Bearer stored-user-jwt');
      expect(request.data, isNull);
    });

    test('accepts the documented 200 response, timestamps included', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        body: checkStatusResponseBody,
      );

      final session = await dataSource.checkStatus(token: 'stored-user-jwt');

      expect(session.user.id, '550e8400-e29b-41d4-a716-446655440000');
      expect(session.user.roles, [UserRole.tecnico]);
      expect(session.user.isActive, isTrue);
      expect(session.token, '<renewed user jwt>');
      expect(
        session.user.createdAt,
        DateTime.parse('2026-03-11T09:14:02.000Z'),
      );
      expect(
        session.user.updatedAt,
        DateTime.parse('2026-03-11T09:14:02.000Z'),
      );
    });

    test('surfaces 401 for a missing, invalid or expired token', () async {
      final (:dataSource, adapter: _) = buildDataSource(
        statusCode: 401,
        body: '{"message":"Unauthorized"}',
      );

      expect(
        () => dataSource.checkStatus(token: 'expired'),
        throwsA(
          isA<HttpApiException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
    });
  });

  group('base URL', () {
    test('routes are mounted at the root, with no global prefix', () async {
      final (:dataSource, :adapter) = buildDataSource(
        baseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms',
        body: loginResponseBody,
      );

      await dataSource.logIn(email: 'a@b.com', password: 'Abc12345');

      expect(
        adapter.captured!.uri.toString(),
        'https://w4qb7jsw-3000.brs.devtunnels.ms/auth/login',
      );
    });

    test('a trailing slash in BACKEND_BASE_URL does not duplicate it', () async {
      final (:dataSource, :adapter) = buildDataSource(
        baseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms/',
        body: checkStatusResponseBody,
      );

      await dataSource.checkStatus(token: 'jwt');

      expect(
        adapter.captured!.uri.toString(),
        'https://w4qb7jsw-3000.brs.devtunnels.ms/auth/check-status',
      );
    });
  });
}
