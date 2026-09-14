/// Local, pre-network validation of the login form.
///
/// The backend remains authoritative: these checks only avoid obviously
/// pointless requests and give immediate feedback.
class CredentialsValidator {
  const CredentialsValidator();

  static final RegExp _emailPattern = RegExp(
    r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$',
  );

  /// Returns an error message, or `null` when the email is acceptable.
  String? validateEmail(String? email) {
    final value = (email ?? '').trim();
    if (value.isEmpty) return 'Introduce tu email.';
    if (!_emailPattern.hasMatch(value)) return 'El email no es válido.';
    return null;
  }

  /// Returns an error message, or `null` when the password is acceptable.
  ///
  /// Only emptiness is checked on purpose: the backend password policy is not
  /// duplicated here, and no password value is ever stored or logged.
  String? validatePassword(String? password) {
    if ((password ?? '').isEmpty) return 'Introduce tu contraseña.';
    return null;
  }
}
