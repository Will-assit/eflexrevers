import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/uuid_info.dart';
import '../services/ble_service.dart';
import '../services/claude_service.dart';
import '../services/hci_snoop_service.dart';
import '../services/settings_service.dart';

/// Écran Protocol Map : liste toutes les UUID découvertes et leur signification
class ProtocolScreen extends StatefulWidget {
  const ProtocolScreen({super.key});

  @override
  State<ProtocolScreen> createState() => _ProtocolScreenState();
}

class _ProtocolScreenState extends State<ProtocolScreen> {
  static const _orange = Color(0xFFFF6600);

  // UUID en cours d'analyse par Claude
  final Set<String> _analyzingUuids = {};

  /// Envoie une UUID à Claude pour identification
  Future<void> _analyzeUuid(UuidInfo uuidInfo) async {
    final settings = context.read<SettingsService>();
    if (settings.apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Clé API manquante — configurez-la dans les Réglages'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _analyzingUuids.add(uuidInfo.uuid));

    try {
      final claudeService = context.read<ClaudeService>();
      final result = await claudeService.analyzeUuid(uuidInfo);
      setState(() {
        uuidInfo.suggestedName = result['suggestedName'];
        uuidInfo.dataType = result['dataType'];
        uuidInfo.claudeExplanation = result['explanation'];
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur Claude : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _analyzingUuids.remove(uuidInfo.uuid));
    }
  }

  /// Génère le fichier protocol_map.dart et le partage
  Future<void> _generateProtocolMap(Map<String, UuidInfo> uuidMap) async {
    final sb = StringBuffer();
    final now = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());

    sb.writeln('// Protocol Map — Généré par eFlexReverse le $now');
    sb.writeln('// Fichier auto-généré à partir des données BLE capturées');
    sb.writeln('// ignore_for_file: constant_identifier_names');
    sb.writeln();
    sb.writeln("import 'dart:typed_data';");
    sb.writeln();
    sb.writeln('/// Protocole BLE de l\'injecteur eFlexFuel');
    sb.writeln('class EflexProtocol {');
    sb.writeln('  EflexProtocol._();');
    sb.writeln();

    // Constantes UUID
    sb.writeln('  // ── UUID des caractéristiques ──────────────────────────');
    for (final info in uuidMap.values) {
      final constName = _uuidToConstName(info.suggestedName ?? info.uuid);
      sb.writeln('  /// ${info.claudeExplanation ?? 'UUID non identifiée'}');
      sb.writeln(
          "  static const String $constName = '${info.uuid}';");
      sb.writeln();
    }

    // Fonctions de décodage
    sb.writeln('  // ── Fonctions de décodage ──────────────────────────────');
    for (final info in uuidMap.values) {
      final funcName = _uuidToFuncName(info.suggestedName ?? info.uuid);
      final retType = _dataTypeToReturnType(info.dataType);

      sb.writeln('  /// Décode ${info.suggestedName ?? info.uuid}');
      if (info.minValue != null && info.maxValue != null) {
        sb.writeln(
            '  /// Plage observée : ${info.minValue!.toStringAsFixed(2)} → ${info.maxValue!.toStringAsFixed(2)}');
      }
      if (info.lastHexExample != null) {
        sb.writeln('  /// Dernier exemple : ${info.lastHexExample}');
      }
      sb.writeln(
          '  static $retType decode$funcName(List<int> data) {');

      // Corps de la fonction selon le type
      switch (info.dataType?.toLowerCase()) {
        case 'pourcentage':
        case 'percentage':
          sb.writeln('    return data.isNotEmpty ? data[0].toDouble() : 0.0;');
        case 'température':
        case 'temperature':
          sb.writeln(
              '    if (data.length < 2) return 0.0;');
          sb.writeln(
              '    return ((data[0] | (data[1] << 8)) / 10.0);');
        case 'mode':
          sb.writeln('    return data.isNotEmpty ? data[0] : 0;');
        default:
          // Float32 générique
          sb.writeln('    if (data.length < 4) return 0.0;');
          sb.writeln(
              '    final bytes = Uint8List.fromList(data.sublist(0, 4));');
          sb.writeln(
              '    return bytes.buffer.asByteData().getFloat32(0, Endian.little);');
      }
      sb.writeln('  }');
      sb.writeln();
    }

    sb.writeln('}');
    sb.writeln();

    // Enum pour les types de données
    sb.writeln('/// Types de données identifiés dans le protocole eFlexFuel');
    sb.writeln('enum EflexDataType {');
    sb.writeln('  ethanol,     // Taux éthanol en %');
    sb.writeln('  temperature, // Température en °C');
    sb.writeln('  mode,        // Mode de fonctionnement');
    sb.writeln('  pressure,    // Pression en bar');
    sb.writeln('  unknown,     // Type non identifié');
    sb.writeln('}');

    final content = sb.toString();

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/protocol_map.dart');
      await file.writeAsString(content);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain')],
        subject: 'eFlexReverse — protocol_map.dart',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur génération : $e')),
        );
      }
    }
  }

  /// Convertit un nom en constante Dart (SCREAMING_SNAKE_CASE)
  String _uuidToConstName(String name) {
    if (name.length > 8 && name.contains('-')) {
      // C'est une UUID brute, utiliser un nom générique
      return 'UUID_${name.substring(0, 8).toUpperCase().replaceAll('-', '_')}';
    }
    return name
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  /// Convertit un nom en nom de fonction Dart (PascalCase)
  String _uuidToFuncName(String name) {
    if (name.length > 8 && name.contains('-')) {
      return 'Uuid${name.substring(0, 8).replaceAll('-', '')}';
    }
    return name
        .split(RegExp(r'[\s_\-]+'))
        .map((w) => w.isEmpty
            ? ''
            : w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join('');
  }

  /// Détermine le type de retour Dart selon le type de données
  String _dataTypeToReturnType(String? dataType) {
    switch (dataType?.toLowerCase()) {
      case 'mode':
        return 'int';
      default:
        return 'double';
    }
  }

  /// Couleur de badge selon le type de données
  Color _typeColor(String? dataType) {
    switch (dataType?.toLowerCase()) {
      case 'pourcentage':
      case 'percentage':
        return Colors.greenAccent.shade700;
      case 'température':
      case 'temperature':
        return Colors.blue.shade400;
      case 'mode':
        return Colors.purple.shade300;
      default:
        return Colors.grey.shade500;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final snoopService = context.watch<HciSnoopService>();
    // Snoop en base, BLE direct prioritaire sur les UUID communes
    final uuidMap = {
      ...snoopService.uuidMap,
      ...bleService.uuidMap,
    };

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Protocol Map',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          if (uuidMap.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.code, color: _orange),
              label: const Text('Générer .dart',
                  style: TextStyle(color: _orange)),
              onPressed: () => _generateProtocolMap(uuidMap),
            ),
        ],
      ),
      body: uuidMap.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: uuidMap.length,
              itemBuilder: (ctx, i) {
                final info = uuidMap.values.elementAt(i);
                return _buildUuidCard(info);
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.schema_outlined, size: 72, color: Color(0xFF444444)),
          SizedBox(height: 16),
          Text(
            'Aucune UUID découverte\nConnectez-vous à un appareil BLE',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildUuidCard(UuidInfo info) {
    final isAnalyzing = _analyzingUuids.contains(info.uuid);

    return Card(
      color: const Color(0xFF2A2A2A),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Ligne 1 : UUID + badge type ─────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Text(
                    info.uuid,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Color(0xFFCCCCCC),
                        fontSize: 11),
                  ),
                ),
                if (info.dataType != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _typeColor(info.dataType).withValues(alpha: 0.2),
                      border: Border.all(
                          color: _typeColor(info.dataType), width: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      info.dataType!,
                      style: TextStyle(
                          color: _typeColor(info.dataType),
                          fontSize: 10,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),

            // ── Nom suggéré ──────────────────────────────────────────────
            if (info.suggestedName != null)
              Text(
                info.suggestedName!,
                style: const TextStyle(
                    color: _orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 14),
              ),

            // ── Plage de valeurs ─────────────────────────────────────────
            if (info.minValue != null && info.maxValue != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Plage : ${info.minValue!.toStringAsFixed(2)} → ${info.maxValue!.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: Color(0xFF88AA88), fontSize: 11),
                ),
              ),

            // ── Dernier exemple HEX ──────────────────────────────────────
            if (info.lastHexExample != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Dernier : ${info.lastHexExample}',
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Color(0xFFAAAAAA),
                      fontSize: 11),
                ),
              ),

            // ── Explication Claude ───────────────────────────────────────
            if (info.claudeExplanation != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  info.claudeExplanation!,
                  style: const TextStyle(
                      color: Color(0xFF9999BB),
                      fontSize: 11,
                      fontStyle: FontStyle.italic),
                ),
              ),

            // ── Compteur paquets + bouton Analyser ───────────────────────
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${info.packets.length} paquet(s)',
                  style: const TextStyle(
                      color: Color(0xFF666666), fontSize: 11),
                ),
                const Spacer(),
                isAnalyzing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _orange),
                      )
                    : TextButton.icon(
                        style: TextButton.styleFrom(
                            foregroundColor: _orange,
                            padding: EdgeInsets.zero),
                        icon: const Icon(Icons.auto_awesome, size: 14),
                        label: const Text('Analyser',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () => _analyzeUuid(info),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
