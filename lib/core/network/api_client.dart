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

/// Centralised HTTP entry point.
///
/// Every REST call of the application goes through this abstraction. Widgets
/// and BLoCs never talk to it directly: only data sources do.
///
/// Implementations must throw [ApiException] subtypes and nothing else.
abstract interface class ApiClient {
  Future<ApiResponse> get(String path, {String? bearerToken});

  Future<ApiResponse> post(
    String path, {
    Map<String, dynamic>? body,
    String? bearerToken,
  });
}
