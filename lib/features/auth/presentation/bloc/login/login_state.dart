part of 'login_cubit.dart';

enum LoginStatus { initial, submitting, success, failure }

/// State of the login form only.
///
/// It never holds the password, and never holds the User JWT: the session is
/// handed to the global [UserSessionBloc] instead.
class LoginState extends Equatable {
  const LoginState({this.status = LoginStatus.initial, this.errorMessage});

  final LoginStatus status;

  /// User safe message. Never a raw backend error or a stack trace.
  final String? errorMessage;

  bool get isSubmitting => status == LoginStatus.submitting;

  @override
  List<Object?> get props => [status, errorMessage];

  @override
  String toString() => 'LoginState(status: $status)';
}
