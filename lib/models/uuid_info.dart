import 'ble_packet.dart';

/// Informations consolidées sur une UUID BLE découverte
class UuidInfo {
  /// UUID complète de la caractéristique BLE
  final String uuid;

  /// Nom suggéré par Claude (ex: "Taux éthanol")
  String? suggestedName;

  /// Type de données détecté : température / pourcentage / mode / inconnu
  String? dataType;

  /// Valeur minimale observée
  double? minValue;

  /// Valeur maximale observée
  double? maxValue;

  /// Dernier exemple de valeur HEX reçue
  String? lastHexExample;

  /// Explication de Claude sur cette caractéristique
  String? claudeExplanation;

  /// Tous les paquets reçus pour cette UUID
  final List<BlePacket> packets = [];

  UuidInfo({
    required this.uuid,
    this.suggestedName,
    this.dataType,
    this.minValue,
    this.maxValue,
    this.lastHexExample,
    this.claudeExplanation,
  });

  /// Met à jour la plage de valeurs observées
  void updateRange(double value) {
    if (minValue == null || value < minValue!) minValue = value;
    if (maxValue == null || value > maxValue!) maxValue = value;
  }

  /// UUID courte pour l'affichage (8 premiers caractères)
  String get shortUuid => uuid.length > 8 ? uuid.substring(0, 8) : uuid;

  /// Sérialisation JSON
  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'suggestedName': suggestedName,
        'dataType': dataType,
        'minValue': minValue,
        'maxValue': maxValue,
        'lastHexExample': lastHexExample,
        'claudeExplanation': claudeExplanation,
        'packetCount': packets.length,
      };
}
