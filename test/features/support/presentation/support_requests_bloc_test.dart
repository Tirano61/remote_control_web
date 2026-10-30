import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/support/data/repositories/support_request_repository_impl.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_web/features/support/domain/usecases/assign_support_request.dart';
import 'package:remote_control_web/features/support/domain/usecases/load_support_requests.dart';
import 'package:remote_control_web/features/support/presentation/bloc/support_requests/support_requests_bloc.dart';

import '../../../support/console_test_doubles.dart';

void main() {
  late FakeSupportRequestRepository repository;

  SupportRequestsBloc buildBloc() => SupportRequestsBloc(
    loadSupportRequests: LoadSupportRequests(repository: repository),
    assignSupportRequest: AssignSupportRequest(repository: repository),
  );

  Future<SupportRequestsLoaded> loadedAfter(
    SupportRequestsBloc bloc,
    bool Function(SupportRequestsLoaded state) predicate,
  ) async =>
      await bloc.stream.firstWhere(
            (state) => state is SupportRequestsLoaded && predicate(state),
          )
          as SupportRequestsLoaded;

  setUp(() {
    repository = FakeSupportRequestRepository();
  });

  group('load', () {
    test('starts in SupportRequestsInitial and loads nothing on its own', () async {
      final bloc = buildBloc();

      expect(bloc.state, const SupportRequestsInitial());
      expect(repository.loadCount, 0);

      await bloc.close();
    });

    test('a WAITING request is visible in the queue', () async {
      repository.requests = [buildSupportRequest()];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      final loaded = await loadedAfter(bloc, (state) => !state.isRefreshing);

      expect(loaded.waiting, hasLength(1));
      expect(loaded.waiting.single.status, SupportRequestStatus.waiting);
      expect(loaded.waiting.single.device!.publicId, '132-491-092');

      await bloc.close();
    });

    test('the whole queue is asked for, so every bucket can be shown', () async {
      repository.requests = [
        buildSupportRequest(id: 'w'),
        buildSupportRequest(
          id: 'a',
          status: SupportRequestStatus.assigned,
          technician: technicianId,
        ),
        buildSupportRequest(id: 'r', status: SupportRequestStatus.rejected),
      ];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      final loaded = await loadedAfter(bloc, (state) => !state.isRefreshing);

      expect(loaded.waiting.map((r) => r.id), ['w']);
      expect(loaded.assignedTo(technicianId).map((r) => r.id), ['a']);
      expect(loaded.history.map((r) => r.id), ['r']);

      await bloc.close();
    });

    test('a failed first load ends in SupportRequestsFailure', () async {
      repository.loadFailure = const NetworkFailure();
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      final state = await bloc.stream.firstWhere(
        (s) => s is SupportRequestsFailure,
      );

      expect((state as SupportRequestsFailure).failure, isA<NetworkFailure>());

      await bloc.close();
    });

    test('a 401 surfaces as an AuthFailure the console can react to', () async {
      repository.loadFailure = const AuthFailure();
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      final state = await bloc.stream.firstWhere(
        (s) => s is SupportRequestsFailure,
      );

      expect(state.lastFailure, isA<AuthFailure>());

      await bloc.close();
    });
  });

  group('assign', () {
    test('WAITING becomes ASSIGNED and the notice is shown', () async {
      repository.requests = [buildSupportRequest()];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      bloc.add(const SupportRequestAssignRequested(requestId));
      final loaded = await loadedAfter(bloc, (state) => state.notice != null);

      expect(repository.assignedIds, [requestId]);
      expect(loaded.waiting, isEmpty);
      expect(loaded.assignedTo(technicianId), hasLength(1));
      expect(
        loaded.assignedTo(technicianId).single.status,
        SupportRequestStatus.assigned,
      );
      expect(loaded.notice, kAssignSucceededNotice);
      expect(loaded.failure, isNull);
      expect(loaded.assigningRequestId, isNull);

      await bloc.close();
    });

    test('the ASSIGNED row reads as waiting for the user of the tablet', () async {
      repository.requests = [buildSupportRequest()];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);
      bloc.add(const SupportRequestAssignRequested(requestId));
      final loaded = await loadedAfter(bloc, (state) => state.notice != null);

      expect(
        loaded.assignedTo(technicianId).single.status.description,
        'Esperando autorización del usuario',
      );

      await bloc.close();
    });

    test('a second click while the first assign is in flight is ignored', () async {
      repository.requests = [buildSupportRequest()];
      final gate = Completer<void>();
      repository.assignGate = gate.future;
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      bloc.add(const SupportRequestAssignRequested(requestId));
      await loadedAfter(bloc, (state) => state.isAssigning);

      // Double click, and a click on a different row, while in flight.
      bloc.add(const SupportRequestAssignRequested(requestId));
      bloc.add(const SupportRequestAssignRequested('another-id'));
      await Future<void>.delayed(Duration.zero);

      gate.complete();
      await loadedAfter(bloc, (state) => !state.isAssigning);

      expect(repository.assignedIds, [requestId]);

      await bloc.close();
    });

    test('the in-flight request is identified so only its button spins', () async {
      repository.requests = [
        buildSupportRequest(id: 'first'),
        buildSupportRequest(id: 'second'),
      ];
      final gate = Completer<void>();
      repository.assignGate = gate.future;
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      bloc.add(const SupportRequestAssignRequested('second'));
      final busy = await loadedAfter(bloc, (state) => state.isAssigning);

      expect(busy.isAssigningRequest('second'), isTrue);
      expect(busy.isAssigningRequest('first'), isFalse);

      gate.complete();
      await loadedAfter(bloc, (state) => !state.isAssigning);
      await bloc.close();
    });

    test('409 reports the conflict and reloads the queue', () async {
      repository.requests = [buildSupportRequest()];
      repository.assignFailure = const ConflictFailure(kAssignConflictMessage);
      // Another technician got there first: the backend now answers ASSIGNED.
      repository.requestsAfterFirstLoad = [
        buildSupportRequest(
          status: SupportRequestStatus.assigned,
          technician: 'somebody-else',
        ),
      ];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);
      expect(repository.loadCount, 1);

      bloc.add(const SupportRequestAssignRequested(requestId));
      // The conflict is reported first, then the re-read replaces the queue;
      // wait for the state that carries both.
      final loaded = await loadedAfter(
        bloc,
        (state) =>
            state.failure != null &&
            !state.isAssigning &&
            state.requests.single.status == SupportRequestStatus.assigned,
      );

      expect(loaded.failure, isA<ConflictFailure>());
      expect(loaded.failure!.message, kAssignConflictMessage);
      // A conflict must trigger a re-read: the queue is stale by definition.
      expect(repository.loadCount, 2);
      expect(loaded.waiting, isEmpty);
      expect(loaded.assignedTo(technicianId), isEmpty);
      expect(loaded.notice, isNull);

      await bloc.close();
    });

    test('a 403 does not clear the queue and is reported as such', () async {
      repository.requests = [buildSupportRequest()];
      repository.assignFailure = const ForbiddenFailure();
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      bloc.add(const SupportRequestAssignRequested(requestId));
      final loaded = await loadedAfter(bloc, (state) => state.failure != null);

      expect(loaded.failure, isA<ForbiddenFailure>());
      expect(loaded.failure, isNot(isA<AuthFailure>()));
      expect(loaded.waiting, hasLength(1));
      // No reload: the state did not move, only the permission was missing.
      expect(repository.loadCount, 1);

      await bloc.close();
    });

    test('a 401 during assign surfaces an AuthFailure', () async {
      repository.requests = [buildSupportRequest()];
      repository.assignFailure = const AuthFailure();
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      bloc.add(const SupportRequestAssignRequested(requestId));
      final loaded = await loadedAfter(bloc, (state) => state.failure != null);

      expect(loaded.lastFailure, isA<AuthFailure>());

      await bloc.close();
    });

    test('an offline device is not assignable from the UI', () async {
      repository.requests = [buildSupportRequest(isDeviceOnline: false)];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      final loaded = await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      final request = loaded.waiting.single;
      expect(request.isDeviceOnline, isFalse);
      expect(request.looksAssignable, isFalse);
      // The rule is still enforced by the backend, this only hides the button.
      expect(request.status.isAssignable, isTrue);

      await bloc.close();
    });
  });

  group('refresh', () {
    test('ASSIGNED becomes ACCEPTED after the tablet authorises', () async {
      repository.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.assigned,
          technician: technicianId,
          assignedAt: DateTime.utc(2026, 3, 11, 9, 31, 12),
        ),
      ];
      repository.requestsAfterFirstLoad = [
        buildSupportRequest(
          status: SupportRequestStatus.accepted,
          technician: technicianId,
          assignedAt: DateTime.utc(2026, 3, 11, 9, 31, 12),
          respondedAt: DateTime.utc(2026, 3, 11, 9, 31, 40),
        ),
      ];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      final assigned = await loadedAfter(bloc, (state) => state.requests.isNotEmpty);
      expect(
        assigned.assignedTo(technicianId).single.status,
        SupportRequestStatus.assigned,
      );

      bloc.add(const SupportRequestsRefreshRequested());
      final accepted = await loadedAfter(
        bloc,
        (state) =>
            !state.isRefreshing &&
            state.requests.single.status == SupportRequestStatus.accepted,
      );

      final request = accepted.assignedTo(technicianId).single;
      expect(request.status, SupportRequestStatus.accepted);
      expect(request.status.description, 'Usuario autorizó la asistencia');
      expect(request.isActive, isTrue);

      await bloc.close();
    });

    test('REJECTED moves the request to the history', () async {
      repository.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.assigned,
          technician: technicianId,
        ),
      ];
      repository.requestsAfterFirstLoad = [
        buildSupportRequest(
          status: SupportRequestStatus.rejected,
          technician: technicianId,
          respondedAt: DateTime.utc(2026, 3, 11, 9, 32),
          closedAt: DateTime.utc(2026, 3, 11, 9, 32),
        ),
      ];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      bloc.add(const SupportRequestsRefreshRequested());
      final rejected = await loadedAfter(
        bloc,
        (state) =>
            !state.isRefreshing &&
            state.requests.single.status == SupportRequestStatus.rejected,
      );

      expect(rejected.assignedTo(technicianId), isEmpty);
      expect(rejected.waiting, isEmpty);
      expect(rejected.history, hasLength(1));
      expect(
        rejected.history.single.status.description,
        'Usuario rechazó la asistencia',
      );
      expect(rejected.history.single.isTerminal, isTrue);

      await bloc.close();
    });

    test('CANCELLED and COMPLETED are terminal too', () async {
      repository.requests = [
        buildSupportRequest(id: 'c', status: SupportRequestStatus.cancelled),
        buildSupportRequest(id: 'd', status: SupportRequestStatus.completed),
      ];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      final loaded = await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      expect(loaded.history, hasLength(2));
      expect(loaded.waiting, isEmpty);
      expect(
        loaded.history.map((r) => r.status.description),
        containsAll(['Solicitud cancelada', 'Asistencia finalizada']),
      );

      await bloc.close();
    });

    test('a failed refresh keeps the queue already on screen', () async {
      repository.requests = [buildSupportRequest()];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);

      repository.loadFailure = const NetworkFailure();
      bloc.add(const SupportRequestsRefreshRequested());
      final loaded = await loadedAfter(bloc, (state) => state.failure != null);

      expect(loaded.waiting, hasLength(1));
      expect(loaded.failure, isA<NetworkFailure>());
      expect(loaded.isRefreshing, isFalse);

      await bloc.close();
    });

    test('no polling: nothing is reloaded without an event', () async {
      repository.requests = [buildSupportRequest()];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repository.loadCount, 1);

      await bloc.close();
    });
  });

  group('coalesced refresh', () {
    final assigned = buildSupportRequest(
      status: SupportRequestStatus.assigned,
      technician: technicianId,
    );
    final accepted = buildSupportRequest(
      status: SupportRequestStatus.accepted,
      technician: technicianId,
    );

    /// Lets the event loop drain, so every pass of the reload loop that can
    /// run does run.
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// A bloc whose first load already answered [assigned]; the next GET is
    /// held by the returned gate.
    Future<(SupportRequestsBloc, Completer<void>)> loadedBloc() async {
      repository.requests = [assigned];
      final bloc = buildBloc();
      bloc.add(const SupportRequestsRequested());
      await settle();
      expect(repository.loadCount, 1);
      final gate = Completer<void>();
      repository.loadGate = gate.future;
      return (bloc, gate);
    }

    SupportRequestsLoaded loaded(SupportRequestsBloc bloc) =>
        bloc.state as SupportRequestsLoaded;

    test('a refresh during a GET runs after it, never next to it', () async {
      final (bloc, gate) = await loadedBloc();

      // GET #1 reads the backend before the tablet answers...
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      // ...which commits ACCEPTED and asks for a reload meanwhile.
      repository.requests = [accepted];
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      expect(repository.loadCount, 2, reason: 'no GET next to the first one');

      gate.complete();
      await settle();

      // GET #1 answered ASSIGNED; GET #2 is what brings ACCEPTED in.
      expect(repository.loadCount, 3);
      expect(loaded(bloc).requests.single.status, SupportRequestStatus.accepted);
      expect(loaded(bloc).isRefreshing, isFalse);

      await bloc.close();
    });

    test('the queue keeps saying it refreshes between both GETs', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();

      final second = Completer<void>();
      gate.complete();
      repository.loadGate = second.future;
      await settle();

      // GET #1 answered, GET #2 is running: no flicker to "idle" in between.
      expect(repository.loadCount, 3);
      expect(loaded(bloc).isRefreshing, isTrue);

      second.complete();
      await settle();
      expect(loaded(bloc).isRefreshing, isFalse);

      await bloc.close();
    });

    test('a burst during one GET costs exactly one more GET', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();

      for (var i = 0; i < 4; i++) {
        bloc.add(const SupportRequestsRefreshRequested());
      }
      await settle();
      gate.complete();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The first load, GET #1 and a single GET #2 for the whole burst.
      expect(repository.loadCount, 1 + 2);

      await bloc.close();
    });

    test('a refresh during the follow-up GET is not lost either', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();

      final second = Completer<void>();
      gate.complete();
      repository.loadGate = second.future;
      await settle();
      expect(repository.loadCount, 3, reason: 'GET #2 is in flight');

      // A later, real change while GET #2 is still out.
      repository.requests = [accepted];
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      expect(repository.loadCount, 3);

      second.complete();
      await settle();

      expect(repository.loadCount, 4, reason: 'GET #3');
      expect(loaded(bloc).requests.single.status, SupportRequestStatus.accepted);

      await bloc.close();
    });

    test('the first load coalesces a refresh as well', () async {
      repository.requests = [assigned];
      final gate = Completer<void>();
      repository.loadGate = gate.future;
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await settle();
      repository.requests = [accepted];
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      expect(repository.loadCount, 1);

      gate.complete();
      await settle();

      expect(repository.loadCount, 2);
      expect(loaded(bloc).requests.single.status, SupportRequestStatus.accepted);

      await bloc.close();
    });

    test('a network error consumes the pending refresh, once', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();

      repository.loadFailure = const NetworkFailure();
      gate.complete();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // GET #1 failed, the pending GET #2 was tried and failed too, and
      // nothing tries again on its own: no retry loop, no backoff.
      expect(repository.loadCount, 3);
      expect(loaded(bloc).requests.single.status, SupportRequestStatus.assigned);
      expect(loaded(bloc).failure, isA<NetworkFailure>());
      expect(loaded(bloc).isRefreshing, isFalse);

      await bloc.close();
    });

    test('a network error without a pending refresh is not retried', () async {
      final (bloc, gate) = await loadedBloc();
      repository.loadFailure = const NetworkFailure();
      bloc.add(const SupportRequestsRefreshRequested());
      gate.complete();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(repository.loadCount, 2);
      expect(loaded(bloc).failure, isA<NetworkFailure>());

      await bloc.close();
    });

    test('a failed first load with a pending refresh shows the retry', () async {
      repository
        ..requests = [assigned]
        ..loadFailure = const NetworkFailure();
      final gate = Completer<void>();
      repository.loadGate = gate.future;
      final bloc = buildBloc();
      bloc.add(const SupportRequestsRequested());
      await settle();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();

      final states = <SupportRequestsState>[];
      final subscription = bloc.stream.listen(states.add);
      repository.loadFailure = null;
      gate.complete();
      await settle();

      // The first failure is not flashed while the retry is already running.
      expect(states.whereType<SupportRequestsFailure>(), isEmpty);
      expect(repository.loadCount, 2);
      expect(loaded(bloc).requests, hasLength(1));

      await subscription.cancel();
      await bloc.close();
    });

    test('a 401 drops the pending refresh: the session is ending', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();

      repository.loadFailure = const AuthFailure();
      gate.complete();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(repository.loadCount, 2, reason: 'no GET after the 401');
      expect(loaded(bloc).failure, isA<AuthFailure>());
      expect(loaded(bloc).isRefreshing, isFalse);

      // The guard is not left stuck: a new request is served normally.
      repository.loadFailure = null;
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      expect(repository.loadCount, 3);

      await bloc.close();
    });

    test('a discarded pending refresh is never run', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      bloc
        ..add(const SupportRequestsRefreshRequested())
        ..add(const SupportRequestsPendingRefreshDiscarded());
      await settle();

      gate.complete();
      await settle();

      expect(repository.loadCount, 2);

      await bloc.close();
    });

    test('a closed bloc runs no pending refresh', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      bloc.add(const SupportRequestsRefreshRequested());
      await settle();

      final closing = bloc.close();
      gate.complete();
      await closing;
      await settle();

      expect(repository.loadCount, 2);
    });

    test('a 409 during a GET in flight reloads once, after it', () async {
      repository.requests = [buildSupportRequest()];
      final bloc = buildBloc();
      bloc.add(const SupportRequestsRequested());
      await settle();
      final gate = Completer<void>();
      repository
        ..loadGate = gate.future
        ..assignFailure = const ConflictFailure();

      bloc.add(const SupportRequestsRefreshRequested());
      await settle();
      bloc.add(const SupportRequestAssignRequested(requestId));
      await settle();
      expect(repository.loadCount, 2, reason: 'the 409 reload waits its turn');

      gate.complete();
      await settle();

      expect(repository.loadCount, 3);
      expect(loaded(bloc).isRefreshing, isFalse);

      await bloc.close();
    });
  });

  group('notice', () {
    test('can be dismissed', () async {
      repository.requests = [buildSupportRequest()];
      final bloc = buildBloc();

      bloc.add(const SupportRequestsRequested());
      await loadedAfter(bloc, (state) => state.requests.isNotEmpty);
      bloc.add(const SupportRequestAssignRequested(requestId));
      await loadedAfter(bloc, (state) => state.notice != null);

      bloc.add(const SupportRequestsNoticeDismissed());
      final loaded = await loadedAfter(bloc, (state) => state.notice == null);

      expect(loaded.notice, isNull);
      expect(loaded.failure, isNull);

      await bloc.close();
    });
  });
}
