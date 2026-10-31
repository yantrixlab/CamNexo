import 'package:flutter/services.dart';

/// A computer running the CamNexo desktop app, found on the local network.
class DiscoveredPc {
  const DiscoveredPc({required this.name, required this.host, required this.port});

  /// The service name the computer announces, for example "CamNexo-Satellite".
  final String name;
  final String host;
  final int port;

  /// The announced name without the " (2)" style suffix Windows adds when an older announcement
  /// of the same name is still around on the network.
  static String baseOf(String name) => name.replaceFirst(RegExp(r'\s*\(\d+\)$'), '');

  String get baseName => baseOf(name);

  /// Name without the "CamNexo-" prefix, for showing to people.
  String get displayName => baseName.startsWith('CamNexo-') ? baseName.substring(8) : baseName;
}

/// found | lost | error
class DiscoveryEvent {
  const DiscoveryEvent({required this.type, this.pc, this.name, this.message});

  final String type;
  final DiscoveredPc? pc;
  final String? name;
  final String? message;

  factory DiscoveryEvent.fromMap(Map<dynamic, dynamic> m) {
    final type = m['type'] as String;
    if (type == 'found') {
      return DiscoveryEvent(
        type: type,
        name: m['name'] as String,
        pc: DiscoveredPc(
          name: m['name'] as String,
          host: m['host'] as String,
          port: (m['port'] as num).toInt(),
        ),
      );
    }
    return DiscoveryEvent(
      type: type,
      name: m['name'] as String?,
      message: m['message'] as String?,
    );
  }
}

/// Thin wrapper over the `camnexo/discovery` platform channels (Android NsdManager).
class DiscoveryBridge {
  static const _method = MethodChannel('camnexo/discovery');
  static const _events = EventChannel('camnexo/discovery/events');

  Stream<DiscoveryEvent> get events => _events
      .receiveBroadcastStream()
      .map((e) => DiscoveryEvent.fromMap(e as Map<dynamic, dynamic>));

  Future<void> start() => _method.invokeMethod('start');
  Future<void> stop() => _method.invokeMethod('stop');
}
