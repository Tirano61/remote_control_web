import 'package:flutter/material.dart';

/// Backend presence of a device, rendered as a filled/hollow dot plus a label.
///
/// The value always comes from the backend (`isOnline`): the web client never
/// computes nor caches presence.
class PresenceIndicator extends StatelessWidget {
  const PresenceIndicator({
    required this.isOnline,
    this.compact = false,
    super.key,
  });

  final bool isOnline;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isOnline
        ? const Color(0xFF1B9E4B)
        : theme.colorScheme.onSurfaceVariant;
    final label = isOnline ? 'Online' : 'Offline';
    final textStyle = compact
        ? theme.textTheme.bodySmall
        : theme.textTheme.bodyMedium;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          isOnline ? '\u25CF' : '\u25CB',
          style: TextStyle(color: color, fontSize: compact ? 12 : 14),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: textStyle?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
