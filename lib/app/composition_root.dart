import '../core/auth/user_token_provider.dart';
import '../core/config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/network/dio_api_client.dart';
import '../features/auth/data/datasources/auth_remote_data_source.dart';
import '../features/auth/data/repositories/auth_repository_impl.dart';
import '../features/auth/data/storage/browser_user_token_storage.dart';
import '../features/auth/data/storage/stored_user_token_provider.dart';
import '../features/auth/domain/repositories/auth_repository.dart';
import '../features/auth/domain/storage/user_token_storage.dart';
import '../features/auth/domain/usecases/log_in.dart';
import '../features/auth/domain/usecases/log_out.dart';
import '../features/auth/domain/usecases/restore_session.dart';
import '../features/auth/presentation/bloc/login/login_cubit.dart';
import '../features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import '../features/devices/data/datasources/devices_remote_data_source.dart';
import '../features/devices/data/repositories/device_repository_impl.dart';
import '../features/devices/domain/repositories/device_repository.dart';
import '../features/devices/domain/usecases/load_devices.dart';
import '../features/devices/presentation/bloc/devices/devices_bloc.dart';
import '../features/support/data/datasources/support_remote_data_source.dart';
import '../features/support/data/repositories/support_request_repository_impl.dart';
import '../features/support/domain/repositories/support_request_repository.dart';
import '../features/support/domain/usecases/assign_support_request.dart';
import '../features/support/domain/usecases/load_support_requests.dart';
import '../features/support/presentation/bloc/support_requests/support_requests_bloc.dart';

/// Composition root.
///
/// Every dependency is built here and injected explicitly. There is no service
/// locator, so tests can replace any piece with a fake.
class AppDependencies {
  AppDependencies({
    required this.config,
    required this.authRepository,
    required this.deviceRepository,
    required this.supportRequestRepository,
  });

  /// Wiring used by the running application.
  ///
  /// A single [ApiClient] and a single token storage are shared by every
  /// feature: the User JWT is persisted in exactly one place, and features
  /// other than `auth` only get read access to it through [UserTokenProvider].
  factory AppDependencies.production({AppConfig? config}) {
    final resolvedConfig = config ?? AppConfig.fromEnvironment();
    final ApiClient apiClient = DioApiClient(config: resolvedConfig);
    final UserTokenStorage tokenStorage = BrowserUserTokenStorage();
    final UserTokenProvider tokenProvider = StoredUserTokenProvider(
      storage: tokenStorage,
    );

    return AppDependencies(
      config: resolvedConfig,
      authRepository: AuthRepositoryImpl(
        remoteDataSource: AuthRemoteDataSourceImpl(apiClient: apiClient),
        tokenStorage: tokenStorage,
      ),
      deviceRepository: DeviceRepositoryImpl(
        remoteDataSource: DevicesRemoteDataSourceImpl(apiClient: apiClient),
        tokenProvider: tokenProvider,
      ),
      supportRequestRepository: SupportRequestRepositoryImpl(
        remoteDataSource: SupportRemoteDataSourceImpl(apiClient: apiClient),
        tokenProvider: tokenProvider,
      ),
    );
  }

  final AppConfig config;
  final AuthRepository authRepository;
  final DeviceRepository deviceRepository;
  final SupportRequestRepository supportRequestRepository;

  late final LogIn logIn = LogIn(repository: authRepository);
  late final RestoreSession restoreSession = RestoreSession(
    repository: authRepository,
  );
  late final LogOut logOut = LogOut(repository: authRepository);

  late final LoadDevices loadDevices = LoadDevices(
    repository: deviceRepository,
  );
  late final LoadSupportRequests loadSupportRequests = LoadSupportRequests(
    repository: supportRequestRepository,
  );
  late final AssignSupportRequest assignSupportRequest = AssignSupportRequest(
    repository: supportRequestRepository,
  );

  /// Global session coordinator, already asked to restore a stored session.
  UserSessionBloc createUserSessionBloc() =>
      UserSessionBloc(restoreSession: restoreSession, logOut: logOut)
        ..add(const UserSessionStarted());

  LoginCubit createLoginCubit({
    required SessionEstablished onSessionEstablished,
  }) => LoginCubit(logIn: logIn, onSessionEstablished: onSessionEstablished);

  /// Device list of the console, already asked for its first load.
  DevicesBloc createDevicesBloc() =>
      DevicesBloc(loadDevices: loadDevices)..add(const DevicesRequested());

  /// Support request queue of the console, already asked for its first load.
  ///
  /// It is created independently from [createDevicesBloc] so that a failure in
  /// one list never blocks the other.
  SupportRequestsBloc createSupportRequestsBloc() => SupportRequestsBloc(
    loadSupportRequests: loadSupportRequests,
    assignSupportRequest: assignSupportRequest,
  )..add(const SupportRequestsRequested());
}
