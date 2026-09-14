import 'package:equatable/equatable.dart';

/// The `RemoteSessionStatus` enum of the backend, typed.
///
/// The contract asks clients to treat unknown future values defensively, so an
/// unrecognised status is preserved instead of crashing the console. An unknown
/// status is never considered live: it grants no action and never keeps an
/// assistance view on screen.
class RemoteSessionStatus extends Equatable {
  const RemoteSessionStatus._(this.wireValue);

  /// Parses a status as sent by the backend.
  factory RemoteSessionStatus.fromWire(String raw) {
    final normalized = raw.trim().toUpperCase();
    for (final status in known) {
      if (status.wireValue == normalized) return status;
    }
    return RemoteSessionStatus._(normalized);
  }

  /// The session exists and both ends may start connecting.
  static const RemoteSessionStatus connecting = RemoteSessionStatus._(
    'CONNECTING',
  );

  /// Reserved by the backend. No code path sets it today, but the console must
  /// render it if it ever arrives — it must never be simulated locally.
  static const RemoteSessionStatus active = RemoteSessionStatus._('ACTIVE');

  /// The session ended. Terminal.
  static const RemoteSessionStatus closed = RemoteSessionStatus._('CLOSED');

  /// Values documented in `docs/backend/ENDPOINTS.md`.
  static const List<RemoteSessionStatus> known = [connecting, active, closed];

  /// Only one of these may exist per technician, and per device, at a time.
  static const List<RemoteSessionStatus> live = [connecting, active];

  /// The exact string used by the backend.
  final String wireValue;

  bool get isKnown => known.contains(this);

  /// Anything this version of the console does not recognise.
  bool get isUnknown => !isKnown;

  /// Whether the session is still open. An unknown status is never live.
  bool get isLive => live.contains(this);

  /// Short label for headers and chips.
  String get label => switch (wireValue) {
    'CONNECTING' => 'Conectando',
    'ACTIVE' => 'En curso',
    'CLOSED' => 'Finalizada',
    _ => wireValue.isEmpty ? 'Estado desconocido' : wireValue,
  };

  /// Sentence shown to the technician.
  String get description => switch (wireValue) {
    'CONNECTING' => 'Conectando con el dispositivo...',
    'ACTIVE' => 'Asistencia en curso',
    'CLOSED' => 'Asistencia finalizada',
    _ => 'Estado no reconocido por esta versión del panel',
  };

  @override
  List<Object?> get props => [wireValue];

  @override
  String toString() => 'RemoteSessionStatus($wireValue)';
}
