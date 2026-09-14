import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';

void main() {
  test('defaults to the local development backend', () {
    expect(AppConfig.defaultBackendBaseUrl, 'http://localhost:3000');
    // Without --dart-define=BACKEND_BASE_URL the default is used.
    expect(
      AppConfig.fromEnvironment().backendBaseUrl,
      const String.fromEnvironment(
        'BACKEND_BASE_URL',
        defaultValue: AppConfig.defaultBackendBaseUrl,
      ),
    );
  });

  test('normalises trailing slashes so paths are appended once', () {
    expect(
      const AppConfig(
        backendBaseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms/',
      ).normalizedBackendBaseUrl,
      'https://w4qb7jsw-3000.brs.devtunnels.ms',
    );
    expect(
      const AppConfig(backendBaseUrl: '  http://localhost:3000//  ')
          .normalizedBackendBaseUrl,
      'http://localhost:3000',
    );
  });

  test('carries the HTTP timeouts used by the client', () {
    const config = AppConfig(backendBaseUrl: 'http://localhost:3000');

    expect(config.connectTimeout, AppConfig.defaultConnectTimeout);
    expect(config.receiveTimeout, AppConfig.defaultReceiveTimeout);
    expect(config.sendTimeout, AppConfig.defaultSendTimeout);
  });
}
