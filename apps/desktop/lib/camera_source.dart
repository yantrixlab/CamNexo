import 'effects_model.dart';

/// A picture size the phone can capture and encode.
class Resolution {
  const Resolution(this.width, this.height);

  final int width;
  final int height;

  /// Common name for the size, like "Full HD".
  String get name => switch (height) {
        2160 => '4K',
        1440 => '2K',
        1080 => 'Full HD',
        720 => 'HD',
        540 => 'qHD',
        360 => '360p',
        _ => '${height}p',
      };

  /// Short form for the top bar, like "1080p" or "4K".
  String get shortName => switch (height) {
        2160 => '4K',
        1440 => '1440p',
        _ => '${height}p',
      };

  String get dimensions => '$width × $height';

  @override
  bool operator ==(Object other) => other is Resolution && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// One connected phone (or a simulated test camera) and what is known about it.
class CameraSource {
  CameraSource({required this.id, required this.key, required this.address});

  /// Number the receiver gave it for this connection. It changes when the phone reconnects.
  final int id;

  /// Stays the same when the same phone reconnects (its network address). Layouts and saved
  /// settings refer to this.
  final String key;
  final String address;

  String name = '';
  String? streamSize;
  bool streaming = false;
  int fps = 0;
  int kbps = 0;
  int decodeErrors = 0;
  int rotation = 0;

  List<Resolution> resolutions = const [];
  Resolution? currentResolution;
  bool resolutionAuto = true;

  bool flip = false; // turn the picture 180 degrees (a phone mounted upside down)
  bool visible = true; // shown in the layout

  /// Background blur or replacement and colour filters chosen for this camera.
  CameraEffects effects = const CameraEffects();

  /// Size to apply once the phone reports its sizes (restored from an earlier session).
  Resolution? pendingResolution;

  bool get isSimulated => key.startsWith('simulated');

  /// Name for people: the phone model when known.
  String get label => name.isNotEmpty ? name : 'Camera $id';
}
