import '../../../../core/network/api_exception.dart';
import '../../domain/entities/remote_session.dart';
import '../../domain/entities/remote_session_device.dart';
import '../../domain/entities/remote_session_ended_by.dart';
import '../../domain/entities/remote_session_status.dart';
import '../../domain/entities/remote_session_technician.dart';

/// Maps the remote session payloads of `remote_control_backend` into domain
/// entities.
///
/// `POST /remote-sessions` and `POST /remote-sessions/:id/close` answer with
/// the session object directly; `GET /remote-sessions/current` wraps it in the
/// documented envelope.
class RemoteSessionDto {
  const RemoteSessionDto._();

  /// Key of the `GET /remote-sessions/current` envelope.
  static const String currentEnvelopeKey = 'remoteSession';

  /// Throws [MalformedResponseApiException] when a required field is missing
  /// or has an unexpected type.
  static RemoteSession fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final supportRequestId = json['supportRequestId'];
    final status = json['status'];
    final createdAt = _optionalDate(json['createdAt']);

    if (id is! String ||
        supportRequestId is! String ||
        status is! String ||
        createdAt == null) {
      throw const MalformedResponseApiException();
    }

    return RemoteSession(
      id: id,
      supportRequestId: supportRequestId,
      status: RemoteSessionStatus.fromWire(status),
      createdAt: createdAt,
      connectedAt: _optionalDate(json['connectedAt']),
      endedAt: _optionalDate(json['endedAt']),
      endedBy: _endedByFromJson(json['endedBy']),
      device: _deviceFromJson(json['device']),
      technician: _technicianFromJson(json['technician']),
    );
  }

  /// Reads the `{ "remoteSession": ... | null }` envelope.
  ///
  /// `null` is a documented, successful answer — it means the technician has no
  /// live session — so it is mapped to `null` and never to a failure. A missing
  /// key is a different thing: the response did not have the documented shape.
  static RemoteSession? currentFromJson(Map<String, dynamic> json) {
    if (!json.containsKey(currentEnvelopeKey)) {
      throw const MalformedResponseApiException();
    }
    final value = json[currentEnvelopeKey];
    if (value == null) return null;
    if (value is Map<String, dynamic>) return fromJson(value);
    if (value is Map) return fromJson(Map<String, dynamic>.from(value));
    throw const MalformedResponseApiException();
  }

  static RemoteSessionDevice? _deviceFromJson(dynamic value) {
    if (value == null) return null;
    if (value is! Map) throw const MalformedResponseApiException();
    final id = value['id'];
    final publicId = value['publicId'];
    final isOnline = value['isOnline'];
    if (id is! String || publicId is! String || isOnline is! bool) {
      throw const MalformedResponseApiException();
    }
    return RemoteSessionDevice(
      id: id,
      publicId: publicId,
      isOnline: isOnline,
      name: _optionalString(value['name']),
    );
  }

  static RemoteSessionTechnician? _technicianFromJson(dynamic value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String) return null;
    final name = value['name'];
    return RemoteSessionTechnician(id: id, name: name is String ? name : '');
  }

  static RemoteSessionEndedBy? _endedByFromJson(dynamic value) =>
      value is String ? RemoteSessionEndedBy.fromWire(value) : null;

  static String? _optionalString(dynamic value) =>
      value is String ? value : null;

  static DateTime? _optionalDate(dynamic value) =>
      value is String ? DateTime.tryParse(value) : null;
}
