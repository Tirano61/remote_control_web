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
}
