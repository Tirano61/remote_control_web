import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/error/failure.dart';
import '../../features/auth/domain/entities/authenticated_user.dart';
import '../../features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import '../../features/devices/presentation/bloc/devices/devices_bloc.dart';
import '../../features/devices/presentation/widgets/devices_section.dart';
import '../../features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import '../../features/remote_session/presentation/widgets/active_assistance_section.dart';
import '../../features/remote_session/presentation/widgets/start_assistance_button.dart';
import '../../features/support/domain/entities/support_request_status.dart';
import '../../features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import '../../features/support/presentation/widgets/support_requests_section.dart';
import '../../features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../../features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import '../../features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import '../composition_root.dart';
import 'technician_console_coordinator.dart';

/// Technician console.
///
/// It composes several features without any of them knowing about the others:
/// `auth` owns the session, `support` owns the request queue, `devices` owns
/// the device list, `remote_session` owns the assistance and
/// `technician_realtime` owns the /technicians connection. Every list is
/// loaded independently, so a failure in one never hides the other.
///
/// REST remains the source of truth. Realtime only tells the console that
/// something changed; what changed is always re-read over HTTP.
class DashboardPage extends StatelessWidget {
  const DashboardPage({
    required this.dependencies,
    required this.user,
    super.key,
  });

  final AppDependencies dependencies;
  final AuthenticatedUser user;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<SupportRequestsBloc>(
          create: (_) => dependencies.createSupportRequestsBloc(),
        ),
        BlocProvider<DevicesBloc>(
          create: (_) => dependencies.createDevicesBloc(),
        ),
        BlocProvider<RemoteSessionBloc>(
          create: (_) => dependencies.createRemoteSessionBloc(),
        ),
        BlocProvider<TechnicianRealtimeBloc>(
          create: (_) => dependencies.createTechnicianRealtimeBloc(),
        ),
        BlocProvider<SignalingJoinBloc>(
          create: (_) => dependencies.createSignalingJoinBloc(),
        ),
        BlocProvider<WebRtcSessionBloc>(
          create: (_) => dependencies.createWebRtcSessionBloc(),
        ),
      ],
      child: _ConsoleCoordinatorScope(
        dependencies: dependencies,
        child: _ConsoleScaffold(user: user),
      ),
    );
  }
}

/// Keeps the console coordinator alive for as long as the console is on screen.
///
/// Opening the console means the user is authenticated, so this is also where
/// the technician namespace is connected; leaving it — a logout, or a session
/// that was invalidated — disposes the coordinator and closes the socket.
class _ConsoleCoordinatorScope extends StatefulWidget {
  const _ConsoleCoordinatorScope({
    required this.dependencies,
    required this.child,
  });

  final AppDependencies dependencies;
  final Widget child;

  @override
  State<_ConsoleCoordinatorScope> createState() =>
      _ConsoleCoordinatorScopeState();
}

