import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/ble_packet.dart';
import '../models/uuid_info.dart';
import 'settings_service.dart';

/// Service BLE : scan, connexion, écoute de toutes les caractéristiques
class BleService extends ChangeNotifier {
  final SettingsService _settings;

  BleService(this._settings);

  // État courant
  BluetoothDevice? _connectedDevice;
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  String _statusMessage = '';

  // Données collectées
  final List<ScanResult> _scanResults = [];
  final List<BlePacket> _packets = [];
  final Map<String, UuidInfo> _uuidMap = {};

  // Abonnements aux streams
  StreamSubscription? _scanSubscription;
  StreamSubscription? _scanningSubscription;
  StreamSubscription? _connectionSubscription;
  final List<StreamSubscription> _charSubscriptions = [];

  // Getters publics
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String get statusMessage => _statusMessage;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  String get deviceName => _connectedDevice?.platformName ?? 'Inconnu';
  List<ScanResult> get scanResults => List.unmodifiable(_scanResults);
  List<BlePacket> get packets => List.unmodifiable(_packets);
  Map<String, UuidInfo> get uuidMap => Map.unmodifiable(_uuidMap);
  int get packetCount => _packets.length;

  /// Demande les permissions nécessaires au scan BLE (Android 12+)
  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every(
      (s) => s.isGranted || s.isLimited,
    );
    return allGranted;
  }

  /// Démarre le scan BLE avec le timeout défini dans les réglages
  Future<void> startScan() async {
    if (_isScanning) return;

    // Vérification de l'état de l'adaptateur Bluetooth
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _statusMessage = 'Bluetooth désactivé';
      notifyListeners();
      return;
    }

    _scanResults.clear();
    _isScanning = true;
    _statusMessage = 'Scan en cours...';
    notifyListeners();

    try {
      await FlutterBluePlus.startScan(
        timeout: Duration(seconds: _settings.scanTimeout),
        androidUsesFineLocation: true,
      );

      // Écoute les résultats en temps réel
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        _scanResults
          ..clear()
          ..addAll(results);
        notifyListeners();
      });

      // Détecte la fin du scan
      _scanningSubscription = FlutterBluePlus.isScanning.listen((scanning) {
        if (!scanning && _isScanning) {
          _isScanning = false;
          _statusMessage = '${_scanResults.length} appareil(s) trouvé(s)';
          notifyListeners();
        }
      });
    } catch (e) {
      _isScanning = false;
      _statusMessage = 'Erreur scan : $e';
      notifyListeners();
      debugPrint('[BLE] Erreur démarrage scan : $e');
    }
  }

  /// Arrête le scan en cours
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();
    _scanningSubscription?.cancel();
    _isScanning = false;
    notifyListeners();
  }

  /// Se connecte à un appareil et s'abonne à TOUTES ses caractéristiques
  Future<void> connectAndListen(BluetoothDevice device) async {
    if (_isConnecting || _isConnected) return;
    _isConnecting = true;
    _statusMessage = 'Connexion à ${device.platformName}...';
    notifyListeners();

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      _connectedDevice = device;
      _isConnected = true;
      _isConnecting = false;
      _statusMessage = 'Connecté à ${device.platformName}';
      notifyListeners();

      // Écoute les changements d'état de connexion pour la reconnexion auto
      _connectionSubscription = device.connectionState.listen((state) {
        final nowConnected = state == BluetoothConnectionState.connected;
        if (!nowConnected && _isConnected) {
          _isConnected = false;
          _statusMessage = 'Déconnecté';
          notifyListeners();

          // Tentative de reconnexion automatique si activée
          if (_settings.autoReconnect) {
            _statusMessage = 'Reconnexion dans 3s...';
            notifyListeners();
            Future.delayed(const Duration(seconds: 3), () {
              if (!_isConnected && !_isConnecting) {
                connectAndListen(device);
              }
            });
          }
        }
      });

      // Découverte de tous les services et caractéristiques
      final services = await device.discoverServices();
      int subscribedCount = 0;

      for (final service in services) {
        for (final char in service.characteristics) {
          // Lecture initiale des caractéristiques lisibles
          if (char.properties.read) {
            try {
              final value = await char.read();
              if (value.isNotEmpty) {
                _addPacket(char.uuid.str, value);
              }
            } catch (e) {
              debugPrint('[BLE] Erreur lecture ${char.uuid.str} : $e');
            }
          }

          // Abonnement aux notifications et indications
          if (char.properties.notify || char.properties.indicate) {
            try {
              await char.setNotifyValue(true);
              final sub = char.lastValueStream.listen((value) {
                if (value.isNotEmpty) {
                  _addPacket(char.uuid.str, value);
                }
              });
              _charSubscriptions.add(sub);
              subscribedCount++;
            } catch (e) {
              debugPrint('[BLE] Erreur subscribe ${char.uuid.str} : $e');
            }
          }
        }
      }

      _statusMessage =
          'Connecté · $subscribedCount caractéristique(s) surveillée(s)';
      notifyListeners();
    } catch (e) {
      _isConnecting = false;
      _isConnected = false;
      _statusMessage = 'Erreur connexion : $e';
      notifyListeners();
      debugPrint('[BLE] Erreur connexion : $e');
    }
  }

  /// Ajoute un paquet reçu à la liste et met à jour la map UUID
  void _addPacket(String uuid, List<int> value) {
    final packet = BlePacket(
      timestamp: DateTime.now(),
      uuid: uuid,
      value: List.unmodifiable(value),
      isHighlighted: true,
    );

    // Insertion en tête de liste (plus récent en haut)
    _packets.insert(0, packet);

    // Respect de la limite mémoire configurée
    if (_packets.length > _settings.maxLogsMemory) {
      _packets.removeRange(_settings.maxLogsMemory, _packets.length);
    }

    // Mise à jour de la map UUID
    _uuidMap.putIfAbsent(uuid, () => UuidInfo(uuid: uuid));
    final info = _uuidMap[uuid]!;
    info.lastHexExample = packet.hexValue;
    info.packets.add(packet);

    // Mise à jour des plages de valeurs
    final numericValue = packet.float32Value ?? packet.uint16Value?.toDouble();
    if (numericValue != null) {
      info.updateRange(numericValue);
    }

    notifyListeners();

    // Suppression du surlignage orange après 500ms
    Future.delayed(const Duration(milliseconds: 500), () {
      packet.isHighlighted = false;
      notifyListeners();
    });
  }

  /// Déconnecte l'appareil et nettoie les abonnements
  Future<void> disconnect() async {
    for (final sub in _charSubscriptions) {
      sub.cancel();
    }
    _charSubscriptions.clear();
    _connectionSubscription?.cancel();

    try {
      await _connectedDevice?.disconnect();
    } catch (e) {
      debugPrint('[BLE] Erreur déconnexion : $e');
    }

    _connectedDevice = null;
    _isConnected = false;
    _statusMessage = 'Déconnecté';
    notifyListeners();
  }

  /// Efface tous les paquets enregistrés
  void clearPackets() {
    _packets.clear();
    notifyListeners();
  }

  /// Efface les données de la map UUID
  void clearUuidMap() {
    _uuidMap.clear();
    notifyListeners();
  }

  /// Exporte les données en JSON formaté
  String exportToJson() {
    final data = {
      'exportedAt': DateTime.now().toIso8601String(),
      'device': {
        'name': _connectedDevice?.platformName ?? 'Inconnu',
        'id': _connectedDevice?.remoteId.str ?? '',
      },
      'packetCount': _packets.length,
      'packets': _packets.map((p) => p.toJson()).toList(),
      'uuids': _uuidMap.values.map((u) => u.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _scanningSubscription?.cancel();
    _connectionSubscription?.cancel();
    for (final sub in _charSubscriptions) {
      sub.cancel();
    }
    super.dispose();
  }
}
