import 'package:equatable/equatable.dart';

/// The `SupportRequestStatus` enum of the backend, typed.
///
/// The contract asks clients to treat unknown future values defensively, so an
/// unrecognised status is preserved instead of crashing the console, and it
/// grants no action: it is neither assignable nor considered active.
class SupportRequestStatus extends Equatable {
  const SupportRequestStatus._(this.wireValue);

  /// Parses a status as sent by the backend.
  factory SupportRequestStatus.fromWire(String raw) {
    final normalized = raw.trim().toUpperCase();
    for (final status in known) {
      if (status.wireValue == normalized) return status;
    }
    return SupportRequestStatus._(normalized);
  }

  /// The tablet asked for assistance; no technician has taken it.
  static const SupportRequestStatus waiting = SupportRequestStatus._('WAITING');

  /// A technician took it; the user has not answered yet.
  static const SupportRequestStatus assigned = SupportRequestStatus._(
    'ASSIGNED',
  );

  /// The user authorised that technician. Does NOT imply a session exists.
  static const SupportRequestStatus accepted = SupportRequestStatus._(
    'ACCEPTED',
  );

  /// The user refused the technician. Terminal.
  static const SupportRequestStatus rejected = SupportRequestStatus._(
    'REJECTED',
  );

  /// The user withdrew the request. Terminal.
  static const SupportRequestStatus cancelled = SupportRequestStatus._(
    'CANCELLED',
  );

  /// A remote session existed and was closed. Terminal.
  static const SupportRequestStatus completed = SupportRequestStatus._(
    'COMPLETED',
  );

  /// Values documented in `docs/backend/ENDPOINTS.md`.
  static const List<SupportRequestStatus> known = [
    waiting,
    assigned,
    accepted,
    rejected,
    cancelled,
    completed,
  ];

  /// Only one of these may exist per device at a time.
  static const List<SupportRequestStatus> active = [
    waiting,
    assigned,
    accepted,
  ];

  /// The exact string used by the backend, also used as the `status` query
  /// parameter of `GET /support-requests`.
  final String wireValue;

  bool get isKnown => known.contains(this);

  bool get isActive => active.contains(this);

  bool get isTerminal => isKnown && !isActive;

  /// Whether `POST /support-requests/:id/assign` is a legal transition.
  ///
  /// This only hides an impossible action: the backend performs the real
  /// conditional transition and stays authoritative.
  bool get isAssignable => this == waiting;

  /// Short label for chips and tables.
  String get label => switch (wireValue) {
    'WAITING' => 'Esperando técnico',
    'ASSIGNED' => 'Asignada',
    'ACCEPTED' => 'Aceptada',
    'REJECTED' => 'Rechazada',
    'CANCELLED' => 'Cancelada',
    'COMPLETED' => 'Finalizada',
    _ => wireValue.isEmpty ? 'Estado desconocido' : wireValue,
  };

  /// Sentence explaining what the state means for the technician.
  String get description => switch (wireValue) {
    'WAITING' => 'Esperando técnico',
    'ASSIGNED' => 'Esperando autorización del usuario',
    'ACCEPTED' => 'Usuario autorizó la asistencia',
    'REJECTED' => 'Usuario rechazó la asistencia',
    'CANCELLED' => 'Solicitud cancelada',
    'COMPLETED' => 'Asistencia finalizada',
    _ => 'Estado no reconocido por esta versión del panel',
  };

  @override
  List<Object?> get props => [wireValue];

  @override
  String toString() => 'SupportRequestStatus($wireValue)';
}