class _ConsoleCoordinatorScopeState extends State<_ConsoleCoordinatorScope> {
  late final TechnicianConsoleCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    _coordinator = widget.dependencies.createConsoleCoordinator(
      userSessionBloc: context.read<UserSessionBloc>(),
      remoteSessionBloc: context.read<RemoteSessionBloc>(),
      technicianRealtimeBloc: context.read<TechnicianRealtimeBloc>(),
      signalingJoinBloc: context.read<SignalingJoinBloc>(),
      supportRequestsBloc: context.read<SupportRequestsBloc>(),
      webRtcSessionBloc: context.read<WebRtcSessionBloc>(),
    )..start();
  }

  @override
  void dispose() {
    unawaited(_coordinator.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ConsoleScaffold extends StatelessWidget {
  const _ConsoleScaffold({required this.user});

  final AuthenticatedUser user;

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        // A rejected User JWT ends the session, wherever it was detected.
        BlocListener<SupportRequestsBloc, SupportRequestsState>(
          listenWhen: _failureChanged,
          listener: (context, state) =>
              _handleFailure(context, state.lastFailure),
        ),
        BlocListener<DevicesBloc, DevicesState>(
          listenWhen: _devicesFailureChanged,
          listener: (context, state) =>
              _handleFailure(context, state.lastFailure),
        ),
        // A refused assignment usually means the device went offline or the
        // request was taken first, so the device list is worth re-reading too.
        BlocListener<SupportRequestsBloc, SupportRequestsState>(
          listenWhen: (previous, current) =>
              _failureChanged(previous, current) &&
              current.lastFailure is ConflictFailure,
          listener: (context, _) =>
              context.read<DevicesBloc>().add(const DevicesRefreshRequested()),
        ),
      ],
      child: Scaffold(
        appBar: _ConsoleAppBar(user: user),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // A live assistance comes first: it is what the technician
                    // is doing right now.
                    const ActiveAssistanceSection(),
                    SupportRequestsSection(
                      technicianId: user.id,
                      now: DateTime.now(),
                      // Only a request this technician owns and the tablet
                      // accepted can start an assistance. The button hides
                      // itself while a session is live, because the backend
                      // allows only one per technician.
                      ownRequestActionBuilder: (request) =>
                          request.status == SupportRequestStatus.accepted
                          ? StartAssistanceButton(supportRequestId: request.id)
                          : null,
                    ),
                    const SizedBox(height: 20),
                    const DevicesSection(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static bool _failureChanged(
    SupportRequestsState previous,
    SupportRequestsState current,
  ) => previous.lastFailure != current.lastFailure && current.lastFailure != null;

  static bool _devicesFailureChanged(
    DevicesState previous,
    DevicesState current,
  ) => previous.lastFailure != current.lastFailure && current.lastFailure != null;

  /// Only a `401` invalidates the session.
  ///
  /// A `403`, a conflict or a network problem is reported inside the section
  /// that produced it and the user stays signed in.
  static void _handleFailure(BuildContext context, Failure? failure) {
    if (failure is! AuthFailure) return;
    context.read<UserSessionBloc>().add(const UserSessionInvalidated());
  }
}


/// Console header.
///
/// Collapses to icon-only actions on narrow viewports so the toolbar never
/// overflows; the console is meant for a desktop browser but must survive a
/// small window.
class _ConsoleAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ConsoleAppBar({required this.user});

  /// Below this width the header drops the labels.
  static const double compactBreakpoint = 900;

  final AuthenticatedUser user;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCompact = MediaQuery.sizeOf(context).width < compactBreakpoint;

    return AppBar(
      titleSpacing: 20,
      title: Row(
        children: [
          Icon(
            Icons.desktop_windows_outlined,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'REMOTE CONTROL',
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
      actions: [
        _RefreshAllButton(isCompact: isCompact),
        const SizedBox(width: 8),
        _UserBadge(user: user, isCompact: isCompact),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: isCompact
              ? IconButton(
                  key: const Key('logout_button'),
                  onPressed: () => _signOut(context),
                  icon: const Icon(Icons.logout, size: 20),
                  tooltip: 'Cerrar sesión',
                )
              : TextButton.icon(
                  key: const Key('logout_button'),
                  onPressed: () => _signOut(context),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('SALIR'),
                ),
        ),
      ],
    );
  }

  void _signOut(BuildContext context) => context.read<UserSessionBloc>().add(
    const UserSessionSignOutRequested(),
  );
}

/// Refreshes both sections at once.
///
/// It deliberately does not re-validate the session: `GET /auth/check-status`
/// is a startup concern, and an expired token is detected by the very requests
/// this button triggers.
class _RefreshAllButton extends StatelessWidget {
  const _RefreshAllButton({required this.isCompact});

  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    void refresh() {
      context.read<SupportRequestsBloc>().add(
        const SupportRequestsRefreshRequested(),
      );
      context.read<DevicesBloc>().add(const DevicesRefreshRequested());
    }

    if (isCompact) {
      return IconButton(
        key: const Key('console_refresh_button'),
        onPressed: refresh,
        icon: const Icon(Icons.refresh, size: 20),
        tooltip: 'Actualizar',
      );
    }

    return FilledButton.tonalIcon(
      key: const Key('console_refresh_button'),
      onPressed: refresh,
      icon: const Icon(Icons.refresh, size: 18),
      label: const Text('ACTUALIZAR'),
    );
  }
}

class _UserBadge extends StatelessWidget {
  const _UserBadge({required this.user, required this.isCompact});

  final AuthenticatedUser user;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = CircleAvatar(
      radius: 14,
      child: Text(
        _initials(user.fullName),
        style: const TextStyle(fontSize: 12),
      ),
    );

    // The email is only a tooltip: it identifies the session without taking
    // toolbar space, and no token or role check depends on it.
    return Tooltip(
      message: '${user.fullName} · ${user.rolesLabel}',
      child: isCompact
          ? avatar
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                avatar,
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(user.fullName, style: theme.textTheme.labelLarge),
                    Text(
                      user.rolesLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  String _initials(String fullName) {
    final parts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }
}
