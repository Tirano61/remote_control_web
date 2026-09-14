import 'package:equatable/equatable.dart';

/// The `technician` block of a support request.
///
/// The backend exposes only `id` and `name` here: never the account email and
/// never the roles.
class SupportTechnician extends Equatable {
  const SupportTechnician({required this.id, required this.name});

  final String id;
  final String name;

  @override
  List<Object?> get props => [id, name];

  @override
  String toString() => 'SupportTechnician(id: $id)';
}
