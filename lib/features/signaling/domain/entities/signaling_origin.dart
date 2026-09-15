/// The `from` field the backend adds to every relayed `webrtc:*` payload.
///
/// `docs/backend/REALTIME.md`: *"`from` is added by the server and is `DEVICE`
/// or `TECHNICIAN`"*. It is metadata, never authorization — the backend has
/// already decided who may talk into the room, and a technician can only ever
/// be relayed messages coming from the device at the other end of its own
/// session.
///
/// Isolation on this side is done with `remoteSessionId` against the session
/// the socket is currently joined to, not with this field.
enum SignalingOrigin {
  device('DEVICE'),
  technician('TECHNICIAN');

  const SignalingOrigin(this.wireValue);

  final String wireValue;

  /// Parses the wire value, or `null` when it is missing or unknown.
  ///
  /// An unrecognised origin never discards the message: the payload is still
  /// a valid offer/answer/candidate for a session this socket joined, and
  /// dropping it would break the negotiation for no security gain.
  static SignalingOrigin? fromWire(Object? raw) {
    if (raw is! String) return null;
    final normalized = raw.trim().toUpperCase();
    for (final origin in values) {
      if (origin.wireValue == normalized) return origin;
    }
    return null;
  }
}
