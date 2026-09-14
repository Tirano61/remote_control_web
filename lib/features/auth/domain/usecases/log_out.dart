import '../repositories/auth_repository.dart';

/// Ends the local session.
///
/// The backend exposes no logout endpoint and no JWT invalidation, so this only
/// clears the persisted User JWT. Inventing `/auth/logout` is not allowed.
class LogOut {
  const LogOut({required AuthRepository repository}) : _repository = repository;

  final AuthRepository _repository;

  Future<void> call() => _repository.logOut();
}
