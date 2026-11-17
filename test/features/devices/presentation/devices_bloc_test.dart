import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/devices/domain/usecases/load_devices.dart';
import 'package:remote_control_web/features/devices/presentation/bloc/devices/devices_bloc.dart';

import '../../../support/console_test_doubles.dart';

void main() {
  late FakeDeviceRepository repository;

  DevicesBloc buildBloc() =>
      DevicesBloc(loadDevices: LoadDevices(repository: repository));

  setUp(() {
    repository = FakeDeviceRepository();
  });

  test('starts in DevicesInitial and loads nothing on its own', () async {
    final bloc = buildBloc();

    expect(bloc.state, const DevicesInitial());
    expect(repository.loadCount, 0);

    await bloc.close();
  });

  test('a successful load exposes the devices', () async {
    repository.devices = [buildDevice(), buildDevice(id: 'b', isOnline: false)];
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    final state = await bloc.stream.firstWhere((s) => s is DevicesLoaded);

    final loaded = state as DevicesLoaded;
    expect(loaded.devices, hasLength(2));
    expect(loaded.isRefreshing, isFalse);
    expect(loaded.refreshFailure, isNull);

    await bloc.close();
  });

  test('online/offline comes straight from the backend rows', () async {
    repository.devices = [
      buildDevice(id: 'on', isOnline: true),
      buildDevice(id: 'off', isOnline: false),
    ];
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    final loaded =
        await bloc.stream.firstWhere((s) => s is DevicesLoaded)
            as DevicesLoaded;

    expect(loaded.devices.first.isOnline, isTrue);
    expect(loaded.devices.last.isOnline, isFalse);
    expect(loaded.onlineCount, 1);

    await bloc.close();
  });

  test('emits Loading then Loaded', () async {
    repository.devices = [buildDevice()];
    final bloc = buildBloc();
    final states = <DevicesState>[];
    final subscription = bloc.stream.listen(states.add);

    bloc.add(const DevicesRequested());
    await bloc.stream.firstWhere((s) => s is DevicesLoaded);

    expect(states.first, isA<DevicesLoading>());
    expect(states.last, isA<DevicesLoaded>());

    await subscription.cancel();
    await bloc.close();
  });

  test('a network failure on the first load ends in DevicesFailure', () async {
    repository.failure = const NetworkFailure();
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    final state = await bloc.stream.firstWhere((s) => s is DevicesFailure);

    expect((state as DevicesFailure).failure, isA<NetworkFailure>());
    expect(state.lastFailure, isA<NetworkFailure>());

    await bloc.close();
  });

  test('a 401 surfaces as an AuthFailure the console can react to', () async {
    repository.failure = const AuthFailure();
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    final state = await bloc.stream.firstWhere((s) => s is DevicesFailure);

    expect(state.lastFailure, isA<AuthFailure>());

    await bloc.close();
  });

  test('manual refresh reloads through the repository', () async {
    repository.devices = [buildDevice()];
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    await bloc.stream.firstWhere((s) => s is DevicesLoaded);

    repository.devices = [buildDevice(), buildDevice(id: 'b')];
    bloc.add(const DevicesRefreshRequested());
    final refreshed = await bloc.stream.firstWhere(
      (s) => s is DevicesLoaded && s.devices.length == 2,
    );

    expect(repository.loadCount, 2);
    expect((refreshed as DevicesLoaded).devices, hasLength(2));

    await bloc.close();
  });

  test('refreshing marks the loaded state as busy meanwhile', () async {
    repository.devices = [buildDevice()];
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    await bloc.stream.firstWhere((s) => s is DevicesLoaded);

    final states = <DevicesState>[];
    final subscription = bloc.stream.listen(states.add);
    bloc.add(const DevicesRefreshRequested());
    await bloc.stream.firstWhere(
      (s) => s is DevicesLoaded && !s.isRefreshing,
    );

    expect(
      states.any((s) => s is DevicesLoaded && s.isRefreshing),
      isTrue,
      reason: 'the refresh button must be able to show progress',
    );

    await subscription.cancel();
    await bloc.close();
  });

  test('a failed refresh keeps the rows already on screen', () async {
    repository.devices = [buildDevice()];
    repository.failureAfterFirstLoad = const NetworkFailure();
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    await bloc.stream.firstWhere((s) => s is DevicesLoaded);

    bloc.add(const DevicesRefreshRequested());
    final state = await bloc.stream.firstWhere(
      (s) => s is DevicesLoaded && s.refreshFailure != null,
    );

    final loaded = state as DevicesLoaded;
    expect(loaded.devices, hasLength(1));
    expect(loaded.refreshFailure, isA<NetworkFailure>());
    expect(loaded.isRefreshing, isFalse);

    await bloc.close();
  });

  test('no polling: nothing is reloaded without an event', () async {
    repository.devices = [buildDevice()];
    final bloc = buildBloc();

    bloc.add(const DevicesRequested());
    await bloc.stream.firstWhere((s) => s is DevicesLoaded);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(repository.loadCount, 1);

    await bloc.close();
  });

  group('coalesced refresh', () {
    /// Lets the event loop drain, so every pass of the reload loop that can
    /// run does run.
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// A bloc whose first load already answered the tablet as [isOnline]; the
    /// next GET is held by the returned gate.
    Future<(DevicesBloc, Completer<void>)> loadedBloc({
      bool isOnline = false,
    }) async {
      repository.devices = [buildDevice(isOnline: isOnline)];
      final bloc = buildBloc();
      bloc.add(const DevicesRequested());
      await settle();
      expect(repository.loadCount, 1);
      final gate = Completer<void>();
      repository.loadGate = gate.future;
      return (bloc, gate);
    }

    DevicesLoaded loaded(DevicesBloc bloc) => bloc.state as DevicesLoaded;

    test('a refresh during a GET is not dropped: it runs after it', () async {
      final (bloc, gate) = await loadedBloc();

      // GET #1 reads the presence registry while the tablet is still OFFLINE.
      bloc.add(const DevicesRefreshRequested());
      await settle();
      // The tablet connects; device:presence-updated asks for a reload while
      // GET #1 is still on its way.
      repository.devices = [buildDevice(isOnline: true)];
      bloc.add(const DevicesRefreshRequested());
      await settle();
      expect(repository.loadCount, 2, reason: 'no GET next to the first one');

      gate.complete();
      await settle();

      // GET #1 answered the stale OFFLINE; GET #2 is what brings ONLINE in.
      expect(repository.loadCount, 3);
      expect(loaded(bloc).devices.single.isOnline, isTrue);
      expect(loaded(bloc).isRefreshing, isFalse);

      await bloc.close();
    });

    test('OFFLINE -> ONLINE -> OFFLINE with slow responses ends OFFLINE', () async {
      final (bloc, firstGate) = await loadedBloc();

      // ONLINE, and the GET that reads it is slow.
      repository.devices = [buildDevice(isOnline: true)];
      bloc.add(const DevicesRefreshRequested());
      await settle();

      // OFFLINE again before that GET came back, with its own slow GET.
      repository.devices = [buildDevice(isOnline: false)];
      final secondGate = Completer<void>();
      repository.loadGate = secondGate.future;
      bloc.add(const DevicesRefreshRequested());
      await settle();
      expect(repository.loadCount, 2);

      firstGate.complete();
      await settle();
      // The ONLINE answer is shown for what it was, and the console keeps
      // saying it is refreshing, because a newer read is on its way.
      expect(repository.loadCount, 3);
      expect(loaded(bloc).devices.single.isOnline, isTrue);
      expect(loaded(bloc).isRefreshing, isTrue);

      secondGate.complete();
      await settle();

      // The last effective presence wins; nothing older comes after it.
      expect(loaded(bloc).devices.single.isOnline, isFalse);
      expect(loaded(bloc).isRefreshing, isFalse);
      expect(repository.loadCount, 3);

      await bloc.close();
    });

    test('a burst during one GET costs exactly one more GET', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const DevicesRefreshRequested());
      await settle();

      for (var i = 0; i < 5; i++) {
        bloc.add(const DevicesRefreshRequested());
      }
      await settle();
      gate.complete();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The first load, GET #1 and a single GET #2 for the whole burst: a
      // flag, never a queue.
      expect(repository.loadCount, 1 + 2);
      expect(loaded(bloc).devices, hasLength(1));

      await bloc.close();
    });

    test('a refresh asked during the first load is not lost either', () async {
      final gate = Completer<void>();
      repository
        ..devices = [buildDevice(isOnline: false)]
        ..loadGate = gate.future;
      final bloc = buildBloc();

      bloc.add(const DevicesRequested());
      await settle();
      repository.devices = [buildDevice(isOnline: true)];
      bloc.add(const DevicesRefreshRequested());
      await settle();
      expect(repository.loadCount, 1);

      gate.complete();
      await settle();

      expect(repository.loadCount, 2);
      expect(loaded(bloc).devices.single.isOnline, isTrue);

      await bloc.close();
    });

    test('a network error consumes the pending refresh, once', () async {
      final (bloc, gate) = await loadedBloc();
      repository.failureAfterFirstLoad = const NetworkFailure();
      bloc.add(const DevicesRefreshRequested());
      await settle();
      bloc.add(const DevicesRefreshRequested());
      await settle();

      gate.complete();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // GET #1 failed, the pending GET #2 was tried and failed too, and
      // nothing retries on its own after that.
      expect(repository.loadCount, 3);
      expect(loaded(bloc).refreshFailure, isA<NetworkFailure>());
      expect(loaded(bloc).isRefreshing, isFalse);
      expect(loaded(bloc).devices, hasLength(1));

      await bloc.close();
    });

    test('a 401 drops the pending refresh: the session is ending', () async {
      final (bloc, gate) = await loadedBloc();
      repository.failureAfterFirstLoad = const AuthFailure();
      bloc.add(const DevicesRefreshRequested());
      await settle();
      bloc.add(const DevicesRefreshRequested());
      await settle();

      gate.complete();
      await settle();

      expect(repository.loadCount, 2);
      expect(loaded(bloc).refreshFailure, isA<AuthFailure>());
      expect(loaded(bloc).isRefreshing, isFalse);

      await bloc.close();
    });

    test('a discarded pending refresh is never run', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const DevicesRefreshRequested());
      await settle();
      bloc
        ..add(const DevicesRefreshRequested())
        ..add(const DevicesPendingRefreshDiscarded());
      await settle();

      gate.complete();
      await settle();

      expect(repository.loadCount, 2);
      expect(loaded(bloc).isRefreshing, isFalse);

      await bloc.close();
    });

    test('a closed bloc runs no pending refresh', () async {
      final (bloc, gate) = await loadedBloc();
      bloc.add(const DevicesRefreshRequested());
      await settle();
      bloc.add(const DevicesRefreshRequested());
      await settle();

      final closing = bloc.close();
      gate.complete();
      await closing;
      await settle();

      expect(repository.loadCount, 2);
    });
  });
}
