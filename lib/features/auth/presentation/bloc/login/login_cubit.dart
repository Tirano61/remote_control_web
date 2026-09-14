import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../domain/entities/user_session.dart';
import '../../../domain/usecases/log_in.dart';
import '../../../domain/validation/credentials_validator.dart';
import '../user_session/user_session_bloc.dart';

part 'login_state.dart';

/// Called when the form produced a valid session. Wired to
/// [UserSessionBloc] by the composition root, so the form does not depend on
/// the global session BLoC.
typedef SessionEstablished = void Function(UserSession session);

/// Owns the login form workflow: local validation, submission and error
/// display. The resulting session belongs to [UserSessionBloc].
class LoginCubit extends Cubit<LoginState> {
  LoginCubit({
    required LogIn logIn,
    required SessionEstablished onSessionEstablished,
    CredentialsValidator validator = const CredentialsValidator(),
  }) : _logIn = logIn,
       _onSessionEstablished = onSessionEstablished,
       _validator = validator,
       super(const LoginState());

  final LogIn _logIn;
  final SessionEstablished _onSessionEstablished;
  final CredentialsValidator _validator;

  CredentialsValidator get validator => _validator;

  Future<void> submit({
    required String email,
    required String password,
  }) async {
    if (state.isSubmitting) return;

    emit(const LoginState(status: LoginStatus.submitting));

    final result = await _logIn(email: email, password: password);

    switch (result) {
      case Success<UserSession>(:final value):
        emit(const LoginState(status: LoginStatus.success));
        _onSessionEstablished(value);
      case Failed<UserSession>(:final failure):
        emit(
          LoginState(
            status: LoginStatus.failure,
            errorMessage: _messageFor(failure),
          ),
        );
    }
  }

  /// Clears a previous error when the user edits the form again.
  void errorDismissed() {
    if (state.status != LoginStatus.failure) return;
    emit(const LoginState());
  }

  String _messageFor(Failure failure) => switch (failure) {
    NetworkFailure() =>
      'No se pudo conectar con el servidor. Revisa tu conexión e inténtalo de nuevo.',
    ServerFailure() =>
      'El servidor no pudo procesar el inicio de sesión. Inténtalo más tarde.',
    _ => failure.message,
  };
}
