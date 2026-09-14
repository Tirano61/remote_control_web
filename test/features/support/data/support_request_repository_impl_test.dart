import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/support/data/repositories/support_request_repository_impl.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';

import '../../../support/console_test_doubles.dart';

void main() {
  late FakeSupportRemoteDataSource remote;
  late InMemoryUserTokenProvider tokenProvider;
  late SupportRequestRepositoryImpl repository;

  setUp(() {
    remote = FakeSupportRemoteDataSource();
    tokenProvider = InMemoryUserTokenProvider('stored-user-jwt');
    repository = SupportRequestRepositoryImpl(
      remoteDataSource: remote,
      tokenProvider: tokenProvider,
    );
  });

  group('loadRequests', () {
    test('returns the queue sent by the backend', () async {
      remote.requests = [
        buildSupportRequest(),
        buildSupportRequest(id: 'b', status: SupportRequestStatus.accepted),
      ];

      final result = await repository.loadRequests();

      final requests = (result as Success<List<SupportRequest>>).value;
      expect(requests, hasLength(2));
      expect(requests.first.status, SupportRequestStatus.waiting);
    });

    test('takes the User JWT from the provider', () async {
      await repository.loadRequests();

      expect(remote.fetchCalls.single.token, 'stored-user-jwt');
    });

    test('forwards the status filter untouched', () async {
      await repository.loadRequests(status: SupportRequestStatus.waiting);

      expect(remote.fetchCalls.single.status, SupportRequestStatus.waiting);
    });

    test('sends no filter when none was asked for', () async {
      await repository.loadRequests();

      expect(remote.fetchCalls.single.status, isNull);
    });

    test('a missing token is an AuthFailure and reaches no network', () async {
      tokenProvider.token = null;

      final result = await repository.loadRequests();

      expect(
        (result as Failed<List<SupportRequest>>).failure,
        isA<AuthFailure>(),
      );
      expect(remote.fetchCalls, isEmpty);
    });

    test('maps 401 to AuthFailure', () async {
      remote.fetchError = const HttpApiException(401);

      final result = await repository.loadRequests();

      expect(
        (result as Failed<List<SupportRequest>>).failure,
        isA<AuthFailure>(),
      );
    });

    test('maps 403 to ForbiddenFailure', () async {
      remote.fetchError = const HttpApiException(403);

      final result = await repository.loadRequests();

      expect(
        (result as Failed<List<SupportRequest>>).failure,
        isA<ForbiddenFailure>(),
      );
    });

    test('maps a transport error to NetworkFailure', () async {
      remote.fetchError = const NetworkApiException();

      final result = await repository.loadRequests();

      expect(
        (result as Failed<List<SupportRequest>>).failure,
        isA<NetworkFailure>(),
      );
    });
  });

  group('assign', () {
    test('returns the updated request on success', () async {
      remote.requests = [buildSupportRequest()];

      final result = await repository.assign(id: requestId);

      final request = (result as Success<SupportRequest>).value;
      expect(request.status, SupportRequestStatus.assigned);
      expect(remote.assignedIds, [requestId]);
    });

    test('maps 409 to a ConflictFailure the user can understand', () async {
      remote.assignError = const HttpApiException(409);

      final result = await repository.assign(id: requestId);

      final failure = (result as Failed<SupportRequest>).failure;
      expect(failure, isA<ConflictFailure>());
      expect(failure.message, kAssignConflictMessage);
      // The reason (not WAITING / device offline / taken first) is not
      // distinguishable: the backend answers the same status code for all.
      expect(failure.message, isNot(contains('409')));
    });

    test('maps 404 to NotFoundFailure', () async {
      remote.assignError = const HttpApiException(404);

      final result = await repository.assign(id: requestId);

      final failure = (result as Failed<SupportRequest>).failure;
      expect(failure, isA<NotFoundFailure>());
      expect(failure.message, 'La solicitud ya no existe.');
    });

    test('maps 403 to ForbiddenFailure, never to AuthFailure', () async {
      remote.assignError = const HttpApiException(403);

      final result = await repository.assign(id: requestId);

      final failure = (result as Failed<SupportRequest>).failure;
      expect(failure, isA<ForbiddenFailure>());
      expect(failure, isNot(isA<AuthFailure>()));
    });

    test('maps 401 to AuthFailure', () async {
      remote.assignError = const HttpApiException(401);

      final result = await repository.assign(id: requestId);

      expect((result as Failed<SupportRequest>).failure, isA<AuthFailure>());
    });

    test('a missing token never sends the request', () async {
      tokenProvider.token = null;

      final result = await repository.assign(id: requestId);

      expect((result as Failed<SupportRequest>).failure, isA<AuthFailure>());
      expect(remote.assignedIds, isEmpty);
    });
  });

  group('loadRequest', () {
    test('returns one request', () async {
      remote.requests = [buildSupportRequest()];

      final result = await repository.loadRequest(id: requestId);

      expect((result as Success<SupportRequest>).value.id, requestId);
    });

    test('maps 404 to NotFoundFailure', () async {
      remote.fetchError = const HttpApiException(404);

      final result = await repository.loadRequest(id: requestId);

      expect((result as Failed<SupportRequest>).failure, isA<NotFoundFailure>());
    });
  });
}
