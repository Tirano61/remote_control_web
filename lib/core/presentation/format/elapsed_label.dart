/// Renders how long ago something happened, in Spanish, for the console.
///
/// Pure function: the clock is passed in, so it is testable and never reads
/// `DateTime.now()` from inside a widget build.
String elapsedLabel(DateTime from, DateTime now) {
  final elapsed = now.difference(from);
  if (elapsed.isNegative || elapsed.inSeconds < 60) return 'hace instantes';
  if (elapsed.inMinutes < 60) {
    return 'hace ${elapsed.inMinutes} min';
  }
  if (elapsed.inHours < 24) {
    final hours = elapsed.inHours;
    return hours == 1 ? 'hace 1 hora' : 'hace $hours horas';
  }
  final days = elapsed.inDays;
  return days == 1 ? 'hace 1 día' : 'hace $days días';
}

/// Day and time in the browser local time zone, as `dd/MM HH:mm`.
///
/// The backend sends UTC ISO-8601 timestamps; they are converted for display.
String shortTimestamp(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Time of day in the browser local time zone, as `HH:mm`.
///
/// Used for backend stamped instants such as `RemoteSession.connectedAt`. The
/// value always comes from the backend: the console never computes the moment
/// an assistance started.
String timeOfDay(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}
