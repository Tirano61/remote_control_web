import 'package:equatable/equatable.dart';

/// Application level error categories.
///
/// A [Failure] is what presentation is allowed to see. Transport details
/// (`DioException`, status codes, backend message strings, stack traces) never
/// leave the data layer.
sealed class Failure extends Equatable {
  const Failure(this.message);

  /// Human readable, user safe message.
  final String message;

  @override
  List<Object?> get props => [message];

  @override
  String toString() => '$runtimeType(message: $message)';
}

/// The server could not be reached: no connection, DNS failure, timeout.
final class NetworkFailure extends Failure {
  const NetworkFailure([
    super.message = 'No se pudo conectar con el servidor.',
  ]);
}

/// Credentials are not valid, or the stored token is missing/expired/rejected.
///
/// Maps to HTTP 401.
final class AuthFailure extends Failure {
  const AuthFailure([
    super.message = 'La sesión no es válida. Inicia sesión nuevamente.',
  ]);
}

/// Authenticated, but not allowed to perform the action.
///
/// Maps to HTTP 403 and to the local technician-console role policy.
final class ForbiddenFailure extends Failure {
  const ForbiddenFailure([
    super.message = 'No tienes permisos para realizar esta acción.',
  ]);
}

/// The request was rejected by validation.
///
/// Maps to HTTP 400 and to local form validation.
final class ValidationFailure extends Failure {
  const ValidationFailure([
    super.message = 'Los datos enviados no son válidos.',
  ]);
}

/// The resource does not exist, or does not belong to the caller.
///
/// Maps to HTTP 404.
final class NotFoundFailure extends Failure {
  const NotFoundFailure([super.message = 'El recurso no existe.']);
}

/// The resource exists but its current state does not allow the transition.
///
/// Maps to HTTP 409.
final class ConflictFailure extends Failure {
  const ConflictFailure([
    super.message = 'La operación no es posible en el estado actual.',
  ]);
}

/// Unexpected server error.
///
/// Maps to HTTP 5xx and to any unclassified status code.
final class ServerFailure extends Failure {
  const ServerFailure([
    super.message = 'El servidor no pudo procesar la solicitud.',
  ]);
}

/// The response could not be understood, or an unexpected client error happened.
final class UnexpectedFailure extends Failure {
  const UnexpectedFailure([
    super.message = 'Ocurrió un error inesperado.',
  ]);
}
