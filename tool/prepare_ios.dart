import 'dart:io';

void main() {
  final iosDir = Directory('ios');
  if (!iosDir.existsSync()) {
    stderr.writeln('HATA: ios klasoru yok.');
    exitCode = 1;
    return;
  }

  patchInfoPlist();
  patchPodfile();
  patchDeploymentTarget();

  if (exitCode == 0) {
    stdout.writeln('iOS ayarlari hazirlandi.');
  }
}

void patchInfoPlist() {
  final file = File('ios/Runner/Info.plist');
  if (!file.existsSync()) {
    stderr.writeln('HATA: ios/Runner/Info.plist bulunamadi.');
    exitCode = 1;
    return;
  }

  var text = file.readAsStringSync();

  final displayNamePattern = RegExp(
    r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)',
  );
  if (displayNamePattern.hasMatch(text)) {
    text = text.replaceFirstMapped(
      displayNamePattern,
      (m) => '${m.group(1)}DHT11 Monitor${m.group(2)}',
    );
  }

  final additions = <String>[];

  void addKey(String key, String value) {
    if (!text.contains('<key>$key</key>')) {
      additions.add('\n\t<key>$key</key>\n\t<string>$value</string>');
    }
  }

  addKey(
    'NSBluetoothAlwaysUsageDescription',
    'DHT11 Monitor, ESP32 sicaklik ve nem sensorune Bluetooth Low Energy ile baglanmak icin Bluetooth erisimi kullanir.',
  );
  addKey(
    'NSBluetoothPeripheralUsageDescription',
    'DHT11 Monitor, ESP32 BLE sensoru ile iletisim kurmak icin Bluetooth erisimi kullanir.',
  );
  addKey(
    'NSLocationWhenInUseUsageDescription',
    'DHT11 Monitor, hava durumunu bulundugunuz konuma gore gostermek icin uygulama acikken konumunuzu kullanir.',
  );

  if (!text.contains('<key>CFBundleDisplayName</key>')) {
    additions.add('\n\t<key>CFBundleDisplayName</key>\n\t<string>DHT11 Monitor</string>');
  }

  if (additions.isNotEmpty) {
    final closingIndex = text.lastIndexOf('</dict>');
    if (closingIndex < 0) {
      stderr.writeln('HATA: Info.plist ana </dict> etiketi bulunamadi.');
      exitCode = 1;
      return;
    }

    text = '${text.substring(0, closingIndex)}${additions.join()}\n${text.substring(closingIndex)}';
  }

  file.writeAsStringSync(text);
}

void patchPodfile() {
  final file = File('ios/Podfile');
  if (!file.existsSync()) {
    stdout.writeln('Bilgi: ios/Podfile yok. Yeni Flutter iOS Swift Package Manager yapisinda bu normal olabilir; Podfile ayari atlaniyor.');
    return;
  }

  var text = file.readAsStringSync();

  final platformPattern = RegExp(
    r"^#?\s*platform\s+:ios,\s*'[^']+'",
    multiLine: true,
  );
  if (platformPattern.hasMatch(text)) {
    text = text.replaceFirst(platformPattern, "platform :ios, '13.0'");
  } else {
    text = "platform :ios, '13.0'\n\n$text";
  }

  const flutterSettings = 'flutter_additional_ios_build_settings(target)';
  const macroMarker = 'BYPASS_PERMISSION_LOCATION_ALWAYS=1';

  if (text.contains(flutterSettings) && !text.contains(macroMarker)) {
    text = text.replaceFirst(
      flutterSettings,
      '''$flutterSettings

    # DHT11 Monitor only needs foreground location.
    if target.name == 'geolocator_apple'
      target.build_configurations.each do |config|
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['\$(inherited)']
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] << '$macroMarker'
      end
    end''',
    );
  }

  file.writeAsStringSync(text);
}

void patchDeploymentTarget() {
  final pbx = File('ios/Runner.xcodeproj/project.pbxproj');
  if (pbx.existsSync()) {
    var text = pbx.readAsStringSync();
    text = text.replaceAll(
      RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;'),
      'IPHONEOS_DEPLOYMENT_TARGET = 13.0;',
    );
    pbx.writeAsStringSync(text);
  }

  final frameworkInfo = File('ios/Flutter/AppFrameworkInfo.plist');
  if (frameworkInfo.existsSync()) {
    var text = frameworkInfo.readAsStringSync();
    text = text.replaceAll(
      RegExp(r'<key>MinimumOSVersion</key>\s*<string>[^<]+</string>'),
      '<key>MinimumOSVersion</key>\n  <string>13.0</string>',
    );
    frameworkInfo.writeAsStringSync(text);
  }
}
