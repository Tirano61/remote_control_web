import 'package:equatable/equatable.dart';

/// A device registered in the backend, as returned by `GET /devices`.
///
/// Only the fields documented in `docs/backend/ENDPOINTS.md` are modelled.
/// Every descriptive field is optional on creation (`POST /devices` accepts an
/// empty body), so it can legitimately come back as `null`.
class Device extends Equatable {
  const Device({
    required this.id,
    required this.publicId,
    required this.isActive,
    required this.isOnline,
    this.name,
    this.manufacturer,
    this.model,
    this.androidVersion,
    this.appVersion,
    this.createdAt,
    this.updatedAt,
  });

  /// Internal UUID. This is the id used by every other endpoint.
  final String id;

  /// Human friendly identifier, e.g. `132-491-092`.
  ///
  /// It is readable out loud by the user of the tablet and is **not** a
  /// credential: it authenticates nothing by itself.
  final String publicId;

  /// Persisted administrative state. Not to be confused with [isOnline].
  final bool isActive;

  /// Realtime presence, computed by the backend on every request.
  ///
  /// The web client never writes nor derives it.
  final bool isOnline;

  final String? name;
  final String? manufacturer;
  final String? model;
  final String? androidVersion;
  final String? appVersion;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Name to show in lists, falling back to the readable id.
  String get displayName {
    final value = name?.trim();
    return (value == null || value.isEmpty) ? publicId : value;
  }

  @override
  List<Object?> get props => [
    id,
    publicId,
    isActive,
    isOnline,
    name,
    manufacturer,
    model,
    androidVersion,
    appVersion,
    createdAt,
    updatedAt,
  ];

  @override
  String toString() =>
      'Device(publicId: $publicId, isOnline: $isOnline, isActive: $isActive)';
}
