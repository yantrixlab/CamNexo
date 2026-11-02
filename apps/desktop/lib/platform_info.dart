import 'dart:io';

/// What differs between the desktop platforms: the names of the helper programs, where files live,
/// and the wording of the virtual camera instructions.

String get receiverExeName => Platform.isWindows ? 'camnexo_receiver.exe' : 'camnexo_receiver';

/// The Unix socket the Linux receiver offers its small preview frames on. The app passes this path to the
/// receiver and reads from it, so both always agree.
String previewSocketPath() {
  final run = Platform.environment['XDG_RUNTIME_DIR'];
  if (run != null && run.isNotEmpty) return '$run/camnexo-preview.sock';
  final user = Platform.environment['USER'] ?? 'user';
  return '${Directory.systemTemp.path}/camnexo-$user-preview.sock';
}

/// Loads the virtual camera module on Linux, as the card in the window shows it.
const linuxCameraCommand = 'sudo modprobe v4l2loopback devices=1 video_nr=10 card_label=CamNexo exclusive_caps=1';

/// The line above the setup command.
String get cameraSetupIntro => Platform.isLinux
    ? 'The virtual camera module is not loaded. Run this in a terminal (it asks for your password). '
        'If it says the module was not found, first install it with: sudo apt install v4l2loopback-dkms'
    : 'Open PowerShell as administrator, run this, then restart CamNexo:';

/// What to pick in a video app.
String get cameraChoiceHint => Platform.isLinux
    ? 'In Zoom, Meet, Teams or OBS, choose "CamNexo".'
    : 'In Zoom, Meet, Teams or OBS, choose "CamNexo (Windows Virtual Camera)".';
