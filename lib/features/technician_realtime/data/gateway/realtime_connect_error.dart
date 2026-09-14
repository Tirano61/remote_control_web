import '../realtime_contract.dart';

/// Tells a rejected handshake from a transport problem.
///
/// The distinction decides whether the user is signed out, so it is made on
/// the documented part of the contract and nowhere else: the `/technicians`
/// middleware answers a `connect_error` whose message is the single generic
/// string `Unauthorized` (`docs/backend/REALTIME.md`). Socket.IO delivers it as
/// the `data` of the CONNECT_ERROR packet, i.e. a map with a `message` key.
///
/// Everything else — no route to the host, CORS, a closed tunnel, a dropped
/// socket — is a network condition and must never end the session.
class RealtimeConnectError {
  const RealtimeConnectError._();

  static bool isAuthenticationFailure(Object? error) =>
      _messageOf(error) ==
      TechnicianRealtimeContract.unauthorizedConnectErrorMessage;

  static String? _messageOf(Object? error) {
    if (error is Map) {
      final message = error['message'];
      return message is String ? message : null;
    }
    return null;
  }
}
