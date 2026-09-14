import '../network/api_exception.dart';
import 'failure.dart';

/// Translates a transport level [ApiException] into the [Failure] categories
/// presentation is allowed to see.
///
/// The mapping follows the "Common errors" table of
/// `docs/backend/ENDPOINTS.md`. Business logic branches on the HTTP status
/// code only: backend `message` strings are not part of the contract.
///
/// Callers that need a more precise wording for a specific endpoint pass
/// [overrides]; returning `null` from it falls back to the default mapping.
Failure failureFromApiException(
  ApiException exception, {
  Failure? Function(int statusCode)? overrides,
}) => switch (exception) {
  NetworkApiException() => const NetworkFailure(),
  MalformedResponseApiException() => const UnexpectedFailure(
    'La respuesta del servidor no pudo interpretarse.',
  ),
  HttpApiException(:final statusCode) =>
    overrides?.call(statusCode) ?? _defaultForStatus(statusCode),
};

Failure _defaultForStatus(int statusCode) => switch (statusCode) {
  400 => const ValidationFailure(),
  // The session stopped being valid. There is no refresh token, so the only
  // possible recovery is a new login.
  401 => const AuthFailure(),
  // Authenticated but not authorised: the session stays alive.
  403 => const ForbiddenFailure(),
  404 => const NotFoundFailure(),
  409 => const ConflictFailure(),
  _ => const ServerFailure(),
};
