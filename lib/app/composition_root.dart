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
import '../features/remote_session/data/datasources/remote_sessions_remote_data_source.dart';
import '../features/remote_session/data/repositories/remote_session_repository_impl.dart';
import '../features/remote_session/domain/repositories/remote_session_repository.dart';
import '../features/remote_session/domain/usecases/activate_remote_session.dart';
import '../features/remote_session/domain/usecases/close_remote_session.dart';
import '../features/remote_session/domain/usecases/create_remote_session.dart';
import '../features/remote_session/domain/usecases/load_current_remote_session.dart';
import '../features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import '../features/signaling/data/technician_signaling_client_impl.dart';
import '../features/signaling/domain/client/technician_signaling_client.dart';
import '../features/support/data/datasources/support_remote_data_source.dart';
import '../features/support/data/repositories/support_request_repository_impl.dart';
import '../features/support/domain/repositories/support_request_repository.dart';
import '../features/support/domain/usecases/assign_support_request.dart';
import '../features/support/domain/usecases/load_support_requests.dart';
import '../features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import '../features/technician_realtime/data/technician_realtime_client_impl.dart';
import '../features/technician_realtime/domain/client/technician_realtime_client.dart';
import '../features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import '../features/webrtc/data/flutter_webrtc_peer_client.dart';
import '../features/webrtc/domain/client/webrtc_peer_client.dart';
import '../features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import '../features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import 'console/technician_console_coordinator.dart';

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
    required this.remoteSessionRepository,
    required this.technicianRealtimeClient,
    required this.technicianSignalingClient,
    required this.webRtcPeerClient,
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

    // The single Socket.IO connection of the application. It is built once and
    // handed out under two ports — realtime and signaling — so that domain
    // notifications, `remote-session:join` and the `webrtc:*` relay all travel
    // over one `/technicians` socket, exactly like one browser tab should.
    //
    // Socket.IO reads the same single token storage as REST, through the same
    // read-only port: the User JWT is never duplicated.
    final realtimeClient = TechnicianRealtimeClientImpl(
      config: resolvedConfig,
      tokenProvider: tokenProvider,
    );

    return AppDependencies(
      config: resolvedConfig,
      authRepository: AuthRepositoryImpl(
        remoteDataSource: AuthRemoteDataSourceImpl(apiClient: apiClient),
        tokenStorage: tokenStorage,
      ),
      technicianRealtimeClient: realtimeClient,
      technicianSignalingClient: TechnicianSignalingClientImpl(
        transport: realtimeClient,
      ),
      deviceRepository: DeviceRepositoryImpl(
        remoteDataSource: DevicesRemoteDataSourceImpl(apiClient: apiClient),
        tokenProvider: tokenProvider,
      ),
      supportRequestRepository: SupportRequestRepositoryImpl(
        remoteDataSource: SupportRemoteDataSourceImpl(apiClient: apiClient),
        tokenProvider: tokenProvider,
      ),
      remoteSessionRepository: RemoteSessionRepositoryImpl(
        remoteDataSource: RemoteSessionsRemoteDataSourceImpl(
          apiClient: apiClient,
        ),
        tokenProvider: tokenProvider,
      ),
      // The only implementation that knows `flutter_webrtc` exists.
      webRtcPeerClient: const FlutterWebRtcPeerClient(),
    );
  }

  final AppConfig config;
  final AuthRepository authRepository;
  final DeviceRepository deviceRepository;
  final SupportRequestRepository supportRequestRepository;
  final RemoteSessionRepository remoteSessionRepository;

  /// Single `/technicians` connection of the application.
  ///
  /// It is shared by the realtime BLoCs and the console coordinator, so there
  /// is exactly one socket and exactly one owner of its lifecycle.
  final TechnicianRealtimeClient technicianRealtimeClient;

  /// `webrtc:*` relay, over that same connection.
  ///
  /// This is the whole API the `RTCPeerConnection` layer needs: it knows
  /// nothing about Socket.IO, the BLoCs or the gateway.
  final TechnicianSignalingClient technicianSignalingClient;

  /// Builds the peer connections. Replaceable by a fake in tests, which is how
  /// the whole negotiation is exercised without a browser.
  final WebRtcPeerClient webRtcPeerClient;

  /// ICE configuration of every peer connection, built once from the single
  /// place it is configured: `WEBRTC_STUN_URL`, or nothing at all.
  late final WebRtcIceConfiguration iceConfiguration =
      WebRtcIceConfiguration.fromStunUrl(config.normalizedWebRtcStunUrl);

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

  late final LoadCurrentRemoteSession loadCurrentRemoteSession =
      LoadCurrentRemoteSession(repository: remoteSessionRepository);
  late final CreateRemoteSession createRemoteSession = CreateRemoteSession(
    repository: remoteSessionRepository,
  );
  late final ActivateRemoteSession activateRemoteSession =
      ActivateRemoteSession(repository: remoteSessionRepository);
  late final CloseRemoteSession closeRemoteSession = CloseRemoteSession(
    repository: remoteSessionRepository,
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

  /// Remote session of the signed-in technician.
  ///
  /// No first load is triggered here: the coordinator asks for it when the user
  /// session is authenticated, which is the only moment the answer means
  /// anything.
  /// No activation is triggered here either: the coordinator decides it, once
  /// the peer connection and the `control` channel are both usable.
  RemoteSessionBloc createRemoteSessionBloc() => RemoteSessionBloc(
    loadCurrentRemoteSession: loadCurrentRemoteSession,
    createRemoteSession: createRemoteSession,
    activateRemoteSession: activateRemoteSession,
    closeRemoteSession: closeRemoteSession,
  );

  TechnicianRealtimeBloc createTechnicianRealtimeBloc() =>
      TechnicianRealtimeBloc(client: technicianRealtimeClient);

  SignalingJoinBloc createSignalingJoinBloc() =>
      SignalingJoinBloc(client: technicianRealtimeClient);

  /// WebRTC negotiation of the console.
  ///
  /// No negotiation is triggered here: the coordinator asks for one when the
  /// session, the room and the tablet are all ready, which is the only moment
  /// an offer would reach anybody.
  WebRtcSessionBloc createWebRtcSessionBloc() => WebRtcSessionBloc(
    peerClient: webRtcPeerClient,
    signalingClient: technicianSignalingClient,
    iceConfiguration: iceConfiguration,
  );

  /// Rules that only exist at the level of the whole console.
  TechnicianConsoleCoordinator createConsoleCoordinator({
    required UserSessionBloc userSessionBloc,
    required RemoteSessionBloc remoteSessionBloc,
    required TechnicianRealtimeBloc technicianRealtimeBloc,
    required SignalingJoinBloc signalingJoinBloc,
    required SupportRequestsBloc supportRequestsBloc,
    required WebRtcSessionBloc webRtcSessionBloc,
  }) => TechnicianConsoleCoordinator(
    userSessionBloc: userSessionBloc,
    remoteSessionBloc: remoteSessionBloc,
    technicianRealtimeBloc: technicianRealtimeBloc,
    signalingJoinBloc: signalingJoinBloc,
    supportRequestsBloc: supportRequestsBloc,
    webRtcSessionBloc: webRtcSessionBloc,
    realtimeClient: technicianRealtimeClient,
    signalingClient: technicianSignalingClient,
  );
}
