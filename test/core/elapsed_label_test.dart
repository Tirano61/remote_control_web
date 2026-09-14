import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/presentation/format/elapsed_label.dart';

void main() {
  final now = DateTime.utc(2026, 3, 11, 10);

  group('elapsedLabel', () {
    test('under a minute reads as just now', () {
      expect(elapsedLabel(now.subtract(const Duration(seconds: 5)), now), 'hace instantes');
      expect(elapsedLabel(now, now), 'hace instantes');
    });

    test('minutes', () {
      expect(elapsedLabel(now.subtract(const Duration(minutes: 3)), now), 'hace 3 min');
      expect(elapsedLabel(now.subtract(const Duration(minutes: 59)), now), 'hace 59 min');
    });

    test('hours', () {
      expect(elapsedLabel(now.subtract(const Duration(hours: 1)), now), 'hace 1 hora');
      expect(elapsedLabel(now.subtract(const Duration(hours: 5)), now), 'hace 5 horas');
    });

    test('days', () {
      expect(elapsedLabel(now.subtract(const Duration(days: 1)), now), 'hace 1 día');
      expect(elapsedLabel(now.subtract(const Duration(days: 4)), now), 'hace 4 días');
    });

    test('a clock skew in the future does not produce a negative label', () {
      expect(elapsedLabel(now.add(const Duration(minutes: 5)), now), 'hace instantes');
    });
  });

  group('shortTimestamp', () {
    test('formats day and time with two digits', () {
      final value = DateTime(2026, 3, 4, 9, 7);

      expect(shortTimestamp(value), '04/03 09:07');
    });
  });
}
