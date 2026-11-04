import 'dart:convert';

import '../domain/entities/remote_control_ack.dart';
import '../domain/entities/remote_control_command.dart';

/// The only place where the `control` channel protocol exists as JSON.
///
/// It is an agreement with `remote_control_device`, carried peer to peer: the
/// backend never sees it. See `docs/CONTROL_CHANNEL.md`.
class RemoteControlChannelCodec {
  const RemoteControlChannelCodec._();

  static const int _version = 1;

  static const String _versionKey = 'v';
  static const String _typeKey = 'type';
  static const String _idKey = 'id';
  static const String _xKey = 'x';
  static const String _yKey = 'y';
  static const String _startXKey = 'startX';
  static const String _startYKey = 'startY';
  static const String _endXKey = 'endX';
  static const String _endYKey = 'endY';
  static const String _durationMsKey = 'durationMs';
  static const String _textKey = 'text';
  static const String _okKey = 'ok';
  static const String _errorKey = 'error';

  static const String _tapType = 'tap';
  static const String _swipeType = 'swipe';
  static const String _backType = 'back';
  static const String _homeType = 'home';
  static const String _recentsType = 'recents';
  static const String _setTextType = 'set_text';
  static const String _ackType = 'ack';

  /// The frame for [command], with exactly the fields of the protocol. It may hold
  /// a text the technician typed, so it is never logged.
  static String encode(RemoteControlCommand command) => switch (command) {
    RemoteTapCommand(:final id, :final point) => jsonEncode({
      _versionKey: _version,
      _typeKey: _tapType,
      _idKey: id,
      _xKey: point.x,
      _yKey: point.y,
    }),
    RemoteSwipeCommand(
      :final id,
      :final start,
      :final end,
      :final durationMs,
    ) =>
      jsonEncode({
        _versionKey: _version,
        _typeKey: _swipeType,
        _idKey: id,
        _startXKey: start.x,
        _startYKey: start.y,
        _endXKey: end.x,
        _endYKey: end.y,
        _durationMsKey: durationMs,
      }),
    RemoteBackCommand(:final id) => jsonEncode({
      _versionKey: _version,
      _typeKey: _backType,
      _idKey: id,
    }),
    RemoteHomeCommand(:final id) => jsonEncode({
      _versionKey: _version,
      _typeKey: _homeType,
      _idKey: id,
    }),
    RemoteRecentsCommand(:final id) => jsonEncode({
      _versionKey: _version,
      _typeKey: _recentsType,
      _idKey: id,
    }),
    RemoteSetTextCommand(:final id, :final text) => jsonEncode({
      _versionKey: _version,
      _typeKey: _setTextType,
      _idKey: id,
      _textKey: text,
    }),
  };

  /// The acknowledgement in [frame], or `null` when it is not a valid one.
  ///
  /// Never throws: the frame comes from the other end, and whatever it holds is
  /// ignored rather than trusted.
  static RemoteControlAck? decodeAck(String frame) {
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final version = decoded[_versionKey];
    if (version is! num || version != _version) return null;
    if (decoded[_typeKey] != _ackType) return null;

    final id = decoded[_idKey];
    if (id is! String || id.isEmpty) return null;

    final ok = decoded[_okKey];
    if (ok is! bool) return null;
    if (ok) return RemoteControlAck(commandId: id);

    final code = decoded[_errorKey];
    if (code is! String) return null;
    // A code from a newer tablet still says the command failed. Treating it as
    // invalid would leave the technician waiting for the timeout instead.
    return RemoteControlAck(
      commandId: id,
      error: RemoteControlError.fromCode(code),
    );
  }
}
