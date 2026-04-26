import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service de persistance et d'accès à tous les réglages de l'application
class SettingsService extends ChangeNotifier {
  // Clés de stockage SharedPreferences
  static const _keyApiKey = 'claude_api_key';
  static const _keyScanTimeout = 'scan_timeout';
  static const _keyAutoReconnect = 'auto_reconnect';
  static const _keyNameFilter = 'ble_name_filter';
  static const _keyMaxBlePackets = 'max_ble_packets';
  static const _keyMaxScreenEntries = 'max_screen_entries';
  static const _keyClaudeLanguage = 'claude_language';
  static const _keySystemPrompt = 'system_prompt';
  static const _keyMaxLogsMemory = 'max_logs_memory';

  // Clés HCI snoop
  static const _keySnoopModeEnabled   = 'snoop_mode_enabled';
  static const _keySnoopFilePath      = 'snoop_file_path';
  static const _keySnoopPollIntervalMs = 'snoop_poll_interval_ms';

  /// Prompt système par défaut envoyé à Claude
  static const String defaultSystemPrompt =
      'Tu es un expert en reverse engineering de protocoles BLE pour systèmes '
      'embarqués moto. Analyse et corrèle les données BLE avec l\'affichage de '
      "l'application eFlexFuel.";

  late SharedPreferences _prefs;
  bool _initialized = false;

  // Valeurs en cache
  String _apiKey = '';
  int _scanTimeout = 10;
  bool _autoReconnect = true;
  String _nameFilter = 'eflex';
  int _maxBlePackets = 50;
  int _maxScreenEntries = 50;
  String _claudeLanguage = 'FR';
  String _systemPrompt = defaultSystemPrompt;
  int _maxLogsMemory = 500;

  // Valeurs HCI snoop en cache
  bool _snoopModeEnabled    = true;
  String _snoopFilePath     = '';
  int _snoopPollIntervalMs  = 500;

  // Getters publics
  bool get isInitialized => _initialized;
  String get apiKey => _apiKey;
  int get scanTimeout => _scanTimeout;
  bool get autoReconnect => _autoReconnect;
  String get nameFilter => _nameFilter;
  int get maxBlePackets => _maxBlePackets;
  int get maxScreenEntries => _maxScreenEntries;
  String get claudeLanguage => _claudeLanguage;
  String get systemPrompt => _systemPrompt;
  int get maxLogsMemory => _maxLogsMemory;
  bool get snoopModeEnabled => _snoopModeEnabled;
  String get snoopFilePath => _snoopFilePath;
  int get snoopPollIntervalMs => _snoopPollIntervalMs;

  /// Charge tous les réglages depuis SharedPreferences (à appeler au démarrage)
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _apiKey = _prefs.getString(_keyApiKey) ?? '';
    _scanTimeout = _prefs.getInt(_keyScanTimeout) ?? 10;
    _autoReconnect = _prefs.getBool(_keyAutoReconnect) ?? true;
    _nameFilter = _prefs.getString(_keyNameFilter) ?? 'eflex';
    _maxBlePackets = _prefs.getInt(_keyMaxBlePackets) ?? 50;
    _maxScreenEntries = _prefs.getInt(_keyMaxScreenEntries) ?? 50;
    _claudeLanguage = _prefs.getString(_keyClaudeLanguage) ?? 'FR';
    _systemPrompt = _prefs.getString(_keySystemPrompt) ?? defaultSystemPrompt;
    _maxLogsMemory       = _prefs.getInt(_keyMaxLogsMemory) ?? 500;
    _snoopModeEnabled    = _prefs.getBool(_keySnoopModeEnabled) ?? true;
    _snoopFilePath       = _prefs.getString(_keySnoopFilePath) ?? '';
    _snoopPollIntervalMs = _prefs.getInt(_keySnoopPollIntervalMs) ?? 500;
    _initialized = true;
    notifyListeners();
  }

  Future<void> setApiKey(String value) async {
    _apiKey = value;
    await _prefs.setString(_keyApiKey, value);
    notifyListeners();
  }

  Future<void> setScanTimeout(int value) async {
    _scanTimeout = value;
    await _prefs.setInt(_keyScanTimeout, value);
    notifyListeners();
  }

  Future<void> setAutoReconnect(bool value) async {
    _autoReconnect = value;
    await _prefs.setBool(_keyAutoReconnect, value);
    notifyListeners();
  }

  Future<void> setNameFilter(String value) async {
    _nameFilter = value;
    await _prefs.setString(_keyNameFilter, value);
    notifyListeners();
  }

  Future<void> setMaxBlePackets(int value) async {
    _maxBlePackets = value;
    await _prefs.setInt(_keyMaxBlePackets, value);
    notifyListeners();
  }

  Future<void> setMaxScreenEntries(int value) async {
    _maxScreenEntries = value;
    await _prefs.setInt(_keyMaxScreenEntries, value);
    notifyListeners();
  }

  Future<void> setClaudeLanguage(String value) async {
    _claudeLanguage = value;
    await _prefs.setString(_keyClaudeLanguage, value);
    notifyListeners();
  }

  Future<void> setSystemPrompt(String value) async {
    _systemPrompt = value;
    await _prefs.setString(_keySystemPrompt, value);
    notifyListeners();
  }

  Future<void> resetSystemPrompt() async {
    await setSystemPrompt(defaultSystemPrompt);
  }

  Future<void> setMaxLogsMemory(int value) async {
    _maxLogsMemory = value;
    await _prefs.setInt(_keyMaxLogsMemory, value);
    notifyListeners();
  }

  Future<void> setSnoopModeEnabled(bool value) async {
    _snoopModeEnabled = value;
    await _prefs.setBool(_keySnoopModeEnabled, value);
    notifyListeners();
  }

  Future<void> setSnoopFilePath(String value) async {
    _snoopFilePath = value;
    await _prefs.setString(_keySnoopFilePath, value);
    notifyListeners();
  }

  Future<void> setSnoopPollIntervalMs(int value) async {
    _snoopPollIntervalMs = value;
    await _prefs.setInt(_keySnoopPollIntervalMs, value);
    notifyListeners();
  }
}
