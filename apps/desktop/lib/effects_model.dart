/// What happens to the background behind the person.
enum BackgroundMode { none, blur, image }

/// A ready-made background picture shipped with the app (`assets/backgrounds/ID.jpg`).
class BuiltInBackground {
  const BuiltInBackground(this.id, this.name);

  final String id;
  final String name;
}

const List<BuiltInBackground> builtInBackgrounds = [
  BuiltInBackground('aurora', 'Aurora'),
  BuiltInBackground('sunset', 'Sunset'),
  BuiltInBackground('ocean', 'Ocean'),
  BuiltInBackground('forest', 'Forest'),
  BuiltInBackground('graphite', 'Graphite'),
  BuiltInBackground('studio', 'Studio'),
  BuiltInBackground('office', 'Office'),
  BuiltInBackground('paper', 'Paper'),
];

/// A ready-made colour look: it sets the four sliders.
class LookPreset {
  const LookPreset(this.id, this.name, {this.brightness = 0, this.contrast = 0, this.saturation = 0, this.warmth = 0});

  final String id;
  final String name;
  final int brightness;
  final int contrast;
  final int saturation;
  final int warmth;
}

const List<LookPreset> lookPresets = [
  LookPreset('natural', 'Natural'),
  LookPreset('bright', 'Bright', brightness: 16, contrast: 6, saturation: 8),
  LookPreset('vivid', 'Vivid', contrast: 12, saturation: 32, warmth: 4),
  LookPreset('warm', 'Warm', brightness: 4, saturation: 6, warmth: 30),
  LookPreset('cool', 'Cool', warmth: -30, saturation: 4),
  LookPreset('soft', 'Soft', brightness: 8, contrast: -14, saturation: -6, warmth: 6),
  LookPreset('cinema', 'Cinema', brightness: -4, contrast: 22, saturation: -14, warmth: 12),
  LookPreset('mono', 'Mono', contrast: 14, saturation: -100),
];

/// The effects chosen for one camera.
class CameraEffects {
  const CameraEffects({
    this.background = BackgroundMode.none,
    this.blur = 60,
    this.builtIn = 'aurora',
    this.customImage,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
  });

  final BackgroundMode background;

  /// 0..100
  final int blur;

  /// The ready-made background in use, unless [customImage] is set.
  final String builtIn;

  /// A picture chosen from disk (full path).
  final String? customImage;

  /// -100..100 each
  final int brightness;
  final int contrast;
  final int saturation;
  final int warmth;

  bool get hasFilters => brightness != 0 || contrast != 0 || saturation != 0 || warmth != 0;
  bool get isOff => background == BackgroundMode.none && !hasFilters;

  /// The look whose sliders match, or null for a custom mix.
  LookPreset? get look {
    for (final p in lookPresets) {
      if (p.brightness == brightness && p.contrast == contrast && p.saturation == saturation && p.warmth == warmth) {
        return p;
      }
    }
    return null;
  }

  CameraEffects copyWith({
    BackgroundMode? background,
    int? blur,
    String? builtIn,
    String? customImage,
    bool clearCustomImage = false,
    int? brightness,
    int? contrast,
    int? saturation,
    int? warmth,
  }) =>
      CameraEffects(
        background: background ?? this.background,
        blur: blur ?? this.blur,
        builtIn: builtIn ?? this.builtIn,
        customImage: clearCustomImage ? null : (customImage ?? this.customImage),
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
      );

  CameraEffects withLook(LookPreset p) =>
      copyWith(brightness: p.brightness, contrast: p.contrast, saturation: p.saturation, warmth: p.warmth);

  /// Only the colour settings of [other] (used to copy a look to all cameras).
  Map<String, Object?> toJson() => {
        'bg': background.name,
        'blur': blur,
        'builtIn': builtIn,
        if (customImage != null) 'image': customImage,
        'b': brightness,
        'c': contrast,
        's': saturation,
        'w': warmth,
      };

  static CameraEffects fromJson(Map<String, Object?> j) => CameraEffects(
        background: BackgroundMode.values.firstWhere((m) => m.name == j['bg'], orElse: () => BackgroundMode.none),
        blur: ((j['blur'] as num?) ?? 60).toInt().clamp(0, 100),
        builtIn: (j['builtIn'] as String?) ?? 'aurora',
        customImage: j['image'] as String?,
        brightness: ((j['b'] as num?) ?? 0).toInt().clamp(-100, 100),
        contrast: ((j['c'] as num?) ?? 0).toInt().clamp(-100, 100),
        saturation: ((j['s'] as num?) ?? 0).toInt().clamp(-100, 100),
        warmth: ((j['w'] as num?) ?? 0).toInt().clamp(-100, 100),
      );

  @override
  bool operator ==(Object other) =>
      other is CameraEffects &&
      other.background == background &&
      other.blur == blur &&
      other.builtIn == builtIn &&
      other.customImage == customImage &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.warmth == warmth;

  @override
  int get hashCode => Object.hash(background, blur, builtIn, customImage, brightness, contrast, saturation, warmth);
}
