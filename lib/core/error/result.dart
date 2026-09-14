import 'package:equatable/equatable.dart';

import 'failure.dart';

/// Explicit success/failure result, so domain and presentation never depend on
/// exceptions crossing layer boundaries.
sealed class Result<T> extends Equatable {
  const Result();

  @override
  List<Object?> get props => const [];
}

final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;

  @override
  List<Object?> get props => [value];

  @override
  String toString() => 'Success<$T>()';
}

final class Failed<T> extends Result<T> {
  const Failed(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];

  @override
  String toString() => 'Failed<$T>(${failure.runtimeType})';
}
