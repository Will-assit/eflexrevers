import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/ble_packet.dart';
import '../models/screen_entry.dart';
import '../services/accessibility_service.dart';
import '../services/ble_service.dart';
import '../services/claude_service.dart';
import '../services/hci_snoop_service.dart';
import '../services/settings_service.dart';
import 'protocol_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';

/// Écran principal : vue divisée BLE / eFlexApp + analyse Claude
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const _orange = Color(0xFFFF6600);
  static const _bgLeft = Color(0xFF1E1E1E);
  static const _bgRight = Color(0xFF1A1E1A);

  bool _isAnalyzing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Démarrage de la capture d'accessibilité
      final accService = context.read<AccessibilityService>();
      final enabled = await accService.checkEnabled();
      if (enabled && !accService.isListening) {
        accService.startListening();
      }
      // Démarrage du snoop HCI si activé dans les réglages
      if (!mounted) return;
      final settings = context.read<SettingsService>();
      if (settings.snoopModeEnabled) {
        context.read<HciSnoopService>().start();
      }
    });
  }

  // ─── Source de données unifiée ─────────────────────────────────────────────

  /// Retourne les paquets BLE depuis le mode direct ou le snoop
  List<BlePacket> _activePackets(BleService ble, HciSnoopService snoop) =>
      ble.isConnected ? ble.packets : snoop.packets;

  int _activePacketCount(BleService ble, HciSnoopService snoop) =>
      ble.isConnected ? ble.packetCount : snoop.packetCount;

  // ─── Analyse Claude ────────────────────────────────────────────────────────

  Future<void> _launchAnalysis() async {
    final bleService   = context.read<BleService>();
    final snoopService = context.read<HciSnoopService>();
    final accService   = context.read<AccessibilityService>();
    final claudeService = context.read<ClaudeService>();
    final settings     = context.read<SettingsService>();

    if (settings.apiKey.isEmpty) {
      _showApiKeyMissing();
      return;
    }

    setState(() => _isAnalyzing = true);

    try {
      final packets = _activePackets(bleService, snoopService).toList();
      final result  = await claudeService.analyzeCorrelation(
        packets,
        accService.entries.toList(),
      );
      if (mounted) _showAnalysisBottomSheet(result);
    } catch (e) {
      if (mounted) _showAnalysisBottomSheet('❌ Erreur : $e', isError: true);
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  void _showApiKeyMissing() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
            'Clé API manquante — configurez-la dans les Réglages'),
        backgroundColor: Colors.red.shade800,
        action: SnackBarAction(
          label: 'Réglages',
          textColor: Colors.white,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ),
    );
  }

  void _showAnalysisBottomSheet(String content, {bool isError = false}) {
    final bleService   = context.read<BleService>();
    final snoopService = context.read<HciSnoopService>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF2A2A2A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            // Poignée
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Titre
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.psychology,
                      color: isError ? Colors.red : _orange),
                  const SizedBox(width: 8),
                  Text(
                    isError ? 'Erreur d\'analyse' : 'Analyse Claude',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF444444), height: 1),
            // Contenu
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  content,
                  style: TextStyle(
                    color: isError
                        ? Colors.red.shade300
                        : const Color(0xFFDDDDDD),
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ),
            ),
            // Boutons
            if (!isError)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _orange,
                          side: const BorderSide(color: _orange),
                        ),
                        icon: const Icon(Icons.map_outlined, size: 16),
                        label: const Text('Protocol Map',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          // Sauvegarde l'analyse Claude dans les UUID actives
                          final uuids = bleService.isConnected
                              ? bleService.uuidMap
                              : snoopService.uuidMap;
                          for (final info in uuids.values) {
                            info.claudeExplanation ??= content;
                          }
                          Navigator.pop(ctx);
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const ProtocolScreen(),
                          ));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _orange,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copier',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: content));
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Analyse copiée')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─── Export JSON ───────────────────────────────────────────────────────────

  Future<void> _exportJson() async {
    final bleService   = context.read<BleService>();
    final snoopService = context.read<HciSnoopService>();
    final accService   = context.read<AccessibilityService>();

    final source = bleService.isConnected ? 'ble_direct' : 'hci_snoop';
    final bleData = bleService.isConnected
        ? jsonDecode(bleService.exportToJson())
        : jsonDecode(snoopService.exportToJson());

    final data = jsonEncode({
      'exportedAt': DateTime.now().toIso8601String(),
      'source': source,
      'ble': bleData,
      'screenEntries': accService.entries.map((e) => e.toJson()).toList(),
    });

    try {
      final dir = await getTemporaryDirectory();
      final ts  = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/eflex_logs_$ts.json');
      await file.writeAsString(data);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'eFlexReverse logs $ts',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Erreur export : $e'),
              backgroundColor: Colors.red.shade800),
        );
      }
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bleService   = context.watch<BleService>();
    final accService   = context.watch<AccessibilityService>();
    final snoopService = context.watch<HciSnoopService>();

    final packets = _activePackets(bleService, snoopService);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: _buildAppBar(bleService),
      body: Column(
        children: [
          _buildStatusBar(bleService, accService, snoopService),
          // Bandeau d'erreur snoop si fichier introuvable et pas de connexion directe
          if (snoopService.status == SnoopStatus.erreur &&
              !bleService.isConnected)
            _buildSnoopErrorBanner(snoopService),
          Expanded(
              child: _buildSplitView(packets, accService)),
          _buildBottomBar(bleService, snoopService, accService),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _orange,
        foregroundColor: Colors.white,
        onPressed: _isAnalyzing ? null : _launchAnalysis,
        icon: _isAnalyzing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.psychology),
        label: Text(_isAnalyzing ? 'Analyse...' : 'Analyser'),
      ),
    );
  }

  AppBar _buildAppBar(BleService bleService) {
    return AppBar(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text(
        'eFlexReverse',
        style: TextStyle(
            fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
      ),
      actions: [
        // Bouton Bluetooth → ScanScreen (mode direct BLE)
        IconButton(
          icon: Icon(
            bleService.isConnected
                ? Icons.bluetooth_connected
                : Icons.bluetooth,
            color: bleService.isConnected
                ? Colors.greenAccent
                : const Color(0xFF888888),
          ),
          tooltip: 'Mode direct BLE',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ScanScreen()),
          ),
        ),
        // Engrenage → Réglages
        IconButton(
          icon: const Icon(Icons.settings_outlined, color: Colors.white),
          tooltip: 'Réglages',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        // Cerveau orange → Analyse Claude
        IconButton(
          icon: const Icon(Icons.psychology, color: _orange),
          tooltip: 'Analyser avec Claude',
          onPressed: _isAnalyzing ? null : _launchAnalysis,
        ),
      ],
    );
  }

  Widget _buildStatusBar(
    BleService bleService,
    AccessibilityService accService,
    HciSnoopService snoopService,
  ) {
    return Container(
      color: const Color(0xFF222222),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // Statut snoop HCI (source principale)
          _statusChip(
            icon: Icons.sensors,
            label: _snoopLabel(snoopService),
            color: _snoopColor(snoopService),
          ),
          const SizedBox(width: 8),
          // Compteur de paquets (source active)
          _statusChip(
            icon: Icons.radio_button_checked,
            label:
                '${_activePacketCount(bleService, snoopService)} paquets',
            color: _orange,
          ),
          const Spacer(),
          // Statut AccessibilityService
          _statusChip(
            icon: accService.isListening
                ? Icons.accessibility_new
                : Icons.accessibility,
            label: accService.isListening ? 'A11y ON' : 'A11y OFF',
            color:
                accService.isListening ? Colors.greenAccent : Colors.grey,
          ),
        ],
      ),
    );
  }

  String _snoopLabel(HciSnoopService s) {
    switch (s.status) {
      case SnoopStatus.inactif:
        return 'Snoop OFF';
      case SnoopStatus.recherche:
        return 'Recherche...';
      case SnoopStatus.lecture:
        return 'Snoop actif';
      case SnoopStatus.erreur:
        return 'Snoop : erreur';
    }
  }

  Color _snoopColor(HciSnoopService s) {
    switch (s.status) {
      case SnoopStatus.inactif:
        return Colors.grey;
      case SnoopStatus.recherche:
        return Colors.orange;
      case SnoopStatus.lecture:
        return Colors.greenAccent;
      case SnoopStatus.erreur:
        return Colors.red;
    }
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(color: color, fontSize: 11),
            overflow: TextOverflow.ellipsis),
      ],
    );
  }

  /// Bandeau d'erreur affiché quand le fichier snoop est introuvable
  Widget _buildSnoopErrorBanner(HciSnoopService snoopService) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3A1A00),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Fichier HCI snoop introuvable',
            style: TextStyle(
                color: _orange,
                fontWeight: FontWeight.bold,
                fontSize: 12),
          ),
          const SizedBox(height: 4),
          const Text(
            'Activez "Journal HCI Bluetooth" dans Paramètres → Options '
            'développeur, puis relancez l\'eFlexFuel app. '
            'Ou connectez-vous directement via le bouton Bluetooth.',
            style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 11),
          ),
          const SizedBox(height: 6),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: _orange,
              side: const BorderSide(color: _orange),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: snoopService.start,
            child: const Text('Réessayer', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitView(
    List<BlePacket> packets,
    AccessibilityService accService,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Colonne gauche — paquets BLE (snoop ou direct)
        Expanded(
          child: Container(
            color: _bgLeft,
            child: Column(
              children: [
                _columnHeader('📡 BLE', packets.length, _orange),
                Expanded(child: _buildBleList(packets)),
              ],
            ),
          ),
        ),
        Container(width: 1, color: const Color(0xFF444444)),
        // Colonne droite — captures écran eFlexApp
        Expanded(
          child: Container(
            color: _bgRight,
            child: Column(
              children: [
                _columnHeader(
                    '📱 eFlexApp', accService.entryCount, Colors.greenAccent),
                Expanded(child: _buildScreenList(accService)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _columnHeader(String title, int count, Color accentColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: const Color(0xFF252525),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
          const Spacer(),
          Text('$count',
              style:
                  const TextStyle(color: Color(0xFFAAAAAA), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildBleList(List<BlePacket> packets) {
    if (packets.isEmpty) {
      return const Center(
        child: Text('En attente de paquets…',
            style: TextStyle(color: Color(0xFF666666), fontSize: 12)),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: packets.length,
      itemBuilder: (ctx, i) => _buildBlePacketTile(packets[i]),
    );
  }

  Widget _buildBlePacketTile(BlePacket packet) {
    final ts = DateFormat('HH:mm:ss.SSS').format(packet.timestamp);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: packet.isHighlighted
          ? _orange.withValues(alpha: 0.18)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(ts,
                  style: const TextStyle(
                      color: Color(0xFF888888), fontSize: 9)),
              const SizedBox(width: 6),
              Text(packet.shortUuid,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      color: _orange,
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 2),
          Text(packet.hexValue,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white,
                  fontSize: 11)),
          if (packet.asciiValue.isNotEmpty)
            Text('"${packet.asciiValue}"',
                style: const TextStyle(
                    color: Color(0xFF88CC88), fontSize: 10)),
          Wrap(
            spacing: 8,
            children: [
              if (packet.uint8Value != null)
                _decodeBadge('u8', '${packet.uint8Value}'),
              if (packet.uint16Value != null)
                _decodeBadge('u16', '${packet.uint16Value}'),
              if (packet.float32Value != null)
                _decodeBadge(
                    'f32', packet.float32Value!.toStringAsFixed(2)),
            ],
          ),
          const Divider(height: 6, color: Color(0xFF333333)),
        ],
      ),
    );
  }

  Widget _decodeBadge(String type, String value) {
    return Text(
      '$type:$value',
      style: const TextStyle(
          color: Color(0xFFAAAA44),
          fontSize: 9,
          fontFamily: 'monospace'),
    );
  }

  Widget _buildScreenList(AccessibilityService accService) {
    if (accService.entries.isEmpty) {
      return const Center(
        child: Text(
          'En attente de données écran…\n(eFlexApp doit être ouverte)',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF666666), fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: accService.entries.length,
      itemBuilder: (ctx, i) =>
          _buildScreenEntryTile(accService.entries[i]),
    );
  }

  Widget _buildScreenEntryTile(ScreenEntry entry) {
    final ts = DateFormat('HH:mm:ss.SSS').format(entry.timestamp);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ts,
              style:
                  const TextStyle(color: Color(0xFF888888), fontSize: 9)),
          const SizedBox(height: 2),
          Text(entry.displayText,
              style:
                  const TextStyle(color: Colors.white, fontSize: 11)),
          const Divider(height: 6, color: Color(0xFF333333)),
        ],
      ),
    );
  }

  Widget _buildBottomBar(
    BleService bleService,
    HciSnoopService snoopService,
    AccessibilityService accService,
  ) {
    return Container(
      color: const Color(0xFF222222),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade400,
                side: BorderSide(color: Colors.grey.shade700),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Effacer logs',
                  style: TextStyle(fontSize: 12)),
              onPressed: () {
                bleService.clearPackets();
                snoopService.clearPackets();
                accService.clearEntries();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF333333),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('Exporter JSON',
                  style: TextStyle(fontSize: 12)),
              onPressed: _exportJson,
            ),
          ),
        ],
      ),
    );
  }
}
