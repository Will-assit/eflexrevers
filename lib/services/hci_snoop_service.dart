import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/ble_packet.dart';
import '../models/uuid_info.dart';
import 'settings_service.dart';

/// Statut courant du service de lecture du journal HCI Bluetooth
enum SnoopStatus { inactif, recherche, lecture, erreur }

/// Service qui lit passivement le fichier btsnoop_hci.log d'Android pour
/// capturer le trafic GATT de l'eFlexFuel app sans connexion BLE directe.
///
/// Prérequis : activer "Journal HCI Bluetooth" dans les Options développeur Android.
class HciSnoopService extends ChangeNotifier {
  final SettingsService _settings;

  HciSnoopService(this._settings);

  // ── État interne ────────────────────────────────────────────────────────────

  SnoopStatus _status = SnoopStatus.inactif;
  String _statusMessage = '';
  String? _activeFilePath;
  Timer? _pollingTimer;

  /// Position dans le fichier jusqu'où on a déjà lu (en bytes)
  int _filePosition = 0;

  /// Chemins testés lors de la dernière découverte (pour affichage diagnostic)
  List<String> _lastTriedPaths = [];

  /// Table de correspondance handle ATT → UUID string
  final Map<int, String> _handleUuidMap = {};

  final List<BlePacket> _packets = [];
  final Map<String, UuidInfo> _uuidMap = {};

  // ── Chemins btsnoop connus (dans l'ordre de priorité) ──────────────────────

  static const List<String> _candidatePaths = [
    '/sdcard/BtHciSnoop/btsnoop_hci.log',        // Samsung One UI
    '/sdcard/btsnoop_hci.log',                    // AOSP générique
    '/sdcard/bluetooth/btsnoop_hci.log',          // Variante OEM
    '/data/misc/bluetooth/logs/btsnoop_hci.log',  // Android standard (root requis)
  ];

  // ── En-tête btsnoop ────────────────────────────────────────────────────────

  static const List<int> _btsnoopMagic = [
    0x62, 0x74, 0x73, 0x6E, 0x6F, 0x6F, 0x70, 0x00 // "btsnoop\0"
  ];
  static const int _headerSize  = 16;
  static const int _recordHeaderSize = 24;

  /// Offset en µs entre l'époque btsnoop (2000-01-01 UTC) et l'époque Unix
  static const int _btsnoopEpochOffsetUsec = 946684800000000;

  // ── Getters publics ─────────────────────────────────────────────────────────

  SnoopStatus get status => _status;
  String get statusMessage => _statusMessage;
  String? get activeFilePath => _activeFilePath;
  bool get isRunning => _status == SnoopStatus.lecture;
  int get packetCount => _packets.length;
  List<BlePacket> get packets => List.unmodifiable(_packets);
  Map<String, UuidInfo> get uuidMap => Map.unmodifiable(_uuidMap);
  Map<int, String> get handleUuidMap => Map.unmodifiable(_handleUuidMap);
  List<String> get lastTriedPaths => List.unmodifiable(_lastTriedPaths);

  // ── API publique ────────────────────────────────────────────────────────────

  /// Démarre le service : découverte du fichier, lecture initiale, polling
  Future<void> start() async {
    if (_status == SnoopStatus.lecture) return;

    _status = SnoopStatus.recherche;
    _statusMessage = 'Recherche du fichier btsnoop...';
    notifyListeners();

    // Demande la permission de lecture du stockage externe
    if (!await _requestStoragePermission()) {
      _setError('Permission stockage refusée');
      return;
    }

    // Découverte du fichier
    final path = _settings.snoopFilePath.isNotEmpty
        ? _settings.snoopFilePath
        : await _discoverSnoopFile();

    if (path == null) {
      _setError(
        'Fichier btsnoop introuvable.\n'
        '1. Vérifiez "Journal HCI Bluetooth" dans les Options développeur.\n'
        '2. Désactivez/réactivez le Bluetooth, puis reconnectez l\'eFlexFuel app au boîtier.\n'
        '3. Si le problème persiste, entrez le chemin manuellement dans les Réglages.',
      );
      return;
    }

    _activeFilePath = path;
    _status = SnoopStatus.lecture;
    _statusMessage = 'Actif : $path';
    notifyListeners();

    // Lecture initiale intégrale du fichier existant
    await _parseEntireFile(path);

    // Démarrage du polling périodique
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(
      Duration(milliseconds: _settings.snoopPollIntervalMs),
      (_) => _pollNewRecords(),
    );
  }

