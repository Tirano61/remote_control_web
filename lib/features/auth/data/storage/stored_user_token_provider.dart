import '../../../../core/auth/user_token_provider.dart';
import '../../domain/storage/user_token_storage.dart';

/// Binds the [UserTokenProvider] port to the single [UserTokenStorage] that the
/// auth feature already owns.
///
/// Other features read the User JWT through this adapter, so there is exactly
/// one place where the token is persisted and exactly one place where it is
/// cleared (`LogOut`).
class StoredUserTokenProvider implements UserTokenProvider {
  const StoredUserTokenProvider({required UserTokenStorage storage})
    : _storage = storage;

  final UserTokenStorage _storage;

  @override
  Future<String?> currentToken() => _storage.read();
}
