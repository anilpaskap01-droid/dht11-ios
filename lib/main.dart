import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Dht11MonitorApp());
}

class Dht11MonitorApp extends StatelessWidget {
  const Dht11MonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DHT11 Monitor',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF70E1F5),
          secondary: Color(0xFF8B7CFF),
          tertiary: Color(0xFF42E59B),
          surface: Color(0xFF0C1420),
          error: Color(0xFFFF6B7A),
        ),
        scaffoldBackgroundColor: const Color(0xFF050A11),
        navigationBarTheme: const NavigationBarThemeData(
          height: 72,
          backgroundColor: Color(0xFF08111C),
          indicatorColor: Color(0xFF16364A),
          labelTextStyle: WidgetStatePropertyAll(
            TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 11.5,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0D1724),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF1E344A)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF1A2B3D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF70E1F5)),
          ),
        ),
      ),
      home: const AppBootstrap(),
    );
  }
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  late final AppController controller;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    controller = AppController();
    controller.initialize().then((_) {
      if (mounted) setState(() => ready = true);
    });
  }

  @override
  void dispose() {
    controller.disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return HomePage(controller: controller);
  }
}

// -----------------------------------------------------------------------------
// APP CONTROLLER
// -----------------------------------------------------------------------------

class AppController extends ChangeNotifier {
  static final Guid environmentalService = Guid('181A');
  static final Guid temperatureUuid = Guid('2A6E');
  static final Guid humidityUuid = Guid('2A6F');

  SharedPreferences? _prefs;

  String? selectedDeviceId;
  String? selectedDeviceName;
  BluetoothDevice? selectedRuntimeDevice;

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? temperatureCharacteristic;
  BluetoothCharacteristic? humidityCharacteristic;

  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<List<int>>? _temperatureSub;
  StreamSubscription<List<int>>? _humiditySub;

  bool connecting = false;
  bool connected = false;
  String connectionStatus = 'Cihaz eklenmedi';
  String? connectionError;
  int? rssi;
  DateTime? lastUpdate;

  double? temperatureC;
  double? humidity;

  bool useFahrenheit = false;
  bool alertsEnabled = true;
  double minTempC = 15;
  double maxTempC = 30;
  double minHumidity = 30;
  double maxHumidity = 70;

  // Sensör işleme / kalibrasyon.
  double temperatureCalibrationC = 0;
  double humidityCalibration = 0;
  int smoothingWindow = 3;
  int recordingIntervalSeconds = 20;
  bool autoReconnect = false;

  final List<double> _temperatureSamples = [];
  final List<double> _humiditySamples = [];

  DateTime? connectedSince;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;

  String weatherCity = 'İstanbul';

  final List<SensorReading> history = [];
  DateTime? _lastPersistedReading;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();

    selectedDeviceId = _prefs?.getString('selected_device_id');
    selectedDeviceName = _prefs?.getString('selected_device_name');
    useFahrenheit = _prefs?.getBool('use_fahrenheit') ?? false;
    alertsEnabled = _prefs?.getBool('alerts_enabled') ?? true;
    minTempC = _prefs?.getDouble('min_temp_c') ?? 15;
    maxTempC = _prefs?.getDouble('max_temp_c') ?? 30;
    minHumidity = _prefs?.getDouble('min_humidity') ?? 30;
    maxHumidity = _prefs?.getDouble('max_humidity') ?? 70;

    temperatureCalibrationC =
        _prefs?.getDouble('temperature_calibration_c') ?? 0;
    humidityCalibration =
        _prefs?.getDouble('humidity_calibration') ?? 0;
    smoothingWindow = _prefs?.getInt('smoothing_window') ?? 3;
    recordingIntervalSeconds =
        _prefs?.getInt('recording_interval_seconds') ?? 20;
    autoReconnect = _prefs?.getBool('auto_reconnect') ?? false;

    if (![1, 3, 5, 7].contains(smoothingWindow)) {
      smoothingWindow = 3;
    }
    if (![5, 20, 60, 300].contains(recordingIntervalSeconds)) {
      recordingIntervalSeconds = 20;
    }

    weatherCity = _prefs?.getString('weather_city') ?? 'İstanbul';

    final raw = _prefs?.getStringList('sensor_history') ?? const <String>[];
    for (final item in raw) {
      try {
        history.add(SensorReading.fromJson(jsonDecode(item)));
      } catch (_) {}
    }

