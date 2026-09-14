import 'package:equatable/equatable.dart';

/// The stable signaling error codes of `docs/backend/REALTIME.md`.
///
/// The contract is explicit: clients branch on `error`, never on a human
/// readable string. An unknown future code is preserved and treated as a
/// refusal, exactly like the documented ones.
class SignalingErrorCode extends Equatable {
  const SignalingErrorCode._(this.wireValue);

  factory SignalingErrorCode.fromWire(String raw) {
    final normalized = raw.trim().toUpperCase();
    for (final code in known) {
      if (code.wireValue == normalized) return code;
    }
    return SignalingErrorCode._(normalized);
  }

  /// The payload does not satisfy the DTO, or carried an unknown property.
  static const SignalingErrorCode invalidPayload = SignalingErrorCode._(
    'INVALID_PAYLOAD',
  );

  /// The socket has not joined that remote session, or joined a different one.
  static const SignalingErrorCode notJoined = SignalingErrorCode._(
    'NOT_JOINED',
  );

  /// The session does not exist, is closed, or belongs to somebody else. The
  /// three cases are indistinguishable on purpose.
  static const SignalingErrorCode unauthorized = SignalingErrorCode._(
    'UNAUTHORIZED',
  );

  /// Transient server side condition: the destination namespace is not
  /// registered yet.
  static const SignalingErrorCode unavailable = SignalingErrorCode._(
    'UNAVAILABLE',
  );

  static const List<SignalingErrorCode> known = [
    invalidPayload,
    notJoined,
    unauthorized,
    unavailable,
  ];

  final String wireValue;

  bool get isKnown => known.contains(this);

  @override
  List<Object?> get props => [wireValue];

  @override
  String toString() => 'SignalingErrorCode($wireValue)';
}
