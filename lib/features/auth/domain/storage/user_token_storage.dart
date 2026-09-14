/// Persistence port for the User JWT.
///
/// Domain and presentation depend only on this interface; whether the token
/// lives in browser storage, in memory, or anywhere else is a data layer
/// decision.
abstract interface class UserTokenStorage {
  /// The persisted User JWT, or `null` when there is none.
  Future<String?> read();

  /// Persists the User JWT, replacing any previous value.
  Future<void> save(String token);

  /// Removes the persisted User JWT.
  Future<void> clear();
}
