import 'package:equatable/equatable.dart';

/// The `device` block embedded in the technician facing support request
/// responses.
///
/// It is a reduced projection of a device — the contract exposes exactly these
/// fields here — so it is deliberately not the `Device` entity of the devices
/// feature.
class SupportDevice extends Equatable {
  const SupportDevice({
    required this.id,
    required this.publicId,
    required this.isOnline,
    this.name,
    this.manufacturer,
    this.model,
  });

  final String id;
  final String publicId;

  /// Realtime presence computed by the backend. A request whose device is
  /// offline cannot be assigned.
  final bool isOnline;

  final String? name;
  final String? manufacturer;
  final String? model;

  String get displayName {
    final value = name?.trim();
    return (value == null || value.isEmpty) ? publicId : value;
  }

  @override
  List<Object?> get props => [id, publicId, isOnline, name, manufacturer, model];

  @override
  String toString() =>
      'SupportDevice(publicId: $publicId, isOnline: $isOnline)';
}
