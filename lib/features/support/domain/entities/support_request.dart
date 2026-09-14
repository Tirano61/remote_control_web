import 'package:equatable/equatable.dart';

import 'support_device.dart';
import 'support_request_status.dart';
import 'support_technician.dart';

/// A support request as seen by the technician console
/// (`GET /support-requests`).
///
/// The `device` block is present only in the technician facing responses, so
/// it is modelled as optional.
class SupportRequest extends Equatable {
  const SupportRequest({
    required this.id,
    required this.deviceId,
    required this.status,
    required this.createdAt,
    this.technicianId,
    this.technician,
    this.device,
    this.assignedAt,
    this.respondedAt,
    this.closedAt,
  });

  final String id;
  final String deviceId;
  final SupportRequestStatus status;
  final DateTime createdAt;

  /// Set by the backend from the authenticated user when the request is taken.
  /// The web client never sends it.
  final String? technicianId;
  final SupportTechnician? technician;

  final SupportDevice? device;
  final DateTime? assignedAt;
  final DateTime? respondedAt;
  final DateTime? closedAt;

  bool get isWaiting => status == SupportRequestStatus.waiting;

  bool get isActive => status.isActive;

  bool get isTerminal => status.isTerminal;

  /// Whether the device is currently reachable.
  ///
  /// `null` when the response carried no `device` block.
  bool? get isDeviceOnline => device?.isOnline;

  /// Whether taking this request could succeed right now.
  ///
  /// Purely a UI hint: the backend refuses an assignment on an offline device
  /// or a non `WAITING` request regardless of what the console shows.
  bool get looksAssignable => status.isAssignable && (device?.isOnline ?? true);

  /// Whether this request is assigned to [userId].
  ///
  /// [userId] must come from the authenticated backend identity, never from
  /// user input, and it is used only to decide what to display.
  bool isAssignedTo(String userId) => technicianId != null && technicianId == userId;

  String get deviceLabel => device?.displayName ?? deviceId;

  SupportRequest copyWith({
    SupportRequestStatus? status,
    String? technicianId,
    SupportTechnician? technician,
    SupportDevice? device,
    DateTime? assignedAt,
    DateTime? respondedAt,
    DateTime? closedAt,
  }) => SupportRequest(
    id: id,
    deviceId: deviceId,
    status: status ?? this.status,
    createdAt: createdAt,
    technicianId: technicianId ?? this.technicianId,
    technician: technician ?? this.technician,
    device: device ?? this.device,
    assignedAt: assignedAt ?? this.assignedAt,
    respondedAt: respondedAt ?? this.respondedAt,
    closedAt: closedAt ?? this.closedAt,
  );

  @override
  List<Object?> get props => [
    id,
    deviceId,
    status,
    createdAt,
    technicianId,
    technician,
    device,
    assignedAt,
    respondedAt,
    closedAt,
  ];

  @override
  String toString() =>
      'SupportRequest(id: $id, status: ${status.wireValue}, '
      'deviceId: $deviceId)';
}
