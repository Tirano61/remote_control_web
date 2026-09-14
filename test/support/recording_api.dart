import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/core/network/dio_api_client.dart';

/// Captures the outgoing request and answers with a canned response, so the
/// exact wire format can be asserted against `docs/backend/ENDPOINTS.md`.
class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter({this.statusCode = 200, this.body = '{}'});

  int statusCode;
  String body;
  RequestOptions? captured;

  /// Raw bytes actually put on the wire, or `null` when no body was sent.
  String? capturedBody;

  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    captured = options;
    capturedBody = requestStream == null
        ? null
        : String.fromCharCodes(
            (await requestStream.toList()).expand((chunk) => chunk),
          );
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Builds a [DioApiClient] wired to a [RecordingAdapter].
({DioApiClient client, RecordingAdapter adapter}) buildRecordingClient({
  String baseUrl = 'http://localhost:3000',
  int statusCode = 200,
  String body = '{}',
}) {
  final adapter = RecordingAdapter(statusCode: statusCode, body: body);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    client: DioApiClient(
      config: AppConfig(backendBaseUrl: baseUrl),
      dio: dio,
    ),
    adapter: adapter,
  );
}
