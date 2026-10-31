import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

// The receiver's small preview stream: 640x360 RGBA frames, about 15 per second. Same pipe as
// \\.\pipe\camnexo-preview. Dart treats a leading "\\." as a network share and fails with
// "network path not found", so use the equivalent \\?\ spelling.
const _pipePath = r'\\?\pipe\camnexo-preview';
const _magic = 0x46584E43; // "CNXF", must match native/windows/vcam/src/frame_pipe.h
const _width = 640;
const _height = 360;

/// Shows the picture the virtual camera is sending. A background isolate reads the receiver's
/// preview pipe and hands every frame over; the full-size picture never passes through here.
class PreviewReader {
  final _images = StreamController<ui.Image>.broadcast();
  Isolate? _isolate;
  ReceivePort? _port;

  Stream<ui.Image> get images => _images.stream;

  Future<void> start() async {
    final port = ReceivePort();
    _port = port;
    _isolate = await Isolate.spawn(_readLoop, port.sendPort);
    port.listen((message) {
      if (message is TransferableTypedData) {
        final pixels = message.materialize().asUint8List();
        ui.decodeImageFromPixels(pixels, _width, _height, ui.PixelFormat.rgba8888, (image) {
          if (_images.isClosed) {
            image.dispose();
          } else {
            _images.add(image);
          }
        });
      }
    });
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _port?.close();
    _images.close();
  }
}

// Reads must be asynchronous. A blocking readIntoSync that waits for a phone which stopped
// streaming stalls the Dart VM's memory management, and the whole window freezes ("Not
// Responding") until the pipe closes. Measured: an 11.9 s main-thread stall with the blocking
// read, 0.1 s with this one.
Future<bool> _readFully(RandomAccessFile f, Uint8List buf) async {
  var off = 0;
  while (off < buf.length) {
    final n = await f.readInto(buf, off, buf.length);
    if (n <= 0) return false;
    off += n;
  }
  return true;
}

Future<void> _readLoop(SendPort out) async {
  final header = Uint8List(24);
  for (;;) {
    RandomAccessFile? f;
    try {
      f = await File(_pipePath).open();
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      continue;
    }
    try {
      while (await _readFully(f, header)) {
        final h = header.buffer.asByteData();
        if (h.getUint32(0, Endian.little) != _magic ||
            h.getUint32(4, Endian.little) != _width ||
            h.getUint32(8, Endian.little) != _height) {
          break;
        }
        // A fresh buffer per frame: it is handed to the UI isolate without copying.
        final pixels = Uint8List(_width * _height * 4);
        if (!await _readFully(f, pixels)) break;
        out.send(TransferableTypedData.fromList([pixels]));
      }
    } catch (_) {
      // the receiver went away; reconnect below
    } finally {
      try {
        await f.close();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