    if (selectedDeviceId != null) {
      connectionStatus = 'Bağlantı bekliyor';
    }
  }

  void disposeController() {
    _reconnectTimer?.cancel();
    _connectionSub?.cancel();
    _temperatureSub?.cancel();
    _humiditySub?.cancel();
    connectedDevice?.disconnect().catchError((_) {});
    super.dispose();
  }

  Future<void> chooseDevice(ScanResult result) async {
    selectedRuntimeDevice = result.device;
    selectedDeviceId = result.device.remoteId.toString();
    selectedDeviceName = _displayName(result);
    connectionError = null;
    connectionStatus = 'Bağlanmaya hazır';
    rssi = result.rssi;

    await _prefs?.setString('selected_device_id', selectedDeviceId!);
    await _prefs?.setString('selected_device_name', selectedDeviceName!);
    notifyListeners();
  }

  String _displayName(ScanResult result) {
    final adv = result.advertisementData.advName.trim();
    final platform = result.device.platformName.trim();
    if (adv.isNotEmpty) return adv;
    if (platform.isNotEmpty) return platform;
    return 'BLE Cihazı';
  }

  Future<void> forgetDevice() async {
    await disconnect();
    selectedDeviceId = null;
    selectedDeviceName = null;
    selectedRuntimeDevice = null;
    connectionStatus = 'Cihaz eklenmedi';
    rssi = null;
    await _prefs?.remove('selected_device_id');
    await _prefs?.remove('selected_device_name');
    notifyListeners();
  }

  Future<void> connectSelected() async {
    if (selectedDeviceId == null || connecting || connected) return;

    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    connecting = true;
    connectionError = null;
    connectionStatus = 'Bağlanıyor';
    notifyListeners();

    BluetoothDevice device = selectedRuntimeDevice ??
        BluetoothDevice.fromId(selectedDeviceId!);

    try {
      connectionStatus = 'Bağlanıyor';
      notifyListeners();

      connectedDevice = device;
      selectedRuntimeDevice = device;

      await _connectionSub?.cancel();
      _connectionSub = device.connectionState.listen((state) {
        final nowConnected = state == BluetoothConnectionState.connected;
        connected = nowConnected;

        if (nowConnected) {
          connectionStatus = 'Bağlı';
          connectedSince ??= DateTime.now();
        } else if (!connecting) {
          connectionStatus = 'Bağlantı kesildi';
          connectedSince = null;

          if (autoReconnect &&
              !_manualDisconnect &&
              selectedDeviceId != null) {
            _reconnectTimer?.cancel();
            _reconnectTimer = Timer(const Duration(seconds: 3), () {
              if (!connected && !connecting && !_manualDisconnect) {
                connectSelected();
              }
            });
          }
        }

        notifyListeners();
      });

      if (device.isDisconnected) {
        await device.connect(timeout: const Duration(seconds: 15));
      }

      await _discoverSensorServices(device);

      try {
        rssi = await device.readRssi();
      } catch (_) {}

      connecting = false;
      connected = true;
      connectionStatus = 'Bağlı';
      connectedSince ??= DateTime.now();
      lastUpdate = DateTime.now();
      notifyListeners();
    } catch (e) {
      connecting = false;
      connected = false;
      connectionStatus = 'Bağlantı hatası';
      connectionError = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  Future<void> _discoverSensorServices(BluetoothDevice device) async {
    final services = await device.discoverServices();
    BluetoothService? service;

    for (final item in services) {
      if (item.uuid == environmentalService) {
        service = item;
        break;
      }
    }

    if (service == null) {
      throw Exception(
        'Bu cihazda DHT11 servisi bulunamadı (181A). Başka cihaz seçmiş olabilirsin.',
      );
    }

    BluetoothCharacteristic? temp;
    BluetoothCharacteristic? hum;
    for (final characteristic in service.characteristics) {
      if (characteristic.uuid == temperatureUuid) temp = characteristic;
      if (characteristic.uuid == humidityUuid) hum = characteristic;
    }

    if (temp == null || hum == null) {
      throw Exception('Sıcaklık veya nem karakteristiği bulunamadı.');
    }

    temperatureCharacteristic = temp;
    humidityCharacteristic = hum;

    await _temperatureSub?.cancel();
    await _humiditySub?.cancel();

    _temperatureSub = temp.onValueReceived.listen((value) {
      final decoded = _decodeSigned16Hundredths(value);
      if (decoded != null) {
        temperatureC = _processTemperature(decoded);
        lastUpdate = DateTime.now();
        _maybeStoreReading();
        notifyListeners();
      }
    });

    _humiditySub = hum.onValueReceived.listen((value) {
      final decoded = _decodeUnsigned16Hundredths(value);
      if (decoded != null) {
        humidity = _processHumidity(decoded);
        lastUpdate = DateTime.now();
        _maybeStoreReading();
        notifyListeners();
      }
    });

    if (temp.properties.notify || temp.properties.indicate) {
      await temp.setNotifyValue(true);
    }
    if (hum.properties.notify || hum.properties.indicate) {
      await hum.setNotifyValue(true);
    }

    if (temp.properties.read) {
      final rawTemp = _decodeSigned16Hundredths(await temp.read());
      if (rawTemp != null) temperatureC = _processTemperature(rawTemp);
    }
    if (hum.properties.read) {
      final rawHumidity = _decodeUnsigned16Hundredths(await hum.read());
      if (rawHumidity != null) humidity = _processHumidity(rawHumidity);
    }
    _maybeStoreReading(force: true);
  }

  double? _decodeSigned16Hundredths(List<int> value) {
    if (value.length < 2) return null;
    var raw = value[0] | (value[1] << 8);
    if ((raw & 0x8000) != 0) raw -= 0x10000;
    return raw / 100.0;
  }

  double? _decodeUnsigned16Hundredths(List<int> value) {
    if (value.length < 2) return null;
    return (value[0] | (value[1] << 8)) / 100.0;
  }

  double _smoothed(
    List<double> samples,
    double value,
  ) {
    samples.add(value);

    while (samples.length > smoothingWindow) {
      samples.removeAt(0);
    }

    if (samples.isEmpty) return value;
    return samples.reduce((a, b) => a + b) / samples.length;
  }

  double _processTemperature(double raw) {
    final calibrated = raw + temperatureCalibrationC;
    return _smoothed(_temperatureSamples, calibrated);
  }

  double _processHumidity(double raw) {
    final calibrated =
        (raw + humidityCalibration).clamp(0.0, 100.0).toDouble();
    return _smoothed(_humiditySamples, calibrated);
  }

  Future<void> refreshSensor() async {
    if (!connected || connectedDevice == null) return;
    try {
      if (temperatureCharacteristic?.properties.read == true) {
        final rawTemp = _decodeSigned16Hundredths(
          await temperatureCharacteristic!.read(),
        );
        if (rawTemp != null) temperatureC = _processTemperature(rawTemp);
      }
      if (humidityCharacteristic?.properties.read == true) {
        final rawHumidity = _decodeUnsigned16Hundredths(
          await humidityCharacteristic!.read(),
        );
        if (rawHumidity != null) humidity = _processHumidity(rawHumidity);
      }
      try {
        rssi = await connectedDevice!.readRssi();
      } catch (_) {}
      lastUpdate = DateTime.now();
      _maybeStoreReading(force: true);
      connectionError = null;
      notifyListeners();
    } catch (e) {
      connectionError = 'Sensör verisi yenilenemedi.';
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();

    try {
      await connectedDevice?.disconnect();
    } catch (_) {}

    connected = false;
    connecting = false;
    connectedSince = null;
    connectedDevice = null;
    temperatureCharacteristic = null;
    humidityCharacteristic = null;
    connectionStatus = selectedDeviceId == null
        ? 'Cihaz eklenmedi'
        : 'Bağlanmaya hazır';
    notifyListeners();
  }

  void _maybeStoreReading({bool force = false}) {
    if (temperatureC == null || humidity == null) return;
    final now = DateTime.now();
    if (!force &&
        _lastPersistedReading != null &&
        now.difference(_lastPersistedReading!).inSeconds < recordingIntervalSeconds) {
      return;
    }

    _lastPersistedReading = now;
    history.add(
      SensorReading(
        time: now,
        temperatureC: temperatureC!,
        humidity: humidity!,
      ),
    );

    if (history.length > 2000) {
      history.removeRange(0, history.length - 2000);
    }
    _saveHistory();
  }

  Future<void> _saveHistory() async {
    final encoded = history
        .map((e) => jsonEncode(e.toJson()))
        .toList(growable: false);
    await _prefs?.setStringList('sensor_history', encoded);
  }

  Future<void> clearHistory() async {
    history.clear();
    await _prefs?.remove('sensor_history');
    notifyListeners();
  }

  double? get dewPointC {
    final t = temperatureC;
    final h = humidity;
    if (t == null || h == null || h <= 0) return null;
    const a = 17.62;
    const b = 243.12;
    final gamma = math.log(h / 100) + (a * t) / (b + t);
    return (b * gamma) / (a - gamma);
  }

  double? get heatIndexC {
    final t = temperatureC;
    final h = humidity;
    if (t == null || h == null) return null;
    final f = t * 9 / 5 + 32;
    if (f < 80 || h < 40) return t;

    final hiF = -42.379 +
        2.04901523 * f +
        10.14333127 * h -
        0.22475541 * f * h -
        0.00683783 * f * f -
        0.05481717 * h * h +
        0.00122874 * f * f * h +
        0.00085282 * f * h * h -
        0.00000199 * f * f * h * h;
    return (hiF - 32) * 5 / 9;
  }

  double? get absoluteHumidity {
    final t = temperatureC;
    final h = humidity;
    if (t == null || h == null) return null;
    final saturation = 6.112 * math.exp((17.67 * t) / (t + 243.5));
    return (saturation * h * 2.1674) / (273.15 + t);
  }

  String get comfortLabel {
    final t = temperatureC;
    final h = humidity;
    if (t == null || h == null) return 'Veri yok';
    if (t >= 20 && t <= 26 && h >= 40 && h <= 60) return 'Konforlu';
    if (h < 30) return 'Hava kuru';
    if (h > 70) return 'Nem yüksek';
    if (t < 18) return 'Serin';
    if (t > 28) return 'Sıcak';
    return 'Normal';
  }

  bool get hasAlert {
    if (!alertsEnabled || temperatureC == null || humidity == null) return false;
    return temperatureC! < minTempC ||
        temperatureC! > maxTempC ||
        humidity! < minHumidity ||
        humidity! > maxHumidity;
  }

  String get alertText {
    if (!hasAlert) return 'Değerler normal aralıkta';
    final parts = <String>[];
    if (temperatureC! < minTempC) parts.add('Sıcaklık düşük');
    if (temperatureC! > maxTempC) parts.add('Sıcaklık yüksek');
    if (humidity! < minHumidity) parts.add('Nem düşük');
    if (humidity! > maxHumidity) parts.add('Nem yüksek');
    return parts.join(' • ');
  }

  double? get vaporPressureHpa {
    final t = temperatureC;
    final h = humidity;
    if (t == null || h == null) return null;

    final saturation = 6.112 * math.exp((17.67 * t) / (t + 243.5));
    return saturation * h / 100;
  }

  double? get vpdKpa {
    final t = temperatureC;
    final h = humidity;
    if (t == null || h == null) return null;

    final saturationKpa =
        0.6108 * math.exp((17.27 * t) / (t + 237.3));
    return saturationKpa * (1 - h / 100);
  }

  int get comfortScore {
    final t = temperatureC;
    final h = humidity;
    if (t == null || h == null) return 0;

    final tempPenalty = (t - 23).abs() * 7;
    final humidityPenalty = (h - 50).abs() * 1.2;
    return (100 - tempPenalty - humidityPenalty)
        .clamp(0, 100)
        .round();
  }

  String get moldRiskLabel {
    final h = humidity;
    final t = temperatureC;
    final dew = dewPointC;

    if (h == null || t == null || dew == null) return 'Veri yok';
    if (h >= 80 || dew >= t - 1.5) return 'Yüksek';
    if (h >= 70 || dew >= t - 4) return 'Orta';
    return 'Düşük';
  }

  String get condensationRiskLabel {
    final t = temperatureC;
    final dew = dewPointC;
    if (t == null || dew == null) return 'Veri yok';

    final gap = t - dew;
    if (gap <= 2) return 'Yüksek';
    if (gap <= 5) return 'Orta';
    return 'Düşük';
  }

  double get temperatureTrendPerHour {
    return _trendPerHour((e) => e.temperatureC);
  }

  double get humidityTrendPerHour {
    return _trendPerHour((e) => e.humidity);
  }

  double _trendPerHour(double Function(SensorReading) valueOf) {
    if (history.length < 2) return 0;

    final now = DateTime.now();
    final recent = history
        .where((e) => now.difference(e.time) <= const Duration(minutes: 15))
        .toList();

    final data = recent.length >= 2
        ? recent
        : history.sublist(math.max(0, history.length - 10));

    if (data.length < 2) return 0;

    final hours =
        data.last.time.difference(data.first.time).inSeconds / 3600.0;
    if (hours <= 0.001) return 0;

    return (valueOf(data.last) - valueOf(data.first)) / hours;
  }

  String trendLabel(double value, {required String unit}) {
    if (value.abs() < 0.1) return '→ Stabil';
    return value > 0
        ? '↗ +${value.toStringAsFixed(1)} $unit/saat'
        : '↘ ${value.toStringAsFixed(1)} $unit/saat';
  }

  String get connectionDurationText {
    final since = connectedSince;
    if (!connected || since == null) return '--';

    final d = DateTime.now().difference(since);
    if (d.inHours > 0) {
      return '${d.inHours}s ${d.inMinutes.remainder(60)}dk';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}dk ${d.inSeconds.remainder(60)}sn';
    }
    return '${d.inSeconds}sn';
  }

  String get dataFreshnessText {
    final update = lastUpdate;
    if (update == null) return 'Veri yok';

    final seconds = DateTime.now().difference(update).inSeconds;
    if (seconds <= 3) return 'Canlı';
    if (seconds < 60) return '$seconds sn önce';
    return '${seconds ~/ 60} dk önce';
  }

  int get signalScore {
    final value = rssi;
    if (value == null) return 0;
    if (value >= -50) return 100;
    if (value <= -95) return 0;
    return (((value + 95) / 45) * 100).clamp(0, 100).round();
  }

  Future<void> setTemperatureCalibration(double value) async {
    temperatureCalibrationC = value;
    _temperatureSamples.clear();
    await _prefs?.setDouble('temperature_calibration_c', value);
    notifyListeners();
  }

  Future<void> setHumidityCalibration(double value) async {
    humidityCalibration = value;
    _humiditySamples.clear();
    await _prefs?.setDouble('humidity_calibration', value);
    notifyListeners();
  }

  Future<void> setSmoothingWindow(int value) async {
    smoothingWindow = value.clamp(1, 10);
    _temperatureSamples.clear();
    _humiditySamples.clear();
    await _prefs?.setInt('smoothing_window', smoothingWindow);
    notifyListeners();
  }

  Future<void> setRecordingIntervalSeconds(int value) async {
    recordingIntervalSeconds = value;
    await _prefs?.setInt(
      'recording_interval_seconds',
      recordingIntervalSeconds,
    );
    notifyListeners();
  }

  Future<void> setAutoReconnect(bool value) async {
    autoReconnect = value;

    if (!value) {
      _reconnectTimer?.cancel();
    }

    await _prefs?.setBool('auto_reconnect', value);
    notifyListeners();
  }

  Future<int> copyHistoryCsvToClipboard() async {
    final buffer = StringBuffer(
      'timestamp,temperature_c,humidity_percent\\n',
    );

    for (final item in history) {
      buffer.writeln(
        '${item.time.toIso8601String()},'
        '${item.temperatureC.toStringAsFixed(2)},'
        '${item.humidity.toStringAsFixed(2)}',
      );
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    return history.length;
  }

  double displayTemperature(double c) => useFahrenheit ? c * 9 / 5 + 32 : c;
  String get temperatureUnit => useFahrenheit ? '°F' : '°C';

  Future<void> setUseFahrenheit(bool value) async {
    useFahrenheit = value;
    await _prefs?.setBool('use_fahrenheit', value);
    notifyListeners();
  }

  Future<void> setAlertsEnabled(bool value) async {
    alertsEnabled = value;
    await _prefs?.setBool('alerts_enabled', value);
    notifyListeners();
  }

  Future<void> setTemperatureLimits(RangeValues values) async {
    minTempC = values.start;
    maxTempC = values.end;
    await _prefs?.setDouble('min_temp_c', minTempC);
    await _prefs?.setDouble('max_temp_c', maxTempC);
    notifyListeners();
  }

  Future<void> setHumidityLimits(RangeValues values) async {
    minHumidity = values.start;
    maxHumidity = values.end;
    await _prefs?.setDouble('min_humidity', minHumidity);
    await _prefs?.setDouble('max_humidity', maxHumidity);
    notifyListeners();
  }

  Future<void> setWeatherCity(String city) async {
    weatherCity = city;
    await _prefs?.setString('weather_city', city);
    notifyListeners();
  }
}

class SensorReading {
  SensorReading({
    required this.time,
    required this.temperatureC,
    required this.humidity,
  });

  final DateTime time;
  final double temperatureC;
  final double humidity;

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'temperatureC': temperatureC,
        'humidity': humidity,
      };

  factory SensorReading.fromJson(Map<String, dynamic> json) {
    return SensorReading(
      time: DateTime.parse(json['time'].toString()),
      temperatureC: (json['temperatureC'] as num).toDouble(),
      humidity: (json['humidity'] as num).toDouble(),
    );
  }
}

// -----------------------------------------------------------------------------
// HOME
// -----------------------------------------------------------------------------

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [
          SensorTab(controller: widget.controller),
          WeatherTab(controller: widget.controller),
          HistoryTab(controller: widget.controller),
          SettingsTab(controller: widget.controller),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.device_thermostat_outlined),
            selectedIcon: Icon(Icons.device_thermostat),
            label: 'Sensör',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: 'Hava',
          ),
          NavigationDestination(
            icon: Icon(Icons.timeline_outlined),
            selectedIcon: Icon(Icons.timeline),
            label: 'Geçmiş',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Ayarlar',
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SENSOR TAB
// -----------------------------------------------------------------------------

class SensorTab extends StatelessWidget {
  const SensorTab({super.key, required this.controller});
  final AppController controller;

  Future<void> _showScanner(BuildContext context) async {
    final result = await showModalBottomSheet<ScanResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1724),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const BleScannerSheet(),
    );

    if (result != null) {
      await controller.chooseDevice(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final temp = controller.temperatureC == null
            ? null
            : controller.displayTemperature(controller.temperatureC!);
        final dew = controller.dewPointC == null
            ? null
            : controller.displayTemperature(controller.dewPointC!);
        final heat = controller.heatIndexC == null
            ? null
            : controller.displayTemperature(controller.heatIndexC!);

        return SafeArea(
          child: RefreshIndicator(
            onRefresh: controller.connected
                ? controller.refreshSensor
                : () async {},
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
              children: [
                const AppHeader(
                  title: 'DHT11 Monitor',
                  subtitle: 'ESP32 • Bluetooth Low Energy',
                ),
                const SizedBox(height: 18),
                _SelectedDeviceCard(
                  controller: controller,
                  onAddOrChange: () => _showScanner(context),
                ),
                if (controller.connectionError != null) ...[
                  const SizedBox(height: 12),
                  ErrorCard(
                    message: controller.connectionError!,
                    onRetry: controller.connectSelected,
                  ),
                ],
                const SizedBox(height: 14),
                if (controller.hasAlert) ...[
                  AlertCard(text: controller.alertText),
                  const SizedBox(height: 14),
                ],
                Row(
                  children: [
                    Expanded(
                      child: MetricCard(
                        icon: Icons.device_thermostat,
                        label: 'Sıcaklık',
                        value: temp?.toStringAsFixed(1) ?? '--',
                        unit: controller.temperatureUnit,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: MetricCard(
                        icon: Icons.water_drop,
                        label: 'Nem',
                        value: controller.humidity?.toStringAsFixed(1) ?? '--',
                        unit: '%',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const SectionTitle('Ortam Analizi'),
                const SizedBox(height: 10),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.55,
                  children: [
                    SmallWeatherCard(
                      icon: Icons.grain,
                      label: 'Çiy noktası',
                      value: dew == null
                          ? '--'
                          : '${dew.toStringAsFixed(1)} ${controller.temperatureUnit}',
                    ),
                    SmallWeatherCard(
                      icon: Icons.local_fire_department_outlined,
                      label: 'Hissedilen',
                      value: heat == null
                          ? '--'
                          : '${heat.toStringAsFixed(1)} ${controller.temperatureUnit}',
                    ),
                    SmallWeatherCard(
                      icon: Icons.air_outlined,
                      label: 'Mutlak nem',
                      value: controller.absoluteHumidity == null
                          ? '--'
                          : '${controller.absoluteHumidity!.toStringAsFixed(1)} g/m³',
                    ),
                    SmallWeatherCard(
                      icon: Icons.sentiment_satisfied_alt,
                      label: 'Konfor',
                      value: controller.comfortLabel,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const SectionTitle('İleri Analiz'),
                const SizedBox(height: 10),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.55,
                  children: [
                    SmallWeatherCard(
                      icon: Icons.spa_outlined,
                      label: 'VPD',
                      value: controller.vpdKpa == null
                          ? '--'
                          : '${controller.vpdKpa!.toStringAsFixed(2)} kPa',
                    ),
                    SmallWeatherCard(
                      icon: Icons.cloud_outlined,
                      label: 'Buhar basıncı',
                      value: controller.vaporPressureHpa == null
                          ? '--'
                          : '${controller.vaporPressureHpa!.toStringAsFixed(1)} hPa',
                    ),
                    SmallWeatherCard(
                      icon: Icons.favorite_outline,
                      label: 'Konfor skoru',
                      value: '${controller.comfortScore} / 100',
                    ),
                    SmallWeatherCard(
                      icon: Icons.coronavirus_outlined,
                      label: 'Küf riski',
                      value: controller.moldRiskLabel,
                    ),
                    SmallWeatherCard(
                      icon: Icons.opacity_outlined,
                      label: 'Yoğuşma riski',
                      value: controller.condensationRiskLabel,
                    ),
                    SmallWeatherCard(
                      icon: Icons.signal_cellular_alt,
                      label: 'BLE kalite',
                      value: '${controller.signalScore} / 100',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                AppCard(
                  child: Column(
                    children: [
                      InfoRow(
                        icon: Icons.trending_up,
                        label: 'Sıcaklık trendi',
                        value: controller.trendLabel(
                          controller.temperatureTrendPerHour,
                          unit: '°C',
                        ),
                      ),
                      const Divider(height: 28),
                      InfoRow(
                        icon: Icons.trending_up,
                        label: 'Nem trendi',
                        value: controller.trendLabel(
                          controller.humidityTrendPerHour,
                          unit: '%',
                        ),
                      ),
                      const Divider(height: 28),
                      InfoRow(
                        icon: Icons.timer_outlined,
                        label: 'Bağlantı süresi',
                        value: controller.connectionDurationText,
                      ),
                      const Divider(height: 28),
                      InfoRow(
                        icon: Icons.bolt_outlined,
                        label: 'Veri tazeliği',
                        value: controller.dataFreshnessText,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                AppCard(
                  child: Column(
                    children: [
                      InfoRow(
                        icon: Icons.bluetooth,
                        label: 'Bağlantı',
                        value: controller.connectionStatus,
                      ),
                      const Divider(height: 28),
                      InfoRow(
                        icon: Icons.network_check,
                        label: 'Sinyal',
                        value: controller.rssi == null
                            ? '--'
                            : '${controller.rssi} dBm • ${_signalLabel(controller.rssi!)}',
                      ),
                      const Divider(height: 28),
                      InfoRow(
                        icon: Icons.schedule,
                        label: 'Son veri',
                        value: _formatTime(controller.lastUpdate),
                      ),
                      const Divider(height: 28),
                      const InfoRow(
                        icon: Icons.hub,
                        label: 'BLE servisi',
                        value: '181A',
                      ),
                      const Divider(height: 28),
                      const InfoRow(
                        icon: Icons.sync,
                        label: 'Sensör güncellemesi',
                        value: '≈ 2 saniye',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (controller.selectedDeviceId != null)
                  SizedBox(
                    height: 54,
                    child: FilledButton.icon(
                      onPressed: controller.connecting
                          ? null
                          : controller.connected
                              ? controller.refreshSensor
                              : controller.connectSelected,
                      icon: controller.connecting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              controller.connected
                                  ? Icons.refresh
                                  : Icons.bluetooth_connected,
                            ),
                      label: Text(
                        controller.connecting
                            ? 'Bağlanıyor...'
                            : controller.connected
                                ? 'Veriyi Yenile'
                                : 'Seçili Cihaza Bağlan',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                if (controller.connected) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: controller.disconnect,
                      icon: const Icon(Icons.link_off),
                      label: const Text('Bağlantıyı Kes'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SelectedDeviceCard extends StatelessWidget {
  const _SelectedDeviceCard({
    required this.controller,
    required this.onAddOrChange,
  });

  final AppController controller;
  final VoidCallback onAddOrChange;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedDeviceId != null;
    final statusColor = controller.connected
        ? const Color(0xFF2AD47B)
        : controller.connecting
            ? const Color(0xFFFFB84D)
            : const Color(0xFF6EAFFC);

    return AppCard(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.13),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  selected ? Icons.bluetooth : Icons.add_link,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected
                          ? (controller.selectedDeviceName ?? 'BLE Cihazı')
                          : 'Bluetooth cihazı ekle',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      selected
                          ? controller.selectedDeviceId!
                          : 'Uygulama artık ESP32’yi kendi kendine aramaz.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8CA4B9),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton.icon(
              onPressed: onAddOrChange,
              icon: Icon(selected ? Icons.swap_horiz : Icons.add),
              label: Text(selected ? 'Bluetooth Cihazını Değiştir' : 'Cihaz Ekle'),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// BLE SCANNER
// -----------------------------------------------------------------------------

class BleScannerSheet extends StatefulWidget {
  const BleScannerSheet({super.key});

  @override
  State<BleScannerSheet> createState() => _BleScannerSheetState();
}

class _BleScannerSheetState extends State<BleScannerSheet> {
  StreamSubscription<List<ScanResult>>? scanSub;
  StreamSubscription<bool>? scanningSub;
  final Map<String, ScanResult> results = {};
  bool scanning = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    scanSub?.cancel();
    scanningSub?.cancel();
    FlutterBluePlus.stopScan().catchError((_) {});
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      scanning = true;
      error = null;
      results.clear();
    });

    await scanSub?.cancel();
    scanSub = FlutterBluePlus.onScanResults.listen(
      (items) {
        if (!mounted) return;
        for (final item in items) {
          results[item.device.remoteId.toString()] = item;
        }
        setState(() {});
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          error = 'Bluetooth taraması başlatılamadı.';
          scanning = false;
        });
      },
    );

    try {
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
      await Future.delayed(const Duration(seconds: 12));
    } catch (_) {
      if (mounted) setState(() => error = 'Bluetooth iznini kontrol et.');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  String _name(ScanResult result) {
    final adv = result.advertisementData.advName.trim();
    final platform = result.device.platformName.trim();
    if (adv.isNotEmpty) return adv;
    if (platform.isNotEmpty) return platform;
    return 'İsimsiz BLE cihazı';
  }

  @override
  Widget build(BuildContext context) {
    final list = results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 14,
          bottom: MediaQuery.of(context).viewInsets.bottom + 18,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: Column(
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0xFF3A4D60),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bluetooth Cihazı Ekle',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'Listeden ESP32’ni kendin seç.',
                          style: TextStyle(
                            color: Color(0xFF8FA7BE),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: scanning ? null : _startScan,
                    icon: scanning
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ErrorCard(message: error!, onRetry: _startScan),
                ),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bluetooth_searching,
                              size: 54,
                              color: Colors.white.withOpacity(0.35),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              scanning
                                  ? 'Yakındaki BLE cihazları aranıyor...'
                                  : 'Cihaz bulunamadı',
                              style: const TextStyle(
                                color: Color(0xFF8FA7BE),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = list[index];
                          final name = _name(item);
                          return Material(
                            color: const Color(0xFF101D2B),
                            borderRadius: BorderRadius.circular(18),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () => Navigator.pop(context, item),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF123B67),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: const Icon(Icons.bluetooth),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            name,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            item.device.remoteId.toString(),
                                            style: const TextStyle(
                                              color: Color(0xFF829AB2),
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          '${item.rssi} dBm',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _signalLabel(item.rssi),
                                          style: const TextStyle(
                                            color: Color(0xFF829AB2),
                                            fontSize: 10.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// HISTORY TAB
// -----------------------------------------------------------------------------

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key, required this.controller});
  final AppController controller;

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  HistoryRange range = HistoryRange.sixHours;

  List<SensorReading> _filtered(List<SensorReading> input) {
    if (range == HistoryRange.all) return input;
    final now = DateTime.now();
    final duration = switch (range) {
      HistoryRange.oneHour => const Duration(hours: 1),
      HistoryRange.sixHours => const Duration(hours: 6),
      HistoryRange.twentyFourHours => const Duration(hours: 24),
      HistoryRange.all => const Duration(days: 36500),
    };
    return input.where((e) => now.difference(e.time) <= duration).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final data = _filtered(widget.controller.history);
        final tempValues = data.map((e) => e.temperatureC).toList();
        final humValues = data.map((e) => e.humidity).toList();

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            children: [
              const AppHeader(
                title: 'Sensör Geçmişi',
                subtitle: 'Yerel kayıt • Son 2000 ölçüm',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _rangeChip('1 saat', HistoryRange.oneHour),
                  _rangeChip('6 saat', HistoryRange.sixHours),
                  _rangeChip('24 saat', HistoryRange.twentyFourHours),
                  _rangeChip('Tümü', HistoryRange.all),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: widget.controller.history.isEmpty
                      ? null
                      : () async {
                          final count =
                              await widget.controller.copyHistoryCsvToClipboard();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '$count ölçüm CSV olarak panoya kopyalandı.',
                              ),
                            ),
                          );
                        },
                  icon: const Icon(Icons.content_copy_outlined),
                  label: const Text('Geçmişi CSV Olarak Panoya Kopyala'),
                ),
              ),
              const SizedBox(height: 16),
              if (data.isEmpty)
                const EmptyHistoryCard()
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: HistoryStatCard(
                        label: 'Sıcaklık ort.',
                        value:
                            '${widget.controller.displayTemperature(_average(tempValues)).toStringAsFixed(1)} ${widget.controller.temperatureUnit}',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: HistoryStatCard(
                        label: 'Nem ort.',
                        value: '${_average(humValues).toStringAsFixed(1)} %',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: HistoryStatCard(
                        label: 'Sıcaklık min/max',
                        value:
                            '${widget.controller.displayTemperature(tempValues.reduce(_minDouble)).toStringAsFixed(1)} / ${widget.controller.displayTemperature(tempValues.reduce(_maxDouble)).toStringAsFixed(1)} ${widget.controller.temperatureUnit}',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: HistoryStatCard(
                        label: 'Nem min/max',
                        value:
                            '${humValues.reduce(_minDouble).toStringAsFixed(0)} / ${humValues.reduce(_maxDouble).toStringAsFixed(0)} %',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const SectionTitle('Sıcaklık Grafiği'),
                const SizedBox(height: 10),
                SensorChartCard(
                  readings: data,
                  valueOf: (e) => widget.controller.displayTemperature(e.temperatureC),
                  unit: widget.controller.temperatureUnit,
                ),
                const SizedBox(height: 18),
                const SectionTitle('Nem Grafiği'),
                const SizedBox(height: 10),
                SensorChartCard(
                  readings: data,
                  valueOf: (e) => e.humidity,
                  unit: '%',
                ),
                const SizedBox(height: 18),
                const SectionTitle('Son Ölçümler'),
                const SizedBox(height: 10),
                AppCard(
                  child: Column(
                    children: [
                      for (int i = data.length - 1,
                              shown = 0;
                          i >= 0 && shown < 12;
                          i--, shown++) ...[
                        ReadingRow(
                          reading: data[i],
                          controller: widget.controller,
                        ),
                        if (i > math.max(0, data.length - 12))
                          const Divider(height: 24),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _rangeChip(String label, HistoryRange value) {
    return ChoiceChip(
      label: Text(label),
      selected: range == value,
      onSelected: (_) => setState(() => range = value),
    );
  }
}

enum HistoryRange { oneHour, sixHours, twentyFourHours, all }

class SensorChartCard extends StatelessWidget {
  const SensorChartCard({
    super.key,
    required this.readings,
    required this.valueOf,
    required this.unit,
  });

  final List<SensorReading> readings;
  final double Function(SensorReading) valueOf;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final sliced = readings.length > 100
        ? readings.sublist(readings.length - 100)
        : readings;
    final values = sliced.map(valueOf).toList();

    return AppCard(
      child: SizedBox(
        height: 210,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${values.reduce(_minDouble).toStringAsFixed(1)} $unit',
                  style: const TextStyle(
                    color: Color(0xFF8FA7BE),
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                Text(
                  '${values.reduce(_maxDouble).toStringAsFixed(1)} $unit',
                  style: const TextStyle(
                    color: Color(0xFF8FA7BE),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: CustomPaint(
                painter: LineChartPainter(values: values),
                size: Size.infinite,
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Text(
                  _formatShortDate(sliced.first.time),
                  style: const TextStyle(
                    color: Color(0xFF71869A),
                    fontSize: 10.5,
                  ),
                ),
                const Spacer(),
                Text(
                  _formatShortDate(sliced.last.time),
                  style: const TextStyle(
                    color: Color(0xFF71869A),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class LineChartPainter extends CustomPainter {
  const LineChartPainter({required this.values});
  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final grid = Paint()
      ..color = const Color(0xFF1C3144)
      ..strokeWidth = 1;
    for (int i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    if (values.length == 1) {
      final dot = Paint()..color = const Color(0xFF3596FF);
      canvas.drawCircle(Offset(size.width / 2, size.height / 2), 4, dot);
      return;
    }

    var minV = values.reduce(_minDouble);
    var maxV = values.reduce(_maxDouble);
    if ((maxV - minV).abs() < 0.01) {
      minV -= 1;
      maxV += 1;
    }

    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final normalized = (values[i] - minV) / (maxV - minV);
      final y = size.height - normalized * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = const Color(0xFF3596FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant LineChartPainter oldDelegate) {
    return oldDelegate.values != values;
  }
}

// -----------------------------------------------------------------------------
// SETTINGS TAB
// -----------------------------------------------------------------------------

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            children: [
              const AppHeader(
                title: 'Ayarlar',
                subtitle: 'Sensör, alarm ve uygulama tercihleri',
              ),
              const SizedBox(height: 16),
              const SectionTitle('Görünüm'),
              const SizedBox(height: 10),
              AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: controller.useFahrenheit,
                  onChanged: controller.setUseFahrenheit,
                  title: const Text(
                    'Fahrenheit kullan',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    controller.useFahrenheit
                        ? 'Sıcaklıklar °F olarak gösteriliyor.'
                        : 'Sıcaklıklar °C olarak gösteriliyor.',
                  ),
                  secondary: const Icon(Icons.thermostat),
                ),
              ),
              const SizedBox(height: 16),
              const SectionTitle('Sensör İşleme'),
              const SizedBox(height: 10),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sıcaklık kalibrasyonu: '
                      '${controller.temperatureCalibrationC >= 0 ? '+' : ''}'
                      '${controller.temperatureCalibrationC.toStringAsFixed(1)} °C',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Slider(
                      value: controller.temperatureCalibrationC,
                      min: -5,
                      max: 5,
                      divisions: 100,
                      label:
                          '${controller.temperatureCalibrationC.toStringAsFixed(1)} °C',
                      onChanged: controller.setTemperatureCalibration,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Nem kalibrasyonu: '
                      '${controller.humidityCalibration >= 0 ? '+' : ''}'
                      '${controller.humidityCalibration.toStringAsFixed(1)} %',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Slider(
                      value: controller.humidityCalibration,
                      min: -15,
                      max: 15,
                      divisions: 60,
                      label:
                          '${controller.humidityCalibration.toStringAsFixed(1)} %',
                      onChanged: controller.setHumidityCalibration,
                    ),
                    const Divider(height: 28),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Veri yumuşatma',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        DropdownButton<int>(
                          value: controller.smoothingWindow,
                          items: const [
                            DropdownMenuItem(value: 1, child: Text('Kapalı')),
                            DropdownMenuItem(value: 3, child: Text('3 ölçüm')),
                            DropdownMenuItem(value: 5, child: Text('5 ölçüm')),
                            DropdownMenuItem(value: 7, child: Text('7 ölçüm')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              controller.setSmoothingWindow(value);
                            }
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Geçmiş kayıt aralığı',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        DropdownButton<int>(
                          value: controller.recordingIntervalSeconds,
                          items: const [
                            DropdownMenuItem(value: 5, child: Text('5 sn')),
                            DropdownMenuItem(value: 20, child: Text('20 sn')),
                            DropdownMenuItem(value: 60, child: Text('1 dk')),
                            DropdownMenuItem(value: 300, child: Text('5 dk')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              controller.setRecordingIntervalSeconds(value);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionTitle('Değer Uyarıları'),
              const SizedBox(height: 10),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: controller.alertsEnabled,
                      onChanged: controller.setAlertsEnabled,
                      title: const Text(
                        'Sınır uyarıları',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: const Text(
                        'Sensör ekranında güvenli aralığın dışına çıkınca uyar.',
                      ),
                      secondary: const Icon(Icons.warning_amber),
                    ),
                    const Divider(height: 28),
                    Text(
                      'Sıcaklık: ${controller.minTempC.round()}°C – ${controller.maxTempC.round()}°C',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    RangeSlider(
                      values: RangeValues(controller.minTempC, controller.maxTempC),
                      min: -10,
                      max: 50,
                      divisions: 60,
                      labels: RangeLabels(
                        '${controller.minTempC.round()}°',
                        '${controller.maxTempC.round()}°',
                      ),
                      onChanged: controller.alertsEnabled
                          ? controller.setTemperatureLimits
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Nem: ${controller.minHumidity.round()}% – ${controller.maxHumidity.round()}%',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    RangeSlider(
                      values: RangeValues(
                        controller.minHumidity,
                        controller.maxHumidity,
                      ),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      labels: RangeLabels(
                        '${controller.minHumidity.round()}%',
                        '${controller.maxHumidity.round()}%',
                      ),
                      onChanged: controller.alertsEnabled
                          ? controller.setHumidityLimits
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionTitle('Bluetooth'),
              const SizedBox(height: 10),
              AppCard(
                child: Column(
                  children: [
                    InfoRow(
                      icon: Icons.bluetooth,
                      label: 'Kayıtlı cihaz',
                      value: controller.selectedDeviceName ?? 'Yok',
                    ),
                    const Divider(height: 28),
                    InfoRow(
                      icon: Icons.fingerprint,
                      label: 'Cihaz kimliği',
                      value: controller.selectedDeviceId ?? '--',
                    ),
                    const Divider(height: 28),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: controller.autoReconnect,
                      onChanged: controller.setAutoReconnect,
                      title: const Text(
                        'Bağlantı koparsa yeniden bağlan',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: const Text(
                        'Tarama yapmaz; yalnızca daha önce seçtiğin BLE cihazına tekrar bağlanır.',
                      ),
                      secondary: const Icon(Icons.autorenew),
                    ),
                    if (controller.selectedDeviceId != null) ...[
                      const Divider(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _confirmForgetDevice(context),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Kayıtlı Bluetooth Cihazını Unut'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionTitle('Veri'),
              const SizedBox(height: 10),
              AppCard(
                child: Column(
                  children: [
                    InfoRow(
                      icon: Icons.storage,
                      label: 'Kayıt sayısı',
                      value: '${controller.history.length}',
                    ),
                    const Divider(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: controller.history.isEmpty
                            ? null
                            : () async {
                                final count =
                                    await controller.copyHistoryCsvToClipboard();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '$count ölçüm CSV olarak panoya kopyalandı.',
                                    ),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.content_copy_outlined),
                        label: const Text('CSV Olarak Panoya Kopyala'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: controller.history.isEmpty
                            ? null
                            : () => _confirmClearHistory(context),
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('Sensör Geçmişini Temizle'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionTitle('Tanılama'),
              const SizedBox(height: 10),
              AppCard(
                child: Column(
                  children: [
                    InfoRow(
                      icon: Icons.network_check,
                      label: 'BLE kalite skoru',
                      value: '${controller.signalScore} / 100',
                    ),
                    const Divider(height: 28),
                    InfoRow(
                      icon: Icons.bolt_outlined,
                      label: 'Son veri',
                      value: controller.dataFreshnessText,
                    ),
                    const Divider(height: 28),
                    InfoRow(
                      icon: Icons.timer_outlined,
                      label: 'Bağlantı süresi',
                      value: controller.connectionDurationText,
                    ),
                    const Divider(height: 28),
                    InfoRow(
                      icon: Icons.filter_alt_outlined,
                      label: 'Yumuşatma',
                      value: controller.smoothingWindow == 1
                          ? 'Kapalı'
                          : '${controller.smoothingWindow} ölçüm',
                    ),
                    const Divider(height: 28),
                    InfoRow(
                      icon: Icons.save_outlined,
                      label: 'Kayıt aralığı',
                      value: '${controller.recordingIntervalSeconds} sn',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AppCard(
                child: const Column(
                  children: [
                    InfoRow(
                      icon: Icons.info_outline,
                      label: 'Uygulama',
                      value: 'DHT11 Monitor v1.5 Pro',
                    ),
                    Divider(height: 28),
                    InfoRow(
                      icon: Icons.memory,
                      label: 'Sensör protokolü',
                      value: 'BLE 181A / 2A6E / 2A6F',
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmForgetDevice(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cihaz unutulsun mu?'),
        content: const Text(
          'Bluetooth cihaz seçimi silinecek. Sonra tekrar tarayıp ekleyebilirsin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unut'),
          ),
        ],
      ),
    );
    if (result == true) await controller.forgetDevice();
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Geçmiş temizlensin mi?'),
        content: const Text('Kaydedilmiş sıcaklık ve nem ölçümleri silinecek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Temizle'),
          ),
        ],
      ),
    );
    if (result == true) await controller.clearHistory();
  }
}

// -----------------------------------------------------------------------------
// WEATHER TAB — GPS + Open-Meteo + Air Quality
// -----------------------------------------------------------------------------

class WeatherTab extends StatefulWidget {
  const WeatherTab({super.key, required this.controller});
  final AppController controller;

  @override
  State<WeatherTab> createState() => _WeatherTabState();
}

class _WeatherTabState extends State<WeatherTab> {
  late final TextEditingController cityController;

  bool loading = false;
  bool locating = false;
  String? error;

  WeatherData? weather;
  AirQualityData? airQuality;

  double? latitude;
  double? longitude;
  double? gpsAccuracy;

  @override
  void initState() {
    super.initState();
    cityController = TextEditingController(text: widget.controller.weatherCity);
    Future.delayed(const Duration(milliseconds: 350), _loadCurrentLocation);
  }

  @override
  void dispose() {
    cityController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentLocation() async {
    setState(() {
      loading = true;
      locating = true;
      error = null;
    });

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        throw Exception('Telefonun konum servisi kapalı. Konumu açıp tekrar dene.');
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        throw Exception(
          'Konum izni verilmedi. İstersen şehir aramasıyla devam edebilirsin.',
        );
      }

      if (permission == LocationPermission.deniedForever) {
        throw Exception(
          'Konum izni kalıcı olarak kapalı. Android ayarlarından DHT11 Monitor '
          'için konum iznini aç.',
        );
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 20),
        ),
      );

      String placeName = 'Mevcut Konum';

      try {
        final reverseUri = Uri.parse(
          'https://api.bigdatacloud.net/data/reverse-geocode-client'
          '?latitude=${pos.latitude}'
          '&longitude=${pos.longitude}'
          '&localityLanguage=tr',
        );

        final reverseResponse =
            await http.get(reverseUri).timeout(const Duration(seconds: 10));

        if (reverseResponse.statusCode == 200) {
          final reverse =
              jsonDecode(reverseResponse.body) as Map<String, dynamic>;

          final locality = reverse['locality']?.toString().trim() ?? '';
          final city = reverse['city']?.toString().trim() ?? '';
          final region =
              reverse['principalSubdivision']?.toString().trim() ?? '';
          final country = reverse['countryName']?.toString().trim() ?? '';

          final raw = <String>[
            if (locality.isNotEmpty) locality,
            if (city.isNotEmpty) city,
            if (region.isNotEmpty) region,
            if (country.isNotEmpty) country,
          ];

          final unique = <String>[];
          for (final value in raw) {
            if (!unique.contains(value)) unique.add(value);
          }

          if (unique.isNotEmpty) {
            placeName = unique.join(', ');
          }
        }
      } catch (_) {
        // Şehir adı çözülemezse GPS koordinatlarıyla hava durumu yine çalışır.
      }

      latitude = pos.latitude;
      longitude = pos.longitude;
      gpsAccuracy = pos.accuracy;

      await _loadByCoordinates(
        pos.latitude,
        pos.longitude,
        placeName: placeName,
      );

      final city = placeName.split(',').first.trim();
      cityController.text = city;
      await widget.controller.setWeatherCity(city);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          locating = false;
        });
      }
    }
  }

  Future<void> _searchCity(String city) async {
    final query = city.trim();
    if (query.isEmpty) return;

    setState(() {
      loading = true;
      error = null;
    });

    try {
      final geoUri = Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search'
        '?name=${Uri.encodeQueryComponent(query)}'
        '&count=1&language=tr&format=json',
      );

      final geoResponse =
          await http.get(geoUri).timeout(const Duration(seconds: 12));

      if (geoResponse.statusCode != 200) {
        throw Exception('Şehir araması başarısız.');
      }

      final geo = jsonDecode(geoResponse.body) as Map<String, dynamic>;
      final results = (geo['results'] as List?) ?? const [];

      if (results.isEmpty) throw Exception('Şehir bulunamadı.');

      final place = results.first as Map<String, dynamic>;
      final lat = (place['latitude'] as num).toDouble();
      final lon = (place['longitude'] as num).toDouble();

      final name = place['name']?.toString() ?? query;
      final admin = place['admin1']?.toString();
      final country = place['country']?.toString();

      final displayName = [
        name,
        if (admin != null && admin != name) admin,
        if (country != null) country,
      ].join(', ');

      latitude = lat;
      longitude = lon;
      gpsAccuracy = null;

      await _loadByCoordinates(
        lat,
        lon,
        placeName: displayName,
      );

      await widget.controller.setWeatherCity(name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadByCoordinates(
    double lat,
    double lon, {
    required String placeName,
  }) async {
    final forecastUri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat'
      '&longitude=$lon'
      '&current=temperature_2m,relative_humidity_2m,apparent_temperature,'
      'precipitation,rain,weather_code,cloud_cover,pressure_msl,'
      'surface_pressure,wind_speed_10m,wind_direction_10m,wind_gusts_10m,'
      'visibility,uv_index'
      '&hourly=temperature_2m,apparent_temperature,relative_humidity_2m,'
      'precipitation_probability,weather_code,wind_speed_10m,uv_index,visibility'
      '&daily=weather_code,temperature_2m_max,temperature_2m_min,'
      'apparent_temperature_max,apparent_temperature_min,sunrise,sunset,'
      'uv_index_max,precipitation_sum,precipitation_probability_max,'
      'wind_speed_10m_max,wind_gusts_10m_max'
      '&timezone=auto&forecast_days=7',
    );

    final airUri = Uri.parse(
      'https://air-quality-api.open-meteo.com/v1/air-quality'
      '?latitude=$lat'
      '&longitude=$lon'
      '&current=european_aqi,us_aqi,pm10,pm2_5,carbon_monoxide,'
      'nitrogen_dioxide,ozone'
      '&timezone=auto',
    );

    final responses = await Future.wait([
      http.get(forecastUri).timeout(const Duration(seconds: 15)),
      http.get(airUri).timeout(const Duration(seconds: 15)),
    ]);

    if (responses[0].statusCode != 200) {
      throw Exception('Hava durumu alınamadı.');
    }

    final weatherJson =
        jsonDecode(responses[0].body) as Map<String, dynamic>;

    AirQualityData? parsedAir;
    if (responses[1].statusCode == 200) {
      try {
        parsedAir = AirQualityData.fromJson(
          jsonDecode(responses[1].body) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    final parsedWeather = WeatherData.fromJson(
      weatherJson,
      placeName: placeName,
    );

    if (!mounted) return;
    setState(() {
      weather = parsedWeather;
      airQuality = parsedAir;
      error = null;
    });
  }

  Future<void> _refresh() async {
    final lat = latitude;
    final lon = longitude;

    if (lat == null || lon == null) {
      await _loadCurrentLocation();
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      await _loadByCoordinates(
        lat,
        lon,
        placeName: weather?.placeName ?? cityController.text,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _outdoorAdvice(WeatherData w, AirQualityData? air) {
    final items = <String>[];

    if (w.uvIndex >= 7) {
      items.add('UV yüksek; uzun süre direkt güneşte kalma');
    } else if (w.uvIndex >= 4) {
      items.add('Güneş koruması iyi olur');
    }

    if (air != null && air.europeanAqi >= 80) {
      items.add('Hava kalitesi düşük; yoğun dış egzersizi azalt');
    }

    if (w.precipitation > 0 ||
        (w.daily.isNotEmpty && w.daily.first.rainProbability >= 50)) {
      items.add('Yağış ihtimali yüksek; şemsiye mantıklı');
    }

    if (w.windSpeed >= 35) {
      items.add('Rüzgâr kuvvetli');
    }

    if (items.isEmpty) {
      return 'Dış ortam koşulları genel olarak uygun görünüyor.';
    }

    return items.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final w = weather;
    final aq = airQuality;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return SafeArea(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
              children: [
                const AppHeader(
                  title: 'Hava & Çevre',
                  subtitle: 'GPS • Hava durumu • Hava kalitesi',
                ),

                const SizedBox(height: 18),

                AppCard(
                  child: Row(
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF1D4661), Color(0xFF122639)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: locating
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(
                                Icons.my_location,
                                color: Color(0xFF70E1F5),
                              ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Otomatik Konum',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              w?.placeName ?? 'Telefonun GPS konumu kullanılır',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF91A8BC),
                                fontSize: 12,
                              ),
                            ),
                            if (gpsAccuracy != null) ...[
                              const SizedBox(height: 3),
                              Text(
                                'GPS doğruluğu ≈ ${gpsAccuracy!.round()} m',
                                style: const TextStyle(
                                  color: Color(0xFF6D879E),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Konumumu Yenile',
                        onPressed: locating ? null : _loadCurrentLocation,
                        icon: const Icon(Icons.gps_fixed),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: cityController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _searchCity,
                        decoration: const InputDecoration(
                          hintText: 'Farklı şehir ara',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 54,
                      height: 54,
                      child: FilledButton(
                        onPressed:
                            loading ? null : () => _searchCity(cityController.text),
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: loading && !locating
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                      ),
                    ),
                  ],
                ),

                if (error != null) ...[
                  const SizedBox(height: 12),
                  ErrorCard(
                    message: error!,
                    onRetry: _loadCurrentLocation,
                  ),
                ],

                if (w != null) ...[
                  const SizedBox(height: 16),

                  CurrentWeatherCard(
                    weather: w,
                    controller: widget.controller,
                  ),

                  if (widget.controller.temperatureC != null) ...[
                    const SizedBox(height: 12),
                    SensorVsWeatherCard(
                      indoorC: widget.controller.temperatureC!,
                      indoorHumidity: widget.controller.humidity,
                      outdoorC: w.temperature,
                      outdoorHumidity: w.humidity,
                      controller: widget.controller,
                    ),
                  ],

                  const SizedBox(height: 14),

                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF10251E), Color(0xFF0B1717)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF1D493B)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          color: Color(0xFF42E59B),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Dışarı Çıkma Özeti',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _outdoorAdvice(w, aq),
                                style: const TextStyle(
                                  color: Color(0xFF9BB7AB),
                                  fontSize: 12.5,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  const SectionTitle('Şu An'),

                  const SizedBox(height: 10),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.55,
                    children: [
                      SmallWeatherCard(
                        icon: Icons.water_drop_outlined,
                        label: 'Nem',
                        value: '${w.humidity.round()}%',
                      ),
                      SmallWeatherCard(
                        icon: Icons.air,
                        label: 'Rüzgâr',
                        value: '${w.windSpeed.toStringAsFixed(1)} km/s',
                      ),
                      SmallWeatherCard(
                        icon: Icons.speed,
                        label: 'Basınç',
                        value: '${w.pressure.round()} hPa',
                      ),
                      SmallWeatherCard(
                        icon: Icons.wb_sunny_outlined,
                        label: 'UV',
                        value: '${w.uvIndex.toStringAsFixed(1)} • ${_uvLabel(w.uvIndex)}',
                      ),
                      SmallWeatherCard(
                        icon: Icons.visibility_outlined,
                        label: 'Görüş',
                        value: '${(w.visibility / 1000).toStringAsFixed(1)} km',
                      ),
                      SmallWeatherCard(
                        icon: Icons.grain,
                        label: 'Yağış',
                        value: '${w.precipitation.toStringAsFixed(1)} mm',
                      ),
                    ],
                  ),

                  if (aq != null) ...[
                    const SizedBox(height: 20),
                    const SectionTitle('Hava Kalitesi'),
                    const SizedBox(height: 10),
                    AirQualityCard(data: aq),
                    const SizedBox(height: 10),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.55,
                      children: [
                        SmallWeatherCard(
                          icon: Icons.blur_on,
                          label: 'PM2.5',
                          value: '${aq.pm25.toStringAsFixed(1)} µg/m³',
                        ),
                        SmallWeatherCard(
                          icon: Icons.blur_circular,
                          label: 'PM10',
                          value: '${aq.pm10.toStringAsFixed(1)} µg/m³',
                        ),
                        SmallWeatherCard(
                          icon: Icons.science_outlined,
                          label: 'NO₂',
                          value: '${aq.nitrogenDioxide.toStringAsFixed(1)} µg/m³',
                        ),
                        SmallWeatherCard(
                          icon: Icons.bubble_chart_outlined,
                          label: 'Ozon',
                          value: '${aq.ozone.toStringAsFixed(1)} µg/m³',
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 20),
                  const SectionTitle('Önümüzdeki 12 Saat'),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 150,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: w.hourly.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        return HourlyCard(
                          item: w.hourly[index],
                          controller: widget.controller,
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 20),
                  const SectionTitle('7 Günlük Tahmin'),
                  const SizedBox(height: 10),
                  AppCard(
                    child: Column(
                      children: [
                        for (int i = 0; i < w.daily.length; i++) ...[
                          DailyRow(
                            item: w.daily[i],
                            controller: widget.controller,
                          ),
                          if (i != w.daily.length - 1)
                            const Divider(height: 26),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  AppCard(
                    child: Column(
                      children: [
                        InfoRow(
                          icon: Icons.wb_twilight,
                          label: 'Gün doğumu',
                          value: _hhmm(w.sunrise),
                        ),
                        const Divider(height: 28),
                        InfoRow(
                          icon: Icons.nights_stay_outlined,
                          label: 'Gün batımı',
                          value: _hhmm(w.sunset),
                        ),
                        const Divider(height: 28),
                        InfoRow(
                          icon: Icons.cloud_outlined,
                          label: 'Bulut',
                          value: '${w.cloudCover.round()}%',
                        ),
                        const Divider(height: 28),
                        InfoRow(
                          icon: Icons.explore_outlined,
                          label: 'Rüzgâr yönü',
                          value:
                              '${_windDirection(w.windDirection)} (${w.windDirection.round()}°)',
                        ),
                        const Divider(height: 28),
                        InfoRow(
                          icon: Icons.storm_outlined,
                          label: 'Rüzgâr hamlesi',
                          value: '${w.windGust.toStringAsFixed(1)} km/s',
                        ),
                        if (latitude != null && longitude != null) ...[
                          const Divider(height: 28),
                          InfoRow(
                            icon: Icons.pin_drop_outlined,
                            label: 'Koordinat',
                            value:
                                '${latitude!.toStringAsFixed(4)}, ${longitude!.toStringAsFixed(4)}',
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),
                  const Text(
                    'Hava ve hava kalitesi: Open‑Meteo • Konum: telefon GPS’i',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF6F879C),
                      fontSize: 11.5,
                    ),
                  ),
                ] else if (loading) ...[
                  const SizedBox(height: 90),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// WEATHER MODELS
// -----------------------------------------------------------------------------

class WeatherData {
  WeatherData({
    required this.placeName,
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.weatherCode,
    required this.precipitation,
    required this.rain,
    required this.cloudCover,
    required this.pressure,
    required this.windSpeed,
    required this.windDirection,
    required this.windGust,
    required this.visibility,
    required this.uvIndex,
    required this.sunrise,
    required this.sunset,
    required this.hourly,
    required this.daily,
  });

  final String placeName;
  final double temperature;
  final double feelsLike;
  final double humidity;
  final int weatherCode;
  final double precipitation;
  final double rain;
  final double cloudCover;
  final double pressure;
  final double windSpeed;
  final double windDirection;
  final double windGust;
  final double visibility;
  final double uvIndex;
  final String sunrise;
  final String sunset;
  final List<HourlyWeather> hourly;
  final List<DailyWeather> daily;

  factory WeatherData.fromJson(
    Map<String, dynamic> json, {
    required String placeName,
  }) {
    final current = json['current'] as Map<String, dynamic>;
    final hourlyJson = json['hourly'] as Map<String, dynamic>;
    final dailyJson = json['daily'] as Map<String, dynamic>;

    final now = DateTime.tryParse(current['time']?.toString() ?? '') ??
        DateTime.now();

    final times = List<String>.from(hourlyJson['time'] as List);
    final temperatures = List<num>.from(hourlyJson['temperature_2m'] as List);
    final apparent =
        List<num>.from(hourlyJson['apparent_temperature'] as List);
    final humidity =
        List<num>.from(hourlyJson['relative_humidity_2m'] as List);
    final rainProb =
        List<num>.from(hourlyJson['precipitation_probability'] as List);
    final codes = List<num>.from(hourlyJson['weather_code'] as List);
    final wind = List<num>.from(hourlyJson['wind_speed_10m'] as List);
    final uv = List<num>.from(hourlyJson['uv_index'] as List);

    final hourly = <HourlyWeather>[];
    for (int i = 0; i < times.length && hourly.length < 12; i++) {
      final time = DateTime.parse(times[i]);
      if (time.isBefore(now.subtract(const Duration(minutes: 30)))) continue;
      hourly.add(
        HourlyWeather(
          time: time,
          temperature: temperatures[i].toDouble(),
          feelsLike: apparent[i].toDouble(),
          humidity: humidity[i].toDouble(),
          precipitationProbability: rainProb[i].toDouble(),
          weatherCode: codes[i].toInt(),
          windSpeed: wind[i].toDouble(),
          uvIndex: uv[i].toDouble(),
        ),
      );
    }

    final dailyTimes = List<String>.from(dailyJson['time'] as List);
    final dailyCodes = List<num>.from(dailyJson['weather_code'] as List);
    final maxTemps = List<num>.from(dailyJson['temperature_2m_max'] as List);
    final minTemps = List<num>.from(dailyJson['temperature_2m_min'] as List);
    final rainMax =
        List<num>.from(dailyJson['precipitation_probability_max'] as List);
    final precipSum = List<num>.from(dailyJson['precipitation_sum'] as List);
    final windMax = List<num>.from(dailyJson['wind_speed_10m_max'] as List);

    final daily = <DailyWeather>[];
    for (int i = 0; i < dailyTimes.length; i++) {
      daily.add(
        DailyWeather(
          date: DateTime.parse(dailyTimes[i]),
          code: dailyCodes[i].toInt(),
          maxTemp: maxTemps[i].toDouble(),
          minTemp: minTemps[i].toDouble(),
          rainProbability: rainMax[i].toDouble(),
          precipitation: precipSum[i].toDouble(),
          maxWind: windMax[i].toDouble(),
        ),
      );
    }

    final sunriseList = List<String>.from(dailyJson['sunrise'] as List);
    final sunsetList = List<String>.from(dailyJson['sunset'] as List);

    double numValue(String key) =>
        (current[key] as num?)?.toDouble() ?? 0.0;

    return WeatherData(
      placeName: placeName,
      temperature: numValue('temperature_2m'),
      feelsLike: numValue('apparent_temperature'),
      humidity: numValue('relative_humidity_2m'),
      weatherCode: (current['weather_code'] as num?)?.toInt() ?? 0,
      precipitation: numValue('precipitation'),
      rain: numValue('rain'),
      cloudCover: numValue('cloud_cover'),
      pressure: numValue('pressure_msl'),
      windSpeed: numValue('wind_speed_10m'),
      windDirection: numValue('wind_direction_10m'),
      windGust: numValue('wind_gusts_10m'),
      visibility: numValue('visibility'),
      uvIndex: numValue('uv_index'),
      sunrise: sunriseList.isNotEmpty ? sunriseList.first : '',
      sunset: sunsetList.isNotEmpty ? sunsetList.first : '',
      hourly: hourly,
      daily: daily,
    );
  }
}

class HourlyWeather {
  HourlyWeather({
    required this.time,
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.precipitationProbability,
    required this.weatherCode,
    required this.windSpeed,
    required this.uvIndex,
  });

  final DateTime time;
  final double temperature;
  final double feelsLike;
  final double humidity;
  final double precipitationProbability;
  final int weatherCode;
  final double windSpeed;
  final double uvIndex;
}

class DailyWeather {
  DailyWeather({
    required this.date,
    required this.code,
    required this.maxTemp,
    required this.minTemp,
    required this.rainProbability,
    required this.precipitation,
    required this.maxWind,
  });

  final DateTime date;
  final int code;
  final double maxTemp;
  final double minTemp;
  final double rainProbability;
  final double precipitation;
  final double maxWind;
}

class AirQualityData {
  AirQualityData({
    required this.europeanAqi,
    required this.usAqi,
    required this.pm10,
    required this.pm25,
    required this.carbonMonoxide,
    required this.nitrogenDioxide,
    required this.ozone,
  });

  final double europeanAqi;
  final double usAqi;
  final double pm10;
  final double pm25;
  final double carbonMonoxide;
  final double nitrogenDioxide;
  final double ozone;

  factory AirQualityData.fromJson(Map<String, dynamic> json) {
    final current = json['current'] as Map<String, dynamic>;

    double value(String key) =>
        (current[key] as num?)?.toDouble() ?? 0.0;

    return AirQualityData(
      europeanAqi: value('european_aqi'),
      usAqi: value('us_aqi'),
      pm10: value('pm10'),
      pm25: value('pm2_5'),
      carbonMonoxide: value('carbon_monoxide'),
      nitrogenDioxide: value('nitrogen_dioxide'),
      ozone: value('ozone'),
    );
  }

  String get label {
    if (europeanAqi <= 20) return 'Çok iyi';
    if (europeanAqi <= 40) return 'İyi';
    if (europeanAqi <= 60) return 'Orta';
    if (europeanAqi <= 80) return 'Zayıf';
    if (europeanAqi <= 100) return 'Kötü';
    return 'Çok kötü';
  }
}

// -----------------------------------------------------------------------------
// COMMON UI
// -----------------------------------------------------------------------------

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Image.asset(
            'assets/logo.png',
            width: 50,
            height: 50,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF8FA7BE),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(17),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0E1926),
            Color(0xFF0A121D),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: const Color(0xFF1B3044)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 20,
            offset: Offset(0, 9),
          ),
        ],
      ),
      child: child,
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: SizedBox(
        height: 125,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 43,
              height: 43,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF17364D), Color(0xFF14243A)],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: const Color(0xFF70E1F5), size: 24),
            ),
            const Spacer(),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF8FA7BE),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: value,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                    TextSpan(
                      text: ' $unit',
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF8FA7BE),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SmallWeatherCard extends StatelessWidget {
  const SmallWeatherCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF3596FF), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF8FA7BE),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF6EAFFC)),
        const SizedBox(width: 11),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8FA7BE),
              fontSize: 13,
            ),
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class ErrorCard extends StatelessWidget {
  const ErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1620),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF6A293A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF7386)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 12.5)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Tekrar')),
        ],
      ),
    );
  }
}

class AlertCard extends StatelessWidget {
  const AlertCard({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF33240F),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF6C4A18)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Color(0xFFFFB84D)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryStatCard extends StatelessWidget {
  const HistoryStatCard({
    super.key,
    required this.label,
    required this.value,
  });
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8FA7BE),
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyHistoryCard extends StatelessWidget {
  const EmptyHistoryCard({super.key});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: SizedBox(
        height: 210,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.query_stats,
                size: 52,
                color: Colors.white.withOpacity(0.3),
              ),
              const SizedBox(height: 12),
              const Text(
                'Henüz kayıt yok',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              const Text(
                'Sensöre bağlanınca ölçümler otomatik kaydedilir.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF8FA7BE),
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReadingRow extends StatelessWidget {
  const ReadingRow({
    super.key,
    required this.reading,
    required this.controller,
  });

  final SensorReading reading;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _formatFullDate(reading.time),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                _formatTime(reading.time),
                style: const TextStyle(
                  color: Color(0xFF8FA7BE),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        Text(
          '${controller.displayTemperature(reading.temperatureC).toStringAsFixed(1)} ${controller.temperatureUnit}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 14),
        Text(
          '${reading.humidity.toStringAsFixed(0)}%',
          style: const TextStyle(
            color: Color(0xFF6EAFFC),
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class CurrentWeatherCard extends StatelessWidget {
  const CurrentWeatherCard({
    super.key,
    required this.weather,
    required this.controller,
  });

  final WeatherData weather;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final icon = _weatherIcon(weather.weatherCode);
    final description = _weatherDescription(weather.weatherCode);
    final temp = controller.displayTemperature(weather.temperature);
    final feels = controller.displayTemperature(weather.feelsLike);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF173A63), Color(0xFF142540), Color(0xFF0B1523)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: const Color(0xFF28557B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.location_on_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  weather.placeName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 58)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${temp.toStringAsFixed(1)}${controller.temperatureUnit}',
                      style: const TextStyle(
                        fontSize: 43,
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      description,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Hissedilen ${feels.toStringAsFixed(1)}${controller.temperatureUnit}',
                      style: const TextStyle(color: Color(0xFFB8D0E7)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SensorVsWeatherCard extends StatelessWidget {
  const SensorVsWeatherCard({
    super.key,
    required this.indoorC,
    required this.indoorHumidity,
    required this.outdoorC,
    required this.outdoorHumidity,
    required this.controller,
  });

  final double indoorC;
  final double? indoorHumidity;
  final double outdoorC;
  final double outdoorHumidity;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final delta = indoorC - outdoorC;
    final label = delta.abs() < 1
        ? 'İç ve dış sıcaklık yakın'
        : delta > 0
            ? 'İçerisi ${delta.abs().toStringAsFixed(1)}° daha sıcak'
            : 'İçerisi ${delta.abs().toStringAsFixed(1)}° daha serin';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sensör ↔ Dış Hava',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CompareValue(
                  label: 'İçerisi',
                  temp:
                      '${controller.displayTemperature(indoorC).toStringAsFixed(1)}${controller.temperatureUnit}',
                  humidity:
                      indoorHumidity == null ? '--' : '${indoorHumidity!.round()}%',
                ),
              ),
              const Icon(Icons.compare_arrows, color: Color(0xFF6EAFFC)),
              Expanded(
                child: _CompareValue(
                  label: 'Dışarısı',
                  temp:
                      '${controller.displayTemperature(outdoorC).toStringAsFixed(1)}${controller.temperatureUnit}',
                  humidity: '${outdoorHumidity.round()}%',
                  alignEnd: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8FA7BE),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompareValue extends StatelessWidget {
  const _CompareValue({
    required this.label,
    required this.temp,
    required this.humidity,
    this.alignEnd = false,
  });
  final String label;
  final String temp;
  final String humidity;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF8FA7BE),
            fontSize: 11.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          temp,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          'Nem $humidity',
          style: const TextStyle(fontSize: 11.5),
        ),
      ],
    );
  }
}

class AirQualityCard extends StatelessWidget {
  const AirQualityCard({super.key, required this.data});

  final AirQualityData data;

  Color get color {
    if (data.europeanAqi <= 20) return const Color(0xFF42E59B);
    if (data.europeanAqi <= 40) return const Color(0xFF9BE15D);
    if (data.europeanAqi <= 60) return const Color(0xFFFFD166);
    if (data.europeanAqi <= 80) return const Color(0xFFFFA24A);
    return const Color(0xFFFF6B7A);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (data.europeanAqi / 120).clamp(0.0, 1.0);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(Icons.eco_outlined, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Avrupa Hava Kalitesi İndeksi',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.label,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                data.europeanAqi.round().toString(),
                style: const TextStyle(
                  fontSize: 29,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: const Color(0xFF172434),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            'US AQI ${data.usAqi.round()} • CO ${data.carbonMonoxide.toStringAsFixed(0)} µg/m³',
            style: const TextStyle(
              color: Color(0xFF879EB3),
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

class HourlyCard extends StatelessWidget {
  const HourlyCard({
    super.key,
    required this.item,
    required this.controller,
  });

  final HourlyWeather item;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF101D2B),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: const Color(0xFF1C3144)),
      ),
      child: Column(
        children: [
          Text(
            '${item.time.hour.toString().padLeft(2, '0')}:00',
            style: const TextStyle(
              color: Color(0xFF9CB3C9),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(_weatherIcon(item.weatherCode),
              style: const TextStyle(fontSize: 30)),
          const Spacer(),
          Text(
            '${controller.displayTemperature(item.temperature).round()}${controller.temperatureUnit}',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '💧 ${item.precipitationProbability.round()}%',
            style: const TextStyle(
              color: Color(0xFF8FA7BE),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class DailyRow extends StatelessWidget {
  const DailyRow({
    super.key,
    required this.item,
    required this.controller,
  });

  final DailyWeather item;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 78,
          child: Text(
            _dayName(item.date),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        Text(_weatherIcon(item.code), style: const TextStyle(fontSize: 26)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '💧 ${item.rainProbability.round()}%',
            style: const TextStyle(
              color: Color(0xFF8FA7BE),
              fontSize: 12,
            ),
          ),
        ),
        Text(
          '${controller.displayTemperature(item.maxTemp).round()}°',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        const SizedBox(width: 10),
        Text(
          '${controller.displayTemperature(item.minTemp).round()}°',
          style: const TextStyle(color: Color(0xFF8FA7BE)),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// HELPERS
// -----------------------------------------------------------------------------

double _minDouble(double a, double b) => a < b ? a : b;
double _maxDouble(double a, double b) => a > b ? a : b;

double _average(List<double> values) {
  if (values.isEmpty) return 0;
  return values.reduce((a, b) => a + b) / values.length;
}

String _signalLabel(int rssi) {
  if (rssi >= -55) return 'Çok iyi';
  if (rssi >= -67) return 'İyi';
  if (rssi >= -75) return 'Orta';
  return 'Zayıf';
}

String _formatTime(DateTime? d) {
  if (d == null) return '--:--:--';
  return '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}

String _formatShortDate(DateTime d) {
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String _formatFullDate(DateTime d) {
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}


String _uvLabel(double uv) {
  if (uv < 3) return 'Düşük';
  if (uv < 6) return 'Orta';
  if (uv < 8) return 'Yüksek';
  if (uv < 11) return 'Çok yüksek';
  return 'Aşırı';
}

String _weatherIcon(int code) {
  if (code == 0) return '☀️';
  if (code == 1) return '🌤️';
  if (code == 2) return '⛅';
  if (code == 3) return '☁️';
  if (code == 45 || code == 48) return '🌫️';
  if ([51, 53, 55, 56, 57].contains(code)) return '🌦️';
  if ([61, 63, 65, 66, 67, 80, 81, 82].contains(code)) return '🌧️';
  if ([71, 73, 75, 77, 85, 86].contains(code)) return '🌨️';
  if ([95, 96, 99].contains(code)) return '⛈️';
  return '🌤️';
}

String _weatherDescription(int code) {
  if (code == 0) return 'Açık';
  if (code == 1) return 'Çoğunlukla açık';
  if (code == 2) return 'Parçalı bulutlu';
  if (code == 3) return 'Kapalı';
  if (code == 45 || code == 48) return 'Sisli';
  if ([51, 53, 55, 56, 57].contains(code)) return 'Çisenti';
  if ([61, 63, 65, 66, 67].contains(code)) return 'Yağmurlu';
  if ([71, 73, 75, 77].contains(code)) return 'Karlı';
  if ([80, 81, 82].contains(code)) return 'Sağanak';
  if ([85, 86].contains(code)) return 'Kar sağanağı';
  if ([95, 96, 99].contains(code)) return 'Gök gürültülü';
  return 'Değişken';
}

String _dayName(DateTime date) {
  const days = ['Pzt', 'Salı', 'Çarş.', 'Perş.', 'Cuma', 'Cmt', 'Paz'];
  return days[date.weekday - 1];
}

String _hhmm(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '--:--';
  return '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

String _windDirection(double deg) {
  const dirs = ['K', 'KD', 'D', 'GD', 'G', 'GB', 'B', 'KB'];
  final index = ((deg + 22.5) ~/ 45) % 8;
  return dirs[index];
}
