import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/composition_root.dart';
import 'package:remote_control_web/app/console/dashboard_page.dart';
import 'package:remote_control_web/app/remote_control_app.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/presentation/pages/login_page.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/support/data/repositories/support_request_repository_impl.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_web/features/support/presentation/bloc/support_requests/support_requests_bloc.dart';

import '../../support/auth_test_doubles.dart';
import '../../support/console_test_doubles.dart';
import '../../support/realtime_test_doubles.dart';
import '../../support/webrtc_test_doubles.dart';
import '../../support/remote_session_test_doubles.dart';

void main() {
  late FakeAuthRemoteDataSource auth;
  late InMemoryUserTokenStorage storage;
  late FakeDeviceRepository devices;
  late FakeSupportRequestRepository supportRequests;
  late FakeRemoteSessionRepository remoteSessions;
  late FakeTechnicianRealtimeClient realtime;

  setUp(() {
    auth = FakeAuthRemoteDataSource();
    storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    auth.checkStatusResponse = technicianSession;
    devices = FakeDeviceRepository();
    supportRequests = FakeSupportRequestRepository();
    remoteSessions = FakeRemoteSessionRepository();
    realtime = FakeTechnicianRealtimeClient();
  });

  /// Opens the console with a restored `tecnico` session.
  Future<void> pumpConsole(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RemoteControlApp(
        dependencies: AppDependencies(
          config: const AppConfig(backendBaseUrl: 'http://localhost:3000'),
          authRepository: AuthRepositoryImpl(
            remoteDataSource: auth,
            tokenStorage: storage,
          ),
          deviceRepository: devices,
          supportRequestRepository: supportRequests,
          remoteSessionRepository: remoteSessions,
          technicianRealtimeClient: realtime,
          technicianSignalingClient: TechnicianSignalingClientImpl(
            transport: realtime,
          ),
          webRtcPeerClient: FakeWebRtcPeerClient(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapAssign(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('assign_button_$id')));
    await tester.pumpAndSettle();
  }

  group('initial load', () {
    testWidgets('both sections are loaded independently', (tester) async {
      devices.devices = [buildDevice()];
      supportRequests.requests = [buildSupportRequest()];

      await pumpConsole(tester);

      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.text('SOLICITUDES DE ASISTENCIA'), findsOneWidget);
      expect(find.text('DISPOSITIVOS'), findsOneWidget);
      expect(devices.loadCount, 1);
      expect(supportRequests.loadCount, 1);
    });

    testWidgets('a devices failure does not hide the support requests', (
      tester,
    ) async {
      devices.failure = const NetworkFailure();
      supportRequests.requests = [buildSupportRequest()];

      await pumpConsole(tester);

      expect(
        find.textContaining('No se pudieron cargar los dispositivos'),
        findsOneWidget,
      );
      expect(find.text('TOMAR SOLICITUD'), findsOneWidget);
      // A failed load never ends the session.
      expect(storage.token, 'tecnico-jwt');
    });

    testWidgets('a support failure does not hide the devices', (tester) async {
      devices.devices = [buildDevice()];
      supportRequests.loadFailure = const NetworkFailure();

      await pumpConsole(tester);

      expect(
        find.textContaining('No se pudieron cargar las solicitudes'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('devices_table')), findsOneWidget);
      expect(find.text('Tablet Prueba'), findsWidgets);
    });

    testWidgets('a failed section offers a retry that reloads it', (
      tester,
    ) async {
      devices.failure = const NetworkFailure();
      await pumpConsole(tester);
      expect(devices.loadCount, 1);

      devices
        ..failure = null
        ..devices = [buildDevice()];
      await tester.tap(find.widgetWithText(FilledButton, 'REINTENTAR'));
      await tester.pumpAndSettle();

      expect(devices.loadCount, 2);
      expect(find.byKey(const Key('devices_table')), findsOneWidget);
    });
  });

  group('devices', () {
    testWidgets('renders the documented columns and the readable id', (
      tester,
    ) async {
      devices.devices = [buildDevice()];

      await pumpConsole(tester);

      expect(find.text('Nombre'), findsOneWidget);
      expect(find.text('ID'), findsOneWidget);
      expect(find.text('Modelo'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);
      expect(find.text('Estado'), findsOneWidget);

      expect(find.text('Tablet Prueba'), findsWidgets);
      expect(find.text('132-491-092'), findsWidgets);
      expect(find.text('SKY_PAD10MAX'), findsWidgets);
      expect(find.text('Android 14'), findsOneWidget);
    });

    testWidgets('online and offline are shown as sent by the backend', (
      tester,
    ) async {
      devices.devices = [
        buildDevice(id: 'on', publicId: '111-111-111', isOnline: true),
        buildDevice(id: 'off', publicId: '222-222-222', isOnline: false),
      ];

      await pumpConsole(tester);

      expect(find.text('Online'), findsWidgets);
      expect(find.text('Offline'), findsWidgets);
      expect(find.text('2 registrados · 1 online'), findsOneWidget);
    });
  });

  group('WAITING', () {
    testWidgets('shows the device, the state and the action', (tester) async {
      supportRequests.requests = [buildSupportRequest()];

      await pumpConsole(tester);

      expect(find.text('Tablet Prueba'), findsWidgets);
      expect(find.text('132-491-092'), findsWidgets);
      expect(find.text('SKY_PAD10MAX'), findsWidgets);
      expect(find.text('Estado: Esperando técnico'), findsOneWidget);
      expect(find.text('TOMAR SOLICITUD'), findsOneWidget);
      expect(find.textContaining('Solicitada hace'), findsOneWidget);
    });

    testWidgets('an empty queue says so', (tester) async {
      await pumpConsole(tester);

      expect(
        find.text('No hay solicitudes esperando un técnico.'),
        findsOneWidget,
      );
      expect(find.text('TOMAR SOLICITUD'), findsNothing);
    });

    testWidgets('the action is disabled while the device is offline', (
      tester,
    ) async {
      supportRequests.requests = [buildSupportRequest(isDeviceOnline: false)];

      await pumpConsole(tester);

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'TOMAR SOLICITUD'),
      );
      expect(button.onPressed, isNull);
      expect(
        find.textContaining('El dispositivo está desconectado'),
        findsOneWidget,
      );
    });
  });

  group('TOMAR SOLICITUD', () {
    testWidgets('assigns the request and waits for the tablet', (tester) async {
      supportRequests.requests = [buildSupportRequest()];
      await pumpConsole(tester);

      await tapAssign(tester, requestId);

      expect(supportRequests.assignedIds, [requestId]);
      expect(find.text(kAssignSucceededNotice), findsOneWidget);
      expect(find.text('TOMAR SOLICITUD'), findsNothing);
      expect(
        find.text('Estado: Esperando autorización del usuario'),
        findsOneWidget,
      );
      expect(find.text('ASIGNADAS A TI (1)'), findsOneWidget);
    });

    testWidgets('a double click only sends one request', (tester) async {
      supportRequests.requests = [buildSupportRequest()];
      final gate = Completer<void>();
      supportRequests.assignGate = gate.future;
      await pumpConsole(tester);

      final button = find.byKey(ValueKey('assign_button_$requestId'));
      await tester.tap(button);
      await tester.pump();
      // Second click while the first call is still in flight.
      await tester.tap(button);
      await tester.pump();

      expect(supportRequests.assignedIds, [requestId]);
      expect(
        tester.widget<FilledButton>(button).onPressed,
        isNull,
        reason: 'the button must be disabled while the call is in flight',
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(supportRequests.assignedIds, [requestId]);
    });

    testWidgets('a 409 shows a short message and refreshes both lists', (
      tester,
    ) async {
      devices.devices = [buildDevice()];
      supportRequests
        ..requests = [buildSupportRequest()]
        ..assignFailure = const ConflictFailure(kAssignConflictMessage)
        ..requestsAfterFirstLoad = [
          buildSupportRequest(
            status: SupportRequestStatus.assigned,
            technician: 'another-technician',
          ),
        ];
      await pumpConsole(tester);
      expect(devices.loadCount, 1);

      await tapAssign(tester, requestId);

      expect(find.text(kAssignConflictMessage), findsOneWidget);
      // No technical exception reaches the user.
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('409'), findsNothing);
      // The queue was re-read, and so was the device list.
      expect(supportRequests.loadCount, 2);
      expect(devices.loadCount, 2);
      expect(find.text('TOMAR SOLICITUD'), findsNothing);
      expect(find.text('EN CURSO CON OTROS TÉCNICOS (1)'), findsOneWidget);
    });

    testWidgets('a 403 reports a permissions error and keeps the session', (
      tester,
    ) async {
      supportRequests
        ..requests = [buildSupportRequest()]
        ..assignFailure = const ForbiddenFailure(
          'No tienes permisos para tomar solicitudes de asistencia.',
        );
      await pumpConsole(tester);

      await tapAssign(tester, requestId);

      expect(
        find.text('No tienes permisos para tomar solicitudes de asistencia.'),
        findsOneWidget,
      );
      // The session survives: 403 is authorisation, not authentication.
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.byType(LoginPage), findsNothing);
      expect(storage.token, 'tecnico-jwt');
      // The request stays takeable: only this user may not take it.
      expect(find.text('TOMAR SOLICITUD'), findsOneWidget);
    });

    testWidgets('a 401 drops the session and returns to the login page', (
      tester,
    ) async {
      supportRequests
        ..requests = [buildSupportRequest()]
        ..assignFailure = const AuthFailure();
      await pumpConsole(tester);
      expect(storage.token, 'tecnico-jwt');

      await tapAssign(tester, requestId);

      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(DashboardPage), findsNothing);
      expect(storage.token, isNull);
    });

    testWidgets('a 401 while loading devices also ends the session', (
      tester,
    ) async {
      devices.failure = const AuthFailure();

      await pumpConsole(tester);

      expect(find.byType(LoginPage), findsOneWidget);
      expect(storage.token, isNull);
    });
  });

  group('refresh', () {
    testWidgets('ACTUALIZAR reloads devices and support requests', (
      tester,
    ) async {
      devices.devices = [buildDevice()];
      supportRequests.requests = [buildSupportRequest()];
      await pumpConsole(tester);

      await tester.tap(find.byKey(const Key('console_refresh_button')));
      await tester.pumpAndSettle();

      expect(devices.loadCount, 2);
      expect(supportRequests.loadCount, 2);
      // Refreshing must not re-validate the session.
      expect(auth.checkStatusTokens, hasLength(1));
    });

    testWidgets('an ASSIGNED request becomes ACCEPTED after refreshing', (
      tester,
    ) async {
      supportRequests
        ..requests = [
          buildSupportRequest(
            status: SupportRequestStatus.assigned,
            technician: technicianId,
          ),
        ]
        ..requestsAfterFirstLoad = [
          buildSupportRequest(
            status: SupportRequestStatus.accepted,
            technician: technicianId,
          ),
        ];
      await pumpConsole(tester);
      expect(
        find.text('Estado: Esperando autorización del usuario'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('support_refresh_button')));
      await tester.pumpAndSettle();

      expect(
        find.text('Estado: Usuario autorizó la asistencia'),
        findsOneWidget,
      );
      // An accepted request is what authorises starting an assistance.
      expect(find.text('INICIAR ASISTENCIA'), findsOneWidget);
    });

    testWidgets('a REJECTED request moves to the history', (tester) async {
      supportRequests
        ..requests = [
          buildSupportRequest(
            status: SupportRequestStatus.assigned,
            technician: technicianId,
          ),
        ]
        ..requestsAfterFirstLoad = [
          buildSupportRequest(
            status: SupportRequestStatus.rejected,
            technician: technicianId,
            closedAt: DateTime.utc(2026, 3, 11, 9, 32),
          ),
        ];
      await pumpConsole(tester);

      await tester.tap(find.byKey(const Key('support_refresh_button')));
      await tester.pumpAndSettle();

      expect(find.text('ASIGNADAS A TI (1)'), findsNothing);
      expect(find.text('HISTORIAL (1)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('support_history_tile')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Usuario rechazó la asistencia'),
        findsOneWidget,
      );
    });

    testWidgets('CANCELLED and COMPLETED are history too', (tester) async {
      supportRequests.requests = [
        buildSupportRequest(id: 'c', status: SupportRequestStatus.cancelled),
        buildSupportRequest(id: 'd', status: SupportRequestStatus.completed),
      ];

      await pumpConsole(tester);

      expect(find.text('HISTORIAL (2)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('support_history_tile')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Solicitud cancelada'), findsOneWidget);
      expect(find.textContaining('Asistencia finalizada'), findsOneWidget);
    });
  });

  group('security', () {
    testWidgets('the User JWT is never rendered', (tester) async {
      devices.devices = [buildDevice()];
      supportRequests.requests = [buildSupportRequest()];

      await pumpConsole(tester);

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => '${widget.data ?? ''}${widget.textSpan?.toPlainText() ?? ''}')
          .join('\n');
      expect(texts, isNot(contains('tecnico-jwt')));
      expect(texts, isNot(contains('Bearer')));
      expect(texts, isNot(contains('Authorization')));
    });
  });
}
