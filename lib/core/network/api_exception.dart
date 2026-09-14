/// Transport level errors raised by [ApiClient] implementations.
///
/// These never reach presentation: repositories translate them into
/// `Failure` values.
sealed class ApiException implements Exception {
  const ApiException();
}

/// The request never produced an HTTP response: no connection, DNS error,
/// timeout, cancelled request, browser/CORS transport error.
final class NetworkApiException extends ApiException {
  const NetworkApiException();

  @override
  String toString() => 'NetworkApiException';
}

/// The server answered with a non 2xx status code.
///
/// Only the status code is carried on purpose. Backend `message` strings are
/// not part of the contract and business logic must not branch on them.
final class HttpApiException extends ApiException {
  const HttpApiException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'HttpApiException(statusCode: $statusCode)';
}

/// A 2xx response whose body did not have the documented shape.
final class MalformedResponseApiException extends ApiException {
  const MalformedResponseApiException();

  @override
  String toString() => 'MalformedResponseApiException';
}
