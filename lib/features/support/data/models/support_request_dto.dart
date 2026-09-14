import '../../../../core/network/api_exception.dart';
import '../../domain/entities/support_device.dart';
import '../../domain/entities/support_request.dart';
import '../../domain/entities/support_request_status.dart';
import '../../domain/entities/support_technician.dart';

/// Maps the support request payloads of `remote_control_backend` into domain
/// entities.
///
/// `GET /support-requests`, `GET /support-requests/:id` and
/// `POST /support-requests/:id/assign` all answer with the same object; the
/// `device` block only exists in these technician facing responses.
class SupportRequestDto {
  const SupportRequestDto._();

  /// Throws [MalformedResponseApiException] when a required field is missing
  /// or has an unexpected type.
  static SupportRequest fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final deviceId = json['deviceId'];
    final status = json['status'];
    final createdAt = _optionalDate(json['createdAt']);

    if (id is! String ||
        deviceId is! String ||
        status is! String ||
        createdAt == null) {
      throw const MalformedResponseApiException();
    }

    return SupportRequest(
      id: id,
      deviceId: deviceId,
      status: SupportRequestStatus.fromWire(status),
      createdAt: createdAt,
      technicianId: _optionalString(json['technicianId']),
      technician: _technicianFromJson(json['technician']),
      device: _deviceFromJson(json['device']),
      assignedAt: _optionalDate(json['assignedAt']),
      respondedAt: _optionalDate(json['respondedAt']),
      closedAt: _optionalDate(json['closedAt']),
    );
  }

  static List<SupportRequest> listFromJson(List<Map<String, dynamic>> json) =>
      json.map(fromJson).toList(growable: false);

  static SupportTechnician? _technicianFromJson(dynamic value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    if (id is! String) return null;
    return SupportTechnician(id: id, name: name is String ? name : '');
  }

  static SupportDevice? _deviceFromJson(dynamic value) {
    if (value is! Map) return null;
    final id = value['id'];
    final publicId = value['publicId'];
    final isOnline = value['isOnline'];
    if (id is! String || publicId is! String || isOnline is! bool) {
      throw const MalformedResponseApiException();
    }
    return SupportDevice(
      id: id,
      publicId: publicId,
      isOnline: isOnline,
      name: _optionalString(value['name']),
      manufacturer: _optionalString(value['manufacturer']),
      model: _optionalString(value['model']),
    );
  }

  static String? _optionalString(dynamic value) =>
      value is String ? value : null;

  static DateTime? _optionalDate(dynamic value) =>
      value is String ? DateTime.tryParse(value) : null;
}
