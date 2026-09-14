import 'package:equatable/equatable.dart';

/// The `technician` block of a remote session.
///
/// The backend exposes only `id` and `name`: never the account email, the
/// roles or any token.
class RemoteSessionTechnician extends Equatable {
  const RemoteSessionTechnician({required this.id, required this.name});

  final String id;
  final String name;

  @override
  List<Object?> get props => [id, name];

  @override
  String toString() => 'RemoteSessionTechnician(id: $id)';
}
