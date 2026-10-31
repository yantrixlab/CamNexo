import 'package:flutter/services.dart';

/// One event from the native streaming module (camera -> H.264 -> TCP).
class StreamStatus {
  const StreamStatus({
    required this.state,
    this.message,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.kbps = 0,
    this.dropped = 0,
    this.minZoom,
    this.maxZoom,
    this.orientation,
    this.flip = false,
  });

  /// connecting | streaming | stats | error | idle
  final String state;
  final String? message;
  final int width;
  final int height;
  final int fps;
  final int kbps;
  final int dropped;
  final double? minZoom;
  final double? maxZoom;

  /// auto | landscape | portrait: how the computer asked the picture to be oriented.
  final String? orientation;
  final bool flip;

  factory StreamStatus.fromMap(Map<dynamic, dynamic> m) => StreamStatus(
        state: m['state'] as String,
        message: m['message'] as String?,
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        fps: (m['fps'] as num?)?.toInt() ?? 0,
        kbps: (m['kbps'] as num?)?.toInt() ?? 0,
        dropped: (m['dropped'] as num?)?.toInt() ?? 0,
        minZoom: (m['minZoom'] as num?)?.toDouble(),
        maxZoom: (m['maxZoom'] as num?)?.toDouble(),
        orientation: m['orientation'] as String?,
        flip: (m['flip'] as bool?) ?? false,
      );
}

/// Thin wrapper over the `camnexo/stream` platform channels.
class StreamBridge {
  static const _method = MethodChannel('camnexo/stream');
  static const _events = EventChannel('camnexo/stream/events');

  Stream<StreamStatus> get status => _events
      .receiveBroadcastStream()
      .map((e) => StreamStatus.fromMap(e as Map<dynamic, dynamic>));

  /// Resolution and orientation are controlled from the computer after connecting.
  Future<void> start({
    required String host,
    required int port,
    required bool front,
  }) =>
      _method.invokeMethod('start', {
        'host': host,
        'port': port,
        'front': front,
      });

  Future<void> stop() => _method.invokeMethod('stop');
  /// Changes between the front and back camera while streaming.
  Future<void> switchCamera({required bool front}) =>
      _method.invokeMethod('switchCamera', {'front': front});
  Future<void> setTorch(bool on) => _method.invokeMethod('setTorch', {'on': on});
  Future<void> setZoom(double ratio) =>
      _method.invokeMethod('setZoom', {'ratio': ratio});
}
