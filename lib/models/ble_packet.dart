import 'dart:typed_data';

/// Modèle représentant un paquet BLE reçu d'une caractéristique
class BlePacket {
  final DateTime timestamp;
  final String uuid;
  final List<int> value;

  /// Indique si le paquet vient d'être reçu (surlignage orange 500ms)
  bool isHighlighted;

  BlePacket({
    required this.timestamp,
    required this.uuid,
    required this.value,
    this.isHighlighted = true,
  });

  /// UUID court : 8 premiers caractères pour l'affichage
  String get shortUuid => uuid.length > 8 ? uuid.substring(0, 8) : uuid;

  /// Valeur brute en hexadécimal (ex: "FF 0A 3B")
  String get hexValue => value
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  /// Valeur ASCII filtrée sur les caractères imprimables uniquement
  String get asciiValue {
    final printable = value.where((b) => b >= 32 && b < 127).toList();
    if (printable.isEmpty) return '';
    return String.fromCharCodes(printable);
  }

  /// Décodage uint8 : premier octet
  int? get uint8Value => value.isNotEmpty ? value[0] : null;

  /// Décodage uint16 little-endian sur les 2 premiers octets
  int? get uint16Value {
    if (value.length >= 2) {
      return value[0] | (value[1] << 8);
    }
    return null;
  }

  /// Décodage float32 little-endian sur les 4 premiers octets
  double? get float32Value {
    if (value.length >= 4) {
      final bytes = Uint8List.fromList(value.sublist(0, 4));
      return bytes.buffer.asByteData().getFloat32(0, Endian.little);
    }
    return null;
  }

  /// Sérialisation JSON pour l'export des logs
  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'uuid': uuid,
        'hex': hexValue,
        'ascii': asciiValue,
        if (uint8Value != null) 'uint8': uint8Value,
        if (uint16Value != null) 'uint16': uint16Value,
        if (float32Value != null) 'float32': float32Value,
      };
}
