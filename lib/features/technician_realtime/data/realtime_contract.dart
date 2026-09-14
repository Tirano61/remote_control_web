/// Wire level constants of the `/technicians` namespace.
///
/// Copied from `docs/backend/REALTIME.md`; they are the contract, so they live
/// in exactly one place and are asserted by the contract tests.
class TechnicianRealtimeContract {
  const TechnicianRealtimeContract._();

  /// Namespace consumed by `remote_control_web`. The `/devices` namespace is
  /// for the tablet and is never opened from here.
  static const String namespace = '/technicians';

  /// Handshake field carrying the User JWT: `auth.token`.
  ///
  /// Nothing else in the handshake is read by the backend, and no `email`,
  /// `userId`, `technicianId` or `roles` is ever sent: identity comes from the
  /// validated token only.
  static const String authTokenField = 'token';

  /// Generic message the namespace middleware answers with when the handshake
  /// is rejected. The reason is deliberately not disclosed.
  static const String unauthorizedConnectErrorMessage = 'Unauthorized';

  /// Client to server. The only signaling event implemented at this stage.
  static const String joinEvent = 'remote-session:join';

  /// Server to client domain notification. Requires no join.
  static const String remoteSessionClosedEvent = 'remote-session:closed';

  /// The only property `remote-session:join` accepts, and the id carried by
  /// both the join ACK and `remote-session:closed`.
  static const String remoteSessionIdField = 'remoteSessionId';

  /// Join ACK fields.
  static const String joinedField = 'joined';
  static const String errorField = 'error';

  /// `remote-session:closed` field carrying a `RemoteSessionEndedBy` value.
  static const String endedByField = 'endedBy';

  /// Payload of `remote-session:join`. The participant is never sent: the
  /// backend derives it from the namespace the socket connected through.
  static Map<String, dynamic> joinPayload(String remoteSessionId) => {
    remoteSessionIdField: remoteSessionId,
  };

  /// Handshake `auth` map.
  static Map<String, dynamic> authPayload(String token) => {
    authTokenField: token,
  };
}
