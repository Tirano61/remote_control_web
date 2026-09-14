import 'package:equatable/equatable.dart';

/// The `device` block embedded in a remote session response.
///
/// The contract exposes exactly these four fields here — it is a narrower
/// projection than the one carried by a support request, so it is deliberately
/// a type of its own instead of a shared "device" entity.
class RemoteSessionDevice extends Equatable {
  const RemoteSessionDevice({
    required this.id,
    required this.publicId,
    required this.isOnline,
    this.name,
  });

  /// Internal UUID.
  final String id;

  /// Human friendly identifier, e.g. `132-491-092`. Never authentication.
  final String publicId;

  /// Presence computed by the backend. The console never sets it.
  final bool isOnline;

  final String? name;

  String get displayName {
    final value = name?.trim();
    return (value == null || value.isEmpty) ? publicId : value;
  }

  @override
  List<Object?> get props => [id, publicId, isOnline, name];

  @override
  String toString() =>
      'RemoteSessionDevice(publicId: $publicId, isOnline: $isOnline)';
}
