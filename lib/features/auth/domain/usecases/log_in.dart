import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../entities/user_session.dart';
import '../repositories/auth_repository.dart';
import '../validation/credentials_validator.dart';

/// Message shown when a valid backend account is not allowed in this console.
const String kTechnicianConsoleAccessDeniedMessage =
    'Este usuario no tiene permisos para acceder al panel técnico.';

/// Authenticates a technician/admin and establishes the session.
///
/// Beyond the REST call it enforces the console access policy: an account
/// authenticated by the backend that holds neither `admin` nor `tecnico` is
/// signed out again and its token removed.
class LogIn {
  const LogIn({
    required AuthRepository repository,
    CredentialsValidator validator = const CredentialsValidator(),
  }) : _repository = repository,
       _validator = validator;

  final AuthRepository _repository;
  final CredentialsValidator _validator;

  Future<Result<UserSession>> call({
    required String email,
    required String password,
  }) async {
    final emailError = _validator.validateEmail(email);
    if (emailError != null) return Failed(ValidationFailure(emailError));

    final passwordError = _validator.validatePassword(password);
    if (passwordError != null) return Failed(ValidationFailure(passwordError));

    final result = await _repository.logIn(
      email: email.trim(),
      password: password,
    );

    return switch (result) {
      Failed<UserSession>() => result,
      Success<UserSession>(:final value) => await _enforceConsoleAccess(value),
    };
  }

  Future<Result<UserSession>> _enforceConsoleAccess(UserSession session) async {
    if (session.user.canAccessTechnicianConsole) return Success(session);
    await _repository.logOut();
    return const Failed(
      ForbiddenFailure(kTechnicianConsoleAccessDeniedMessage),
    );
  }
}
