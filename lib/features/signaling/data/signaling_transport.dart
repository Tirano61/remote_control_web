/// One `webrtc:*` event exactly as the socket delivered it, unparsed.
typedef SignalingWireEvent = ({String event, Object? data});

/// The slice of the single `/technicians` connection signaling needs.
///
/// It exists so that this feature never opens a socket of its own. The
/// `technician_realtime` client owns the one physical connection of the
/// application — handshake, reconnection, `remote-session:join` — and exposes
/// it through this port; signaling only emits over it and reads what arrives.
///
/// Nothing here interprets a payload: the realtime side forwards raw events
/// and never touches SDP or ICE, which is what keeps them out of its logs.
abstract interface class SignalingTransport {
  /// Session whose signaling room the socket is in, or `null`.
  ///
  /// Set by an accepted `remote-session:join`, lost with the connection. It is
  /// read before every emission and before publishing every incoming message.
  String? get joinedRemoteSessionId;

  /// `webrtc:offer`, `webrtc:answer` and `webrtc:ice-candidate` as they
  /// arrive. Broadcast.
  Stream<SignalingWireEvent> get signalingEvents;

  /// Emits [payload] and reports its acknowledgement to [onAck].
  ///
  /// Returns `false` when there is no usable socket, in which case nothing was
  /// emitted and [onAck] will never be called.
  bool emitSignaling(
    String event,
    Map<String, dynamic> payload,
    void Function(Object? ack) onAck,
  );

  /// Forgets the joined room without touching the connection.
  ///
  /// Called when the backend answers `NOT_JOINED` — the stored membership is
  /// stale and only a new `remote-session:join` can restore it.
  void forgetJoinedRemoteSession();
}
