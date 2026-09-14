import 'api_exception.dart';

/// A decoded JSON object response.
class ApiResponse {
  const ApiResponse({required this.statusCode, required this.data});

  final int statusCode;

  /// Decoded JSON body. Empty when the backend answered with no content.
  final Map<String, dynamic> data;

  @override
  String toString() => 'ApiResponse(statusCode: $statusCode)';
}

/// A decoded JSON array response.
///
/// `GET /devices` and `GET /support-requests` answer with a top level array of
/// objects, so they cannot be represented by [ApiResponse].
class ApiListResponse {
  const ApiListResponse({required this.statusCode, required this.data});

  final int statusCode;

  /// Decoded JSON array. Every element is a JSON object.
  final List<Map<String, dynamic>> data;

  @override
  String toString() =>
      'ApiListResponse(statusCode: $statusCode, items: ${data.length})';
}

/// Centralised HTTP entry point.
///
/// Every REST call of the application goes through this abstraction. Widgets
/// and BLoCs never talk to it directly: only data sources do.
///
/// Implementations must throw [ApiException] subtypes and nothing else.
abstract interface class ApiClient {
  Future<ApiResponse> get(
    String path, {
    String? bearerToken,
    Map<String, dynamic>? queryParameters,
  });

  /// Same as [get], for endpoints documented as answering a JSON array.
  Future<ApiListResponse> getList(
    String path, {
    String? bearerToken,
    Map<String, dynamic>? queryParameters,
  });

  Future<ApiResponse> post(
    String path, {
    Map<String, dynamic>? body,
    String? bearerToken,
  });
}