  /// Arrête le polling et remet le service en état inactif
  void stop() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _status = SnoopStatus.inactif;
    _statusMessage = '';
    notifyListeners();
  }

  /// Efface tous les paquets capturés (conserve la table handle→UUID)
  void clearPackets() {
    _packets.clear();
    _uuidMap.clear();
    notifyListeners();
  }

  /// Exporte les données capturées en JSON formaté
  String exportToJson() {
    final data = {
      'exportedAt': DateTime.now().toIso8601String(),
      'source': 'hci_snoop',
      'snoopFile': _activeFilePath,
      'packetCount': _packets.length,
      'handleUuidMap': _handleUuidMap
          .map((k, v) => MapEntry('0x${k.toRadixString(16).padLeft(4, '0')}', v)),
      'packets': _packets.map((p) => p.toJson()).toList(),
      'uuids': _uuidMap.values.map((u) => u.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  // ── Initialisation ──────────────────────────────────────────────────────────

  Future<bool> _requestStoragePermission() async {
    // MANAGE_EXTERNAL_STORAGE est la seule permission qui couvre /sdcard/ sur Android 11+.
    // Sur Android ≤ 10, permission_handler retourne PermissionStatus.granted automatiquement
    // car MANAGE_EXTERNAL_STORAGE n'existe pas avant API 30.
    // Sur Android 11+, ouvre la page Paramètres "Accès à tous les fichiers" (switch manuel).
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  /// Parcourt les chemins candidats et retourne le premier fichier trouvé
  Future<String?> _discoverSnoopFile() async {
    final List<String> toTry = [..._candidatePaths];

    // Chemin dynamique via path_provider pour éviter les écarts de symlink /sdcard
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final sdcard = ext.path.split('/Android').first; // ex: /storage/emulated/0
        toTry.insertAll(0, [
          '$sdcard/BtHciSnoop/btsnoop_hci.log',
          '$sdcard/btsnoop_hci.log',
          '$sdcard/bluetooth/btsnoop_hci.log',
        ]);
      }
    } catch (_) {}

    _lastTriedPaths = toTry;

    for (final path in toTry) {
      if (await File(path).exists()) return path;
    }
    return null;
  }

  // ── Parsing du fichier btsnoop ──────────────────────────────────────────────

  /// Lit et parse le fichier en entier depuis le début
  Future<void> _parseEntireFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (!_validateHeader(bytes)) return;
      _filePosition = _headerSize;
      _processRecordsFrom(bytes, _filePosition);
    } catch (e) {
      _setError('Erreur lecture fichier : $e');
    }
  }

  /// Polling : lit uniquement les octets ajoutés depuis la dernière lecture
  Future<void> _pollNewRecords() async {
    if (_activeFilePath == null) return;
    try {
      final bytes = await File(_activeFilePath!).readAsBytes();

      if (bytes.length > _filePosition) {
        // Nouveaux enregistrements depuis la dernière position
        final newSlice = Uint8List.sublistView(bytes, _filePosition);
        _processRecordsFromSlice(newSlice);
      } else if (bytes.length < _filePosition) {
        // Fichier tronqué / recréé — repart depuis le début
        _filePosition = _headerSize;
        _processRecordsFrom(bytes, _filePosition);
      }
    } catch (e) {
      debugPrint('[HciSnoop] Erreur polling : $e');
    }
  }

  /// Valide la magic btsnoop et le type de datalink
  bool _validateHeader(Uint8List bytes) {
    if (bytes.length < _headerSize) {
      _setError('Fichier trop court pour être un btsnoop valide');
      return false;
    }
    for (int i = 0; i < _btsnoopMagic.length; i++) {
      if (bytes[i] != _btsnoopMagic[i]) {
        _setError('Magic btsnoop invalide — ce n\'est pas un fichier HCI snoop');
        return false;
      }
    }
    final bd = ByteData.sublistView(bytes);
    final version      = bd.getUint32(8, Endian.big);
    final datalinkType = bd.getUint32(12, Endian.big);
    if (version != 1 || (datalinkType != 1001 && datalinkType != 1002)) {
      _setError(
        'Format btsnoop non supporté '
        '(version=$version, datalink=$datalinkType)',
      );
      return false;
    }
    return true;
  }

  /// Parse les enregistrements btsnoop à partir d'un offset dans un tableau complet
  void _processRecordsFrom(Uint8List bytes, int startOffset) {
    final bd = ByteData.sublistView(bytes);
    int offset = startOffset;

    while (offset + _recordHeaderSize <= bytes.length) {
      final originalLen = bd.getUint32(offset,      Endian.big);
      final includedLen = bd.getUint32(offset + 4,  Endian.big);
      // flags à offset+8, drops à offset+12 (ignorés sauf pour direction)
      final tsUsec      = bd.getInt64(offset + 16, Endian.big);

      offset += _recordHeaderSize;
      if (offset + includedLen > bytes.length) break; // enregistrement tronqué

      if (includedLen > 0 && originalLen > 0) {
        final recordData = Uint8List.sublistView(bytes, offset, offset + includedLen);
        final unixUsec   = tsUsec + _btsnoopEpochOffsetUsec;
        final timestamp  = DateTime.fromMicrosecondsSinceEpoch(
          unixUsec,
          isUtc: true,
        ).toLocal();
        _processHciRecord(recordData, timestamp);
      }

      offset += includedLen;
    }

    _filePosition = offset;
  }

  /// Parse les enregistrements dans un sous-tableau (utilisé pour le polling)
  void _processRecordsFromSlice(Uint8List slice) {
    final bd = ByteData.sublistView(slice);
    int offset = 0;

    while (offset + _recordHeaderSize <= slice.length) {
      final originalLen = bd.getUint32(offset,      Endian.big);
      final includedLen = bd.getUint32(offset + 4,  Endian.big);
      final tsUsec      = bd.getInt64(offset + 16, Endian.big);

      offset += _recordHeaderSize;
      if (offset + includedLen > slice.length) break;

      if (includedLen > 0 && originalLen > 0) {
        final recordData = Uint8List.sublistView(slice, offset, offset + includedLen);
        final unixUsec   = tsUsec + _btsnoopEpochOffsetUsec;
        final timestamp  = DateTime.fromMicrosecondsSinceEpoch(
          unixUsec,
          isUtc: true,
        ).toLocal();
        _processHciRecord(recordData, timestamp);
      }

      offset += includedLen;
    }

    _filePosition += offset;
  }

  // ── Parsing HCI / L2CAP / ATT ───────────────────────────────────────────────

  /// Décode un enregistrement HCI brut et dispatch selon le type
  void _processHciRecord(Uint8List data, DateTime timestamp) {
    if (data.isEmpty) return;

    // data[0] = indicateur de type HCI UART
    // 0x01 = Command, 0x02 = ACL Data, 0x03 = SCO, 0x04 = Event
    if (data[0] == 0x02) {
      _processAclPacket(data, timestamp);
    }
  }

  /// Décode un paquet HCI ACL Data et extrait le PDU ATT si présent
  void _processAclPacket(Uint8List data, DateTime timestamp) {
    // Structure HCI ACL (après le type byte 0x02) :
    //   bytes 1-2 : handle_flags (LE) — bits 0-11 = connexion handle
    //   bytes 3-4 : data_total_length (LE)
    // Structure L2CAP (après HCI ACL header) :
    //   bytes 5-6 : l2cap_length (LE)
    //   bytes 7-8 : channel_id (LE) — 0x0004 = ATT
    if (data.length < 10) return;

    final channelId = data[7] | (data[8] << 8);
    if (channelId != 0x0004) return; // Seul le canal ATT nous intéresse

    // PDU ATT commence à data[9]
    final attOpcode  = data[9];
    final attPayload = Uint8List.sublistView(data, 10);

    switch (attOpcode) {
      // Découverte des caractéristiques → construit la table handle→UUID
      case 0x09: _processAttReadByTypeResponse(attPayload);     break;
      // Découverte des services → idem
      case 0x11: _processAttReadByGroupTypeResponse(attPayload); break;
      // Notification GATT : données réelles envoyées par le boîtier
      case 0x1B: _processAttNotification(attPayload, timestamp); break;
      // Indication GATT (similaire à notify, accusé requis côté client)
      case 0x1D: _processAttNotification(attPayload, timestamp); break;
    }
  }

  /// ATT_Read_By_Type_Response (0x09) — extrait les paires handle→UUID
  /// Format : length(1) + [ handle(2 LE) + uuid(2 ou 16 bytes) ] * N
  void _processAttReadByTypeResponse(Uint8List payload) {
    if (payload.isEmpty) return;
    final pairLen = payload[0]; // longueur d'une paire (handle + uuid)
    if (pairLen < 4) return;    // au moins 2 bytes handle + 2 bytes UUID

    int i = 1;
    while (i + pairLen <= payload.length) {
      final handle   = payload[i] | (payload[i + 1] << 8);
      final uuidBytes = Uint8List.sublistView(payload, i + 2, i + pairLen);
      final uuid      = _bytesToUuidString(uuidBytes);
      _handleUuidMap[handle] = uuid;
      _uuidMap.putIfAbsent(uuid, () => UuidInfo(uuid: uuid));
      i += pairLen;
    }
    notifyListeners();
  }

  /// ATT_Read_By_Group_Type_Response (0x11) — découverte des services primaires
  /// Format : length(1) + [ startHandle(2 LE) + endHandle(2 LE) + uuid ] * N
  void _processAttReadByGroupTypeResponse(Uint8List payload) {
    if (payload.isEmpty) return;
    final itemLen = payload[0];
    if (itemLen < 6) return; // 2+2 handles + 2 UUID minimum

    int i = 1;
    while (i + itemLen <= payload.length) {
      final startHandle = payload[i] | (payload[i + 1] << 8);
      final uuidBytes   = Uint8List.sublistView(payload, i + 4, i + itemLen);
      final uuid        = _bytesToUuidString(uuidBytes);
      _handleUuidMap.putIfAbsent(startHandle, () => uuid);
      _uuidMap.putIfAbsent(uuid, () => UuidInfo(uuid: uuid));
      i += itemLen;
    }
  }

  /// ATT_Handle_Value_Notification (0x1B) ou Indication (0x1D) — données GATT
  /// Format : handle(2 LE) + value[...]
  void _processAttNotification(Uint8List payload, DateTime timestamp) {
    if (payload.length < 3) return; // 2 handle + au moins 1 byte de valeur

    final handle = payload[0] | (payload[1] << 8);
    final value  = Uint8List.sublistView(payload, 2);
    if (value.isEmpty) return;

    // Résolution handle → UUID (utilise un label générique si inconnu)
    final uuid = _handleUuidMap[handle]
        ?? 'handle-0x${handle.toRadixString(16).padLeft(4, '0')}';

    _addPacket(uuid, List<int>.from(value), timestamp);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Convertit un tableau de bytes btsnoop en chaîne UUID standard
  String _bytesToUuidString(Uint8List bytes) {
    if (bytes.length == 2) {
      // UUID 16-bit → étendue en UUID BLE complète (big-endian dans btsnoop)
      final short = (bytes[0] | (bytes[1] << 8)).toRadixString(16).padLeft(4, '0');
      return '0000$short-0000-1000-8000-00805f9b34fb';
    }
    if (bytes.length == 16) {
      // UUID 128-bit : btsnoop stocke en little-endian → inverser
      final reversed = bytes.reversed.toList();
      final hex = reversed
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      return '${hex.substring(0, 8)}-'
          '${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-'
          '${hex.substring(16, 20)}-'
          '${hex.substring(20)}';
    }
    // Longueur inattendue : retourne le hex brut
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Ajoute un paquet capturé à la liste et met à jour la map UUID
  void _addPacket(String uuid, List<int> value, DateTime timestamp) {
    final packet = BlePacket(
      timestamp: timestamp,
      uuid: uuid,
      value: List.unmodifiable(value),
      isHighlighted: true,
    );

    _packets.insert(0, packet);
    if (_packets.length > _settings.maxLogsMemory) {
      _packets.removeRange(_settings.maxLogsMemory, _packets.length);
    }

    _uuidMap.putIfAbsent(uuid, () => UuidInfo(uuid: uuid));
    final info = _uuidMap[uuid]!;
    info.lastHexExample = packet.hexValue;
    info.packets.add(packet);

    final numericValue =
        packet.float32Value ?? packet.uint16Value?.toDouble();
    if (numericValue != null) info.updateRange(numericValue);

    notifyListeners();

    // Supprime le surlignage orange après 500ms
    Future.delayed(const Duration(milliseconds: 500), () {
      packet.isHighlighted = false;
      notifyListeners();
    });
  }

  void _setError(String message) {
    _status = SnoopStatus.erreur;
    _statusMessage = message;
    debugPrint('[HciSnoop] $message');
    notifyListeners();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }
}
