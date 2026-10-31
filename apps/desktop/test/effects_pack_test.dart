import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camnexo_desktop/effects_pack.dart';

/// Makes a small zip with the layout of the real pack (the real one is 27 MB), and serves it.
Future<({EffectsPackSpec spec, HttpServer server, Directory work})> _serve({int status = 200, bool corrupt = false}) async {
  final work = Directory.systemTemp.createTempSync('camnexo_pack_test');
  final src = Directory('${work.path}/src')..createSync();
  Directory('${src.path}/models').createSync();
  File('${src.path}/onnxruntime.dll').writeAsBytesSync(List.filled(4000, 7));
  File('${src.path}/onnxruntime_providers_shared.dll').writeAsBytesSync(List.filled(500, 3));
  File('${src.path}/models/modnet.onnx').writeAsBytesSync(List.generate(9000, (i) => i % 251));
  final zip = File('${work.path}/pack.zip');
  final tar = '${Platform.environment['SystemRoot']}\\System32\\tar.exe';
  final r = Process.runSync(tar, ['-a', '-c', '-f', zip.path, '-C', src.path, 'onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'models']);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  final bytes = zip.readAsBytesSync();
  final spec = EffectsPackSpec(url: 'unused', sha256: sha256.convert(bytes).toString(), size: bytes.length);

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.statusCode = status;
    if (status == 200) {
      final body = corrupt ? (List<int>.of(bytes)..[bytes.length ~/ 2] ^= 0xFF) : bytes;
      req.response.contentLength = body.length;
      req.response.add(body);
    }
    await req.response.close();
  });
  return (spec: spec, server: server, work: work);
}

void main() {
  test('downloads the pack, checks it and puts the files in place', () async {
    final s = await _serve();
    addTearDown(() async {
      await s.server.close(force: true);
      s.work.deleteSync(recursive: true);
    });
    final dir = '${s.work.path}/installed/effects';
    final pack = EffectsPack(dir: dir, spec: s.spec, urlOverride: 'http://127.0.0.1:${s.server.port}/pack.zip');
    expect(pack.installed, isFalse);

    var lastReceived = 0;
    var installingCalled = false;
    await pack.download(onProgress: (got, total) => lastReceived = got, onInstalling: () => installingCalled = true);

    expect(lastReceived, s.spec.size);
    expect(installingCalled, isTrue);
    expect(pack.installed, isTrue);
    expect(File('$dir/models/modnet.onnx').lengthSync(), 9000);
    expect(File('$dir/onnxruntime.dll').lengthSync(), 4000);
    expect(Directory('$dir.download').existsSync(), isFalse, reason: 'the working folder is cleaned up');
  });

  test('a download that does not match the published checksum is refused and nothing is installed', () async {
    final s = await _serve(corrupt: true);
    addTearDown(() async {
      await s.server.close(force: true);
      s.work.deleteSync(recursive: true);
    });
    final dir = '${s.work.path}/installed/effects';
    final pack = EffectsPack(dir: dir, spec: s.spec, urlOverride: 'http://127.0.0.1:${s.server.port}/pack.zip');

    await expectLater(pack.download(), throwsA(isA<EffectsPackException>().having((e) => e.message, 'message', contains('did not match'))));
    expect(pack.installed, isFalse);
    expect(Directory(dir).existsSync(), isFalse);
    expect(Directory('$dir.download').existsSync(), isFalse);
  });

  test('a server error is reported in plain words', () async {
    final s = await _serve(status: 404);
    addTearDown(() async {
      await s.server.close(force: true);
      s.work.deleteSync(recursive: true);
    });
    final pack = EffectsPack(dir: '${s.work.path}/installed/effects', spec: s.spec, urlOverride: 'http://127.0.0.1:${s.server.port}/pack.zip');
    await expectLater(pack.download(), throwsA(isA<EffectsPackException>().having((e) => e.message, 'message', contains('404'))));
  });

  test('no connection is reported in plain words', () async {
    final s = await _serve();
    final port = s.server.port;
    await s.server.close(force: true); // nothing listens on this port any more
    addTearDown(() => s.work.deleteSync(recursive: true));
    final pack = EffectsPack(dir: '${s.work.path}/installed/effects', spec: s.spec, urlOverride: 'http://127.0.0.1:$port/pack.zip');
    await expectLater(pack.download(), throwsA(isA<EffectsPackException>().having((e) => e.message, 'message', contains('Could not reach'))));
  });

  test('the pinned spec is a SHA-256 and a size', () {
    expect(effectsPackSpec.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(effectsPackSpec.size, greaterThan(1000000));
    expect(effectsPackSpec.url, startsWith('https://'));
  });
}
