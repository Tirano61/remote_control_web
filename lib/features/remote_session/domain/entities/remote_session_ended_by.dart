import 'package:equatable/equatable.dart';

/// The `RemoteSessionEndedBy` enum of the backend, typed.
///
/// `SYSTEM` is documented as reserved: no backend code path writes it today,
/// but it is part of the contract and is modelled here.
class RemoteSessionEndedBy extends Equatable {
  const RemoteSessionEndedBy._(this.wireValue);

  factory RemoteSessionEndedBy.fromWire(String raw) {
    final normalized = raw.trim().toUpperCase();
    for (final value in known) {
      if (value.wireValue == normalized) return value;
    }
    return RemoteSessionEndedBy._(normalized);
  }

  /// Closed through `POST /remote-sessions/:id/close`.
  static const RemoteSessionEndedBy technician = RemoteSessionEndedBy._(
    'TECHNICIAN',
  );

  /// Closed through `POST /device/remote-sessions/:id/close`.
  static const RemoteSessionEndedBy device = RemoteSessionEndedBy._('DEVICE');

  /// Reserved. No code path writes it today.
  static const RemoteSessionEndedBy system = RemoteSessionEndedBy._('SYSTEM');

  static const List<RemoteSessionEndedBy> known = [technician, device, system];

  final String wireValue;

  bool get isKnown => known.contains(this);

  String get label => switch (wireValue) {
    'TECHNICIAN' => 'Finalizada por el técnico',
    'DEVICE' => 'Finalizada desde el dispositivo',
    'SYSTEM' => 'Finalizada por el sistema',
    _ => 'Finalizada',
  };

  @override
  List<Object?> get props => [wireValue];

  @override
  String toString() => 'RemoteSessionEndedBy($wireValue)';
}
