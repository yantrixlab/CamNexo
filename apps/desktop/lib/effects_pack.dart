import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The effects pack: ONNX Runtime and the person-matting model that background blur and replacement
/// need. They are not in the installer (that keeps it small); the app downloads this zip once, the first
/// time someone turns Effects on, and keeps it in the user's own folder.
///
/// The address, size and SHA-256 are fixed here, so only the file we published is ever installed.
/// Build and publish a new pack with installer/windows/make-effects-pack.ps1.
class EffectsPackSpec {
  const EffectsPackSpec({required this.url, required this.sha256, required this.size});

  final String url;
  final String sha256;
  final int size;
}

const effectsPackSpec = EffectsPackSpec(
  url: 'https://camnexo.yantrixlab.com/downloads/effects/CamNexo-Effects-1.zip',
  sha256: 'dae3f0f94f943af5bd4dbd65f78e13c46a5ac0e7fb88eeefa5815620ac469b30',
  size: 28683814,
);

/// What the pack must contain once unpacked (paths relative to the pack folder).
const effectsPackFiles = ['onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'models/modnet.onnx'];

/// A problem that can be shown to the person as it is.
class EffectsPackException implements Exception {
  EffectsPackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class EffectsPack {
  EffectsPack({String? dir, EffectsPackSpec? spec, String? urlOverride})
      : dir = dir ?? defaultDir(),
        spec = spec ?? effectsPackSpec,
        _url = urlOverride ?? Platform.environment['CAMNEXO_EFFECTS_URL'];

  /// Where the pack lives: %LOCALAPPDATA%\CamNexo\effects. The receiver looks in the same place.
  static String defaultDir() {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return '$base${Platform.pathSeparator}CamNexo${Platform.pathSeparator}effects';
  }

  final String dir;
  final EffectsPackSpec spec;

  /// For testing a pack from another address (the SHA-256 must still match).
  final String? _url;

  HttpClient? _client;
  bool _cancelled = false;

  String _path(String relative) => '$dir${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

  bool get installed => effectsPackFiles.every((f) => File(_path(f)).existsSync());

  /// Stops a download in progress; [download] then throws.
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  /// Downloads, checks and unpacks the pack. [onProgress] gets (bytes received, bytes expected); [onInstalling]
  /// is called when the download is complete and the files are being put in place.
  Future<void> download({void Function(int received, int total)? onProgress, void Function()? onInstalling}) async {
    _cancelled = false;
    final work = Directory('$dir.download');
    final zip = File('${work.path}${Platform.pathSeparator}pack.zip');
    final unpacked = Directory('${work.path}${Platform.pathSeparator}files');
    try {
      if (work.existsSync()) work.deleteSync(recursive: true);
      work.createSync(recursive: true);
      await _fetch(zip, onProgress);
      onInstalling?.call();
      unpacked.createSync();
      // tar.exe (bsdtar) is part of Windows 10 and later, and refuses paths that leave the folder.
      final r = await Process.run('${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\tar.exe',
          ['-xf', zip.path, '-C', unpacked.path]);
      if (r.exitCode != 0) throw EffectsPackException('The download could not be unpacked. ${r.stderr}'.trim());
      for (final f in effectsPackFiles) {
        if (!File('${unpacked.path}${Platform.pathSeparator}${f.replaceAll('/', Platform.pathSeparator)}').existsSync()) {
          throw EffectsPackException('The download is incomplete ($f is missing).');
        }
      }
      final target = Directory(dir);
      if (target.existsSync()) target.deleteSync(recursive: true);
      target.parent.createSync(recursive: true);
      unpacked.renameSync(dir);
    } on EffectsPackException {
      rethrow;
    } on FileSystemException catch (e) {
      throw EffectsPackException('Could not save the files: ${e.message}');
    } finally {
      _client = null;
      try {
        if (work.existsSync()) work.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _fetch(File zip, void Function(int received, int total)? onProgress) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    final out = zip.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final request = await client.getUrl(Uri.parse(_url ?? spec.url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw EffectsPackException('The server answered ${response.statusCode}. Try again in a moment.');
      }
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        out.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds >= 100) {
          lastReport = now;
          onProgress?.call(received, spec.size);
        }
      }
      await out.flush();
      onProgress?.call(received, spec.size);
    } on EffectsPackException {
      rethrow;
    } on TimeoutException {
      throw EffectsPackException('The connection stalled. Check your internet and try again.');
    } on SocketException catch (_) {
      throw EffectsPackException(_cancelled ? 'Cancelled.' : 'Could not reach the download server. Check your internet and try again.');
    } on HttpException catch (_) {
      throw EffectsPackException(_cancelled ? 'Cancelled.' : 'The download was interrupted. Try again.');
    } finally {
      await out.close();
      client.close(force: true);
    }
    if (_cancelled) throw EffectsPackException('Cancelled.');
    hasher.close();
    if (received != spec.size || digestSink.value.toString() != spec.sha256) {
      throw EffectsPackException('The download did not match what we published, so it was not installed. Try again.');
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
