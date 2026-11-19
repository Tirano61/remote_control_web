import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/devices/presentation/bloc/devices/devices_bloc.dart';
import 'package:remote_control_web/features/remote_session/presentation/presence/session_device_presence.dart';

import '../../../support/console_test_doubles.dart';
import '../../../support/remote_session_test_doubles.dart';

void main() {
  group('isSessionDeviceOnline', () {
    test('the device list answers when it has the device', () {
      final device = buildRemoteSessionDevice(isOnline: false);

      expect(
        isSessionDeviceOnline(device, DevicesLoaded(devices: [buildDevice()])),
        isTrue,
      );
      expect(
        isSessionDeviceOnline(
          buildRemoteSessionDevice(),
          DevicesLoaded(devices: [buildDevice(isOnline: false)]),
        ),
        isFalse,
      );
    });

    test('a refresh in flight keeps showing the last answer it applied', () {
      expect(
        isSessionDeviceOnline(
          buildRemoteSessionDevice(isOnline: false),
          DevicesLoaded(devices: [buildDevice()], isRefreshing: true),
        ),
        isTrue,
      );
    });

    test('without the device in the list, the session says it', () {
      final online = buildRemoteSessionDevice();
      final offline = buildRemoteSessionDevice(isOnline: false);

      for (final devices in <DevicesState>[
        const DevicesInitial(),
        const DevicesLoading(),
        const DevicesFailure(NetworkFailure()),
        DevicesLoaded(
          devices: [buildDevice(id: '9b2e4f10-0000-4000-8000-000000000001')],
        ),
      ]) {
        expect(isSessionDeviceOnline(online, devices), isTrue);
        expect(isSessionDeviceOnline(offline, devices), isFalse);
      }
    });

    test('only the id matches a device, never its readable id', () {
      expect(
        isSessionDeviceOnline(
          buildRemoteSessionDevice(isOnline: false),
          DevicesLoaded(
            devices: [buildDevice(id: '9b2e4f10-0000-4000-8000-000000000001')],
          ),
        ),
        isFalse,
      );
    });
  });
}
