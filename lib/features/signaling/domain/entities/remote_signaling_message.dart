import 'package:equatable/equatable.dart';

import 'signaling_origin.dart';
import 'webrtc_ice_candidate.dart';
import 'webrtc_session_description.dart';

/// A `webrtc:*` message relayed to this technician by the backend.
///
/// The variants mirror the three relayed events one to one. Nothing is applied
/// to a peer connection at this stage: the message is parsed, filtered by the
/// session the socket is joined to, and handed over.
sealed class RemoteSignalingMessage extends Equatable {
  const RemoteSignalingMessage({this.origin});

  /// Which session the message belongs to. It is the isolation boundary on the
  /// client: a message for any other session is dropped.
  String get remoteSessionId;

  /// `from`, as the backend stamped it. Metadata only — never authorization,
  /// and `null` when the field was absent or unknown.
  final SignalingOrigin? origin;

  @override
  List<Object?> get props => const [];
}

/// `webrtc:offer` relayed from the device.
final class OfferReceived extends RemoteSignalingMessage {
  const OfferReceived({required this.offer, super.origin});

  final WebRtcOffer offer;

  @override
  String get remoteSessionId => offer.remoteSessionId;

  @override
  List<Object?> get props => [offer, origin];

  @override
  String toString() =>
      'OfferReceived(remoteSessionId: $remoteSessionId, '
      'sdpLength: ${offer.sdpLength}, from: ${origin?.wireValue})';
}

/// `webrtc:answer` relayed from the device.
final class AnswerReceived extends RemoteSignalingMessage {
  const AnswerReceived({required this.answer, super.origin});

  final WebRtcAnswer answer;

  @override
  String get remoteSessionId => answer.remoteSessionId;

  @override
  List<Object?> get props => [answer, origin];

  @override
  String toString() =>
      'AnswerReceived(remoteSessionId: $remoteSessionId, '
      'sdpLength: ${answer.sdpLength}, from: ${origin?.wireValue})';
}

/// `webrtc:ice-candidate` relayed from the device.
final class IceCandidateReceived extends RemoteSignalingMessage {
  const IceCandidateReceived({required this.candidate, super.origin});

  final WebRtcIceCandidate candidate;

  @override
  String get remoteSessionId => candidate.remoteSessionId;

  @override
  List<Object?> get props => [candidate, origin];

  @override
  String toString() =>
      'IceCandidateReceived(remoteSessionId: $remoteSessionId, '
      'candidateLength: ${candidate.candidateLength}, '
      'from: ${origin?.wireValue})';
}
