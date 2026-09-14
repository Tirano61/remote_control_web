import '../../../../core/network/api_exception.dart';
import '../../domain/entities/device.dart';

/// Maps the device payload of `remote_control_backend` into [Device].
///
/// The same object shape is returned by `POST /devices`, `GET /devices`,
/// `GET /devices/:id` and `PATCH /devices/:id`.
class DeviceDto {
  const DeviceDto._();

  /// Throws [MalformedResponseApiException] when a required field is missing
  /// or has an unexpected type.
  static Device fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final publicId = json['publicId'];
    final isActive = json['isActive'];
    final isOnline = json['isOnline'];

    if (id is! String ||
        publicId is! String ||
        isActive is! bool ||
        isOnline is! bool) {
      throw const MalformedResponseApiException();
    }

    return Device(
      id: id,
      publicId: publicId,
      isActive: isActive,
      isOnline: isOnline,
      name: _optionalString(json['name']),
      manufacturer: _optionalString(json['manufacturer']),
      model: _optionalString(json['model']),
      androidVersion: _optionalString(json['androidVersion']),
      appVersion: _optionalString(json['appVersion']),
      createdAt: _optionalDate(json['createdAt']),
      updatedAt: _optionalDate(json['updatedAt']),
    );
  }

  static List<Device> listFromJson(List<Map<String, dynamic>> json) =>
      json.map(fromJson).toList(growable: false);

  static String? _optionalString(dynamic value) => value is String ? value : null;

  static DateTime? _optionalDate(dynamic value) =>
      value is String ? DateTime.tryParse(value) : null;
}
