import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/storage/user_token_storage.dart';

/// Browser backed implementation of [UserTokenStorage].
///
/// On Flutter Web `shared_preferences` writes to `window.localStorage`, which
/// is what allows the session to survive a page refresh.
///
/// SECURITY TRADE-OFF (documented deliberately):
///
/// * `localStorage` is readable by any JavaScript running on the origin, so a
///   successful XSS would expose the User JWT. The alternative — an HttpOnly,
///   SameSite cookie issued by the backend — is not available: the current
///   contract returns the token in the JSON body and expects
///   `Authorization: Bearer`. Changing that is a backend change and is out of
///   scope here.
/// * The exposure window is bounded: User JWTs live 2h and there is no refresh
///   token, so a leaked token expires on its own.
/// * Only the token is persisted. The password is never written anywhere, and
///   the user profile is always re-fetched from `GET /auth/check-status`
///   instead of being cached locally.
/// * Hardening that belongs to later stages: a strict Content-Security-Policy
///   for `web/index.html`, and moving to HttpOnly cookies if the backend
///   contract ever offers them.
class BrowserUserTokenStorage implements UserTokenStorage {
  BrowserUserTokenStorage({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  /// Storage key. Namespaced to avoid clashing with anything else on the origin.
  static const String tokenKey = 'remote_control_web.user_token';

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read() async {
    final token = await _preferences.getString(tokenKey);
    if (token == null || token.isEmpty) return null;
    return token;
  }

  @override
  Future<void> save(String token) => _preferences.setString(tokenKey, token);

  @override
  Future<void> clear() => _preferences.remove(tokenKey);
}
