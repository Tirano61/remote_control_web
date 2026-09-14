import 'package:flutter/foundation.dart';

/// Operational logging, debug builds only.
///
/// Safe to log: `device.publicId`, `supportRequestId`, `remoteSessionId`,
/// connection lifecycle facts.
///
/// NEVER pass to this function: the User JWT, an `Authorization` header, a
/// password, an `auth.token` handshake map, SDP or ICE candidate contents.
/// Release builds drop the call entirely, but the rule holds regardless.
void logDebug(String message) {
  if (kDebugMode) {
    debugPrint('[remote_control_web] $message');
  }
}
