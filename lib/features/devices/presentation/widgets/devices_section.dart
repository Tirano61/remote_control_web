import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/presentation/widgets/console_feedback.dart';
import '../../../../core/presentation/widgets/console_section.dart';
import '../../../../core/presentation/widgets/presence_indicator.dart';
import '../../domain/entities/device.dart';
import '../bloc/devices/devices_bloc.dart';

/// "DISPOSITIVOS" block of the technician console.
///
/// Read only: the list and the presence of each row come from `GET /devices`
/// and are refreshed on demand.
class DevicesSection extends StatelessWidget {
  const DevicesSection({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DevicesBloc, DevicesState>(
      builder: (context, state) => ConsoleSection(
        title: 'DISPOSITIVOS',
        subtitle: switch (state) {
          DevicesLoaded(:final devices, :final onlineCount) =>
            '${devices.length} registrados · $onlineCount online',
          _ => null,
        },
        trailing: _RefreshButton(
          isBusy: state is DevicesLoading ||
              (state is DevicesLoaded && state.isRefreshing),
          onPressed: () => context.read<DevicesBloc>().add(
            const DevicesRefreshRequested(),
          ),
        ),
        child: switch (state) {
          DevicesInitial() || DevicesLoading() => const _SectionProgress(),
          DevicesFailure(:final failure) => ConsoleErrorState(
            message: 'No se pudieron cargar los dispositivos. ${failure.message}',
            onRetry: () => context.read<DevicesBloc>().add(
              const DevicesRefreshRequested(),
            ),
          ),
          DevicesLoaded(:final devices, :final refreshFailure) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (refreshFailure != null) ...[
                ConsoleBanner(
                  message:
                      'No se pudo actualizar la lista. ${refreshFailure.message}',
                  isError: true,
                ),
                const SizedBox(height: 12),
              ],
              if (devices.isEmpty)
                const ConsoleEmptyState(
                  message: 'Todavía no hay dispositivos registrados.',
                  icon: Icons.tablet_android_outlined,
                )
              else
                _DevicesTable(devices: devices),
            ],
          ),
        },
      ),
    );
  }
}

class _DevicesTable extends StatelessWidget {
  const _DevicesTable({required this.devices});

  final List<Device> devices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 720),
        child: DataTable(
          key: const Key('devices_table'),
          headingRowHeight: 40,
          dataRowMinHeight: 44,
          dataRowMaxHeight: 56,
          headingTextStyle: theme.textTheme.labelLarge,
          columns: const [
            DataColumn(label: Text('Nombre')),
            DataColumn(label: Text('ID')),
            DataColumn(label: Text('Modelo')),
            DataColumn(label: Text('Android')),
            DataColumn(label: Text('Estado')),
          ],
          rows: [
            for (final device in devices)
              DataRow(
                key: ValueKey(device.id),
                cells: [
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(device.displayName),
                        if (!device.isActive) ...[
                          const SizedBox(width: 8),
                          Tooltip(
                            message: 'Dispositivo deshabilitado',
                            child: Icon(
                              Icons.block,
                              size: 16,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  DataCell(SelectableText(device.publicId)),
                  DataCell(Text(device.model ?? '—')),
                  DataCell(
                    Text(
                      device.androidVersion == null
                          ? '—'
                          : 'Android ${device.androidVersion}',
                    ),
                  ),
                  DataCell(PresenceIndicator(isOnline: device.isOnline)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.isBusy, required this.onPressed});

  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const Key('devices_refresh_button'),
    onPressed: isBusy ? null : onPressed,
    icon: isBusy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.refresh, size: 18),
    label: const Text('ACTUALIZAR'),
  );
}

class _SectionProgress extends StatelessWidget {
  const _SectionProgress();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 28),
    child: Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}
