/// Read-only access to the current User JWT.
///
/// Features other than `auth` need the token to authenticate their REST calls,
/// but they must not know where it is stored nor be able to change it. They
/// depend on this port; the composition root binds it to the same storage the
/// auth feature already owns, so the token is never duplicated across several
/// storages.
///
/// Only the data layer may use it. Presentation and domain never see the token.
abstract interface class UserTokenProvider {
  /// The current User JWT, or `null` when there is no session.
  Future<String?> currentToken();
}
