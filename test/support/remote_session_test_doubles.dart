import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/features/remote_session/data/datasources/remote_sessions_remote_data_source.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_device.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_technician.dart';
import 'package:remote_control_web/features/remote_session/domain/repositories/remote_session_repository.dart';

import 'console_test_doubles.dart';

const String remoteSessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';

RemoteSessionDevice buildRemoteSessionDevice({
  String id = deviceId,
  String publicId = '132-491-092',
  String? name = 'Tablet Prueba',
  bool isOnline = true,
}) => RemoteSessionDevice(
  id: id,
  publicId: publicId,
  name: name,
  isOnline: isOnline,
);

RemoteSession buildRemoteSession({
  String id = remoteSessionId,
  String supportRequestId = requestId,
  RemoteSessionStatus? status,
  DateTime? createdAt,
  DateTime? connectedAt,
  DateTime? endedAt,
  RemoteSessionEndedBy? endedBy,
  RemoteSessionDevice? device,
  bool isDeviceOnline = true,
}) => RemoteSession(
  id: id,
  supportRequestId: supportRequestId,
  status: status ?? RemoteSessionStatus.connecting,
  createdAt: createdAt ?? DateTime.utc(2026, 3, 11, 9, 33, 41),
  connectedAt: connectedAt,
  endedAt: endedAt,
  endedBy: endedBy,
  device: device ?? buildRemoteSessionDevice(isOnline: isDeviceOnline),
  technician: const RemoteSessionTechnician(
    id: technicianId,
    name: 'Ana Torres',
  ),
);

/// Scripted [RemoteSessionRepository].
///
/// The live session is modelled the way the backend does it: a single value
/// that `GET /remote-sessions/current` answers with, which create and close
/// change.
class FakeRemoteSessionRepository implements RemoteSessionRepository {
  /// What `GET /remote-sessions/current` answers.
  RemoteSession? current;

  /// Session returned by a successful `POST /remote-sessions`.
  RemoteSession? createResponse;

  Failure? currentFailure;
  Failure? createFailure;
  Failure? closeFailure;

  /// Applied instead of [currentFailure] from the second read onwards, which is
  /// how "the retry succeeds" is scripted.
  Failure? currentFailureAfterFirstRead;
  bool _read = false;

  /// Keeps a call in flight so a second click can be attempted meanwhile.
  Future<void>? createGate;
  Future<void>? closeGate;

  /// Set when the backend must behave as if the session had already been
  /// closed by the tablet: create/close fail, and `current` is what it is.
  int currentCount = 0;
  final List<String> createdSupportRequestIds = [];
  final List<String> closedIds = [];

  @override
  Future<Result<RemoteSession>> create({
    required String supportRequestId,
  }) async {
    createdSupportRequestIds.add(supportRequestId);
    final gate = createGate;
    if (gate != null) await gate;
    final failure = createFailure;
    if (failure != null) return Failed(failure);
    final created =
        createResponse ?? buildRemoteSession(supportRequestId: supportRequestId);
    current = created;
    return Success(created);
  }

  @override
  Future<Result<RemoteSession?>> loadCurrent() async {
    currentCount++;
    final failure = _read ? currentFailureAfterFirstRead ?? currentFailure : currentFailure;
    _read = true;
    if (failure != null) return Failed(failure);
    return Success(current);
  }

  @override
  Future<Result<RemoteSession>> close({required String id}) async {
    closedIds.add(id);
    final gate = closeGate;
    if (gate != null) await gate;
    final failure = closeFailure;
    if (failure != null) return Failed(failure);
    final closed = buildRemoteSession(
      id: id,
      status: RemoteSessionStatus.closed,
      endedAt: DateTime.utc(2026, 3, 11, 9, 40),
      endedBy: RemoteSessionEndedBy.technician,
    );
    current = null;
    return Success(closed);
  }
}

/// Scripted [RemoteSessionsRemoteDataSource], for repository level tests.
class FakeRemoteSessionsRemoteDataSource
    implements RemoteSessionsRemoteDataSource {
  RemoteSession? current;
  RemoteSession? createResponse;
  RemoteSession? closeResponse;

  Object? createError;
  Object? currentError;
  Object? closeError;

  final List<({String supportRequestId, String token})> createCalls = [];
  final List<String> currentTokens = [];
  final List<({String id, String token})> closeCalls = [];

  @override
  Future<RemoteSession> create({
    required String supportRequestId,
    required String token,
  }) async {
    createCalls.add((supportRequestId: supportRequestId, token: token));
    final error = createError;
    if (error != null) throw error;
    return createResponse ?? buildRemoteSession();
  }

  @override
  Future<RemoteSession?> fetchCurrent({required String token}) async {
    currentTokens.add(token);
    final error = currentError;
    if (error != null) throw error;
    return current;
  }

  @override
  Future<RemoteSession> close({
    required String id,
    required String token,
  }) async {
    closeCalls.add((id: id, token: token));
    final error = closeError;
    if (error != null) throw error;
    return closeResponse ??
        buildRemoteSession(
          id: id,
          status: RemoteSessionStatus.closed,
          endedBy: RemoteSessionEndedBy.technician,
        );
  }
}
