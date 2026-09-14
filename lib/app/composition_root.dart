import '../core/config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/network/dio_api_client.dart';
import '../features/auth/data/datasources/auth_remote_data_source.dart';
import '../features/auth/data/repositories/auth_repository_impl.dart';
import '../features/auth/data/storage/browser_user_token_storage.dart';
import '../features/auth/domain/repositories/auth_repository.dart';
import '../features/auth/domain/storage/user_token_storage.dart';
import '../features/auth/domain/usecases/log_in.dart';
import '../features/auth/domain/usecases/log_out.dart';
import '../features/auth/domain/usecases/restore_session.dart';
import '../features/auth/presentation/bloc/login/login_cubit.dart';
import '../features/auth/presentation/bloc/user_session/user_session_bloc.dart';

/// Composition root.
///
/// Every dependency is built here and injected explicitly. There is no service
/// locator, so tests can replace any piece with a fake.
class AppDependencies {
  AppDependencies({required this.config, required this.authRepository});

  /// Wiring used by the running application.
  factory AppDependencies.production({AppConfig? config}) {
    final resolvedConfig = config ?? AppConfig.fromEnvironment();
    final ApiClient apiClient = DioApiClient(config: resolvedConfig);
    final UserTokenStorage tokenStorage = BrowserUserTokenStorage();

    return AppDependencies(
      config: resolvedConfig,
      authRepository: AuthRepositoryImpl(
        remoteDataSource: AuthRemoteDataSourceImpl(apiClient: apiClient),
        tokenStorage: tokenStorage,
      ),
    );
  }

  final AppConfig config;
  final AuthRepository authRepository;

  late final LogIn logIn = LogIn(repository: authRepository);
  late final RestoreSession restoreSession = RestoreSession(
    repository: authRepository,
  );
  late final LogOut logOut = LogOut(repository: authRepository);

  /// Global session coordinator, already asked to restore a stored session.
  UserSessionBloc createUserSessionBloc() =>
      UserSessionBloc(restoreSession: restoreSession, logOut: logOut)
        ..add(const UserSessionStarted());

  LoginCubit createLoginCubit({
    required SessionEstablished onSessionEstablished,
  }) => LoginCubit(logIn: logIn, onSessionEstablished: onSessionEstablished);
}
