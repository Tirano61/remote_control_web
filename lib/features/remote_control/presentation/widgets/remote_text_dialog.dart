import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/remote_control_command.dart';

/// Where the technician writes what goes to the field focused on the tablet.
///
/// A dialog that takes no route and puts up no barrier, shown over the picture by
/// whoever owns it. It has to leave two things reachable: the picture, which is the
/// only way to check the target, and FINALIZAR ASISTENCIA, which is never held back.
/// The owner holds back the other commands for as long as this exists, so nothing
/// the technician does moves the focus they confirmed.
///
/// The text lives in the controller of this widget and nowhere else. It is emptied
/// the moment it is handed over or abandoned, without waiting for any answer, and
/// it goes away with this widget in any other case: the owner removing it because
/// the session ended is all it takes.
class RemoteTextDialog extends StatefulWidget {
  const RemoteTextDialog({
    required this.canSend,
    required this.onSend,
    required this.onCancel,
    super.key,
  });

  /// Whether a text can go out right now.
  final bool canSend;

  /// Called with exactly what was written, or `''` to empty the field. The owner
  /// closes the dialog.
  final ValueChanged<String> onSend;

  /// The owner closes the dialog.
  final VoidCallback onCancel;

  @override
  State<RemoteTextDialog> createState() => _RemoteTextDialogState();
}

class _RemoteTextDialogState extends State<RemoteTextDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send(String text) {
    _controller.clear();
    widget.onSend(text);
  }

  void _cancel() {
    _controller.clear();
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
      child: AlertDialog(
        key: const Key('remote_text_dialog'),
        alignment: Alignment.centerRight,
        insetPadding: const EdgeInsets.all(8),
        scrollable: true,
        title: const Text('Enviar texto al campo enfocado'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Confirme en la pantalla remota que el campo correcto está '
                'seleccionado.',
              ),
              const SizedBox(height: 8),
              const Text('El texto enviado reemplazará todo su contenido.'),
              const SizedBox(height: 12),
              ValueListenableBuilder(
                valueListenable: _controller,
                builder: (context, value, _) {
                  // Counted by `String.length`, the UTF-16 code units of the
                  // contract. A formatter limiting the input could count something
                  // else, and would cut what was pasted without saying so.
                  final length = value.text.length;
                  return TextField(
                    key: const Key('remote_text_field'),
                    controller: _controller,
                    autofocus: true,
                    keyboardType: TextInputType.multiline,
                    minLines: 3,
                    maxLines: 6,
                    autocorrect: false,
                    enableSuggestions: false,
                    // Null, not the default empty list, which still enables
                    // autofill: the browser would get autocomplete="on", and the
                    // web engine would keep the element with the text in the page
                    // after this widget is gone, waiting for that context to end.
                    autofillHints: null,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      counterText: '$length / $maxRemoteTextLength',
                      errorText: RemoteSetTextCommand.fits(value.text)
                          ? null
                          : 'El texto supera el máximo de '
                                '$maxRemoteTextLength caracteres.',
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('remote_text_cancel_button'),
            onPressed: _cancel,
            child: const Text('Cancelar'),
          ),
          OutlinedButton(
            key: const Key('remote_text_clear_button'),
            onPressed: widget.canSend ? () => _send('') : null,
            child: const Text('Vaciar campo'),
          ),
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, value, _) {
              final text = value.text;
              final canSendText =
                  widget.canSend &&
                  text.isNotEmpty &&
                  RemoteSetTextCommand.fits(text);
              return FilledButton(
                key: const Key('remote_text_send_button'),
                onPressed: canSendText ? () => _send(_controller.text) : null,
                child: const Text('Enviar texto'),
              );
            },
          ),
        ],
      ),
    );
  }
}
