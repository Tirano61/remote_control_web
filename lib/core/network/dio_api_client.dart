import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// [ApiClient] implementation backed by Dio.
///
/// Security note: no logging interceptor is installed, and none must be added.
/// Request bodies carry passwords and request headers carry the User JWT;
/// neither may ever reach the console. Errors are reduced to a status code
/// before leaving this class.
class DioApiClient implements ApiClient {
  DioApiClient({required AppConfig config, Dio? dio})
    : _dio =
          (dio ?? Dio())
            ..options.baseUrl = config.normalizedBackendBaseUrl
            ..options.connectTimeout = config.connectTimeout
            ..options.receiveTimeout = config.receiveTimeout
            ..options.sendTimeout = config.sendTimeout
            ..options.responseType = ResponseType.json
            ..options.contentType = Headers.jsonContentType
            // Non 2xx statuses are turned into DioException and mapped below,
            // so callers get a typed ApiException instead of a raw response.
            ..options.validateStatus = ((status) =>
                status != null && status >= 200 && status < 300);

  final Dio _dio;

  @override
  Future<ApiResponse> get(String path, {String? bearerToken}) =>
      _send(() => _dio.get<dynamic>(path, options: _options(bearerToken)));

  @override
  Future<ApiResponse> post(
    String path, {
    Map<String, dynamic>? body,
    String? bearerToken,
  }) => _send(
    () => _dio.post<dynamic>(path, data: body, options: _options(bearerToken)),
  );

  Options _options(String? bearerToken) => Options(
    headers: {
      if (bearerToken != null && bearerToken.isNotEmpty)
        'Authorization': 'Bearer $bearerToken',
    },
  );

  Future<ApiResponse> _send(Future<Response<dynamic>> Function() request) async {
    try {
      final response = await request();
      return ApiResponse(
        statusCode: response.statusCode ?? 200,
        data: _asJsonObject(response.data),
      );
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  Map<String, dynamic> _asJsonObject(dynamic data) {
    if (data == null) return const {};
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isEmpty) return const {};
    throw const MalformedResponseApiException();
  }

  ApiException _mapDioException(DioException error) {
    final statusCode = error.response?.statusCode;
    if (statusCode != null) {
      return HttpApiException(statusCode);
    }
    return switch (error.type) {
      // No response arrived: treat everything as "server not reachable", which
      // is what the user needs to know and what keeps the stored token.
      DioExceptionType.badResponse => const MalformedResponseApiException(),
      _ => const NetworkApiException(),
    };
  }
}
