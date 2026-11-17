import '../../domain/entities/device_presence_updated_notice.dart';
import '../realtime_contract.dart';

/// Parses the `device:presence-updated` payload: `{ "deviceId": "..." }`.
///
/// Same rules as the support request notices: a payload without a usable
/// `deviceId` is dropped, never thrown on, and any other field — an
/// `isOnline` included, should one ever appear — is ignored, so nothing the
/// event carries can ever become state.
class DevicePresenceUpdatedNoticeDto {
  const DevicePresenceUpdatedNoticeDto._();

  static DevicePresenceUpdatedNotice? fromEvent(Object? data) {
    if (data is! Map<Object?, Object?>) return null;
    final id = data[TechnicianRealtimeContract.deviceIdField];
    if (id is! String || id.trim().isEmpty) return null;
    return DevicePresenceUpdatedNotice(deviceId: id);
  }
}
