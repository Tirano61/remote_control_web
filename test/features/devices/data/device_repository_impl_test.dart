import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/devices/data/repositories/device_repository_impl.dart';
import 'package:remote_control_web/features/devices/domain/entities/device.dart';

import '../../../support/console_test_doubles.dart';

void main() {
  late FakeDevicesRemoteDataSource remote;
  late InMemoryUserTokenProvider tokenProvider;
  late DeviceRepositoryImpl repository;

  setUp(() {
    remote = FakeDevicesRemoteDataSource();
    tokenProvider = InMemoryUserTokenProvider('stored-user-jwt');
    repository = DeviceRepositoryImpl(
      remoteDataSource: remote,
      tokenProvider: tokenProvider,
    );
  });

  group('loadDevices', () {
    test('returns the devices sent by the backend', () async {
      remote.devices = [buildDevice(), buildDevice(id: 'b', isOnline: false)];

      final result = await repository.loadDevices();

      expect(result, isA<Success<List<Device>>>());
      final devices = (result as Success<List<Device>>).value;
      expect(devices, hasLength(2));
      expect(devices.first.isOnline, isTrue);
      expect(devices.last.isOnline, isFalse);
    });

    test('takes the User JWT from the provider, not from the caller', () async {
      await repository.loadDevices();

      expect(remote.fetchDevicesTokens, ['stored-user-jwt']);
      expect(tokenProvider.readCount, 1);
    });

    test('a missing token is an AuthFailure and reaches no network', () async {
      tokenProvider.token = null;

      final result = await repository.loadDevices();

      expect(result, isA<Failed<List<Device>>>());
      expect((result as Failed<List<Device>>).failure, isA<AuthFailure>());
      expect(remote.fetchDevicesTokens, isEmpty);
    });

    test('maps 401 to AuthFailure', () async {
      remote.error = const HttpApiException(401);

      final result = await repository.loadDevices();

      expect((result as Failed<List<Device>>).failure, isA<AuthFailure>());
    });

    test('maps 403 to ForbiddenFailure with a permissions message', () async {
      remote.error = const HttpApiException(403);

      final result = await repository.loadDevices();

      final failure = (result as Failed<List<Device>>).failure;
      expect(failure, isA<ForbiddenFailure>());
      expect(failure.message, contains('permisos'));
    });

    test('maps a transport error to NetworkFailure', () async {
      remote.error = const NetworkApiException();

      final result = await repository.loadDevices();

      expect((result as Failed<List<Device>>).failure, isA<NetworkFailure>());
    });

    test('maps 500 to ServerFailure', () async {
      remote.error = const HttpApiException(500);

      final result = await repository.loadDevices();

      expect((result as Failed<List<Device>>).failure, isA<ServerFailure>());
    });

    test('maps an unreadable body to UnexpectedFailure', () async {
      remote.error = const MalformedResponseApiException();

      final result = await repository.loadDevices();

      expect((result as Failed<List<Device>>).failure, isA<UnexpectedFailure>());
    });

    test('the raw transport error never reaches the failure message', () async {
      remote.error = const HttpApiException(500);

      final result = await repository.loadDevices();

      final failure = (result as Failed<List<Device>>).failure;
      expect(failure.message, isNot(contains('HttpApiException')));
      expect(failure.message, isNot(contains('500')));
    });
  });

  group('loadDevice (prepared for a future device detail)', () {
    test('returns the requested device', () async {
      remote.devices = [buildDevice()];

      final result = await repository.loadDevice(id: deviceId);

      expect((result as Success<Device>).value.publicId, '132-491-092');
      expect(remote.fetchDeviceIds, [deviceId]);
    });

    test('maps 404 to NotFoundFailure', () async {
      remote.error = const HttpApiException(404);

      final result = await repository.loadDevice(id: deviceId);

      expect((result as Failed<Device>).failure, isA<NotFoundFailure>());
    });
  });
}
