import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../services/settings_service.dart';
import 'main_screen.dart';

/// Écran de scan BLE : liste les appareils à portée et permet de se connecter
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const _orange = Color(0xFFFF6600);

  @override
  void initState() {
    super.initState();
    // Demande les permissions BLE au démarrage
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<BleService>().requestPermissions();
    });
  }

  /// Nombre de barres de signal (0 à 4) selon le RSSI
  int _signalBars(int rssi) {
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    if (rssi >= -90) return 1;
    return 0;
  }

  /// Vérifie si l'appareil est probablement un eFlexFuel
  bool _isEflex(ScanResult result, String nameFilter) {
    final name = (result.device.platformName +
            result.advertisementData.advName)
        .toLowerCase();
    return name.contains('eflex') ||
        name.contains('flex') ||
        (nameFilter.isNotEmpty && name.contains(nameFilter.toLowerCase()));
  }

  /// Widget d'indicateur de force du signal (barres verticales)
  Widget _buildSignalBars(int rssi) {
    final bars = _signalBars(rssi);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        return Container(
          width: 4,
          height: (i + 1) * 5.0,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: i < bars ? _orange : Colors.grey.shade700,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  /// Connexion à un appareil puis navigation vers l'écran principal
  Future<void> _connectToDevice(
      BleService bleService, BluetoothDevice device) async {
    await bleService.stopScan();
    await bleService.connectAndListen(device);
    if (!mounted) return;
    if (bleService.isConnected) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MainScreen()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(bleService.statusMessage.isNotEmpty
              ? bleService.statusMessage
              : 'Échec de connexion'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final nameFilter = context.watch<SettingsService>().nameFilter;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          'eFlexReverse — Scan BLE',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: Column(
        children: [
          // ── Bandeau d'avertissement mode direct ───────────────────────────
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.orange.shade900,
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Mode direct BLE — bloque l\'eFlexFuel app pendant la connexion. '
                    'Utilisez le mode HCI Snoop (écran principal) pour capturer sans bloquer.',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

          // ── Bouton Start / Stop scan ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      bleService.isScanning ? Colors.red.shade800 : _orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: Icon(bleService.isScanning
                    ? Icons.stop_circle_outlined
                    : Icons.bluetooth_searching),
                label: Text(
                  bleService.isScanning ? 'Arrêter le scan' : 'Démarrer le scan',
                  style: const TextStyle(fontSize: 16),
                ),
                onPressed: bleService.isConnecting
                    ? null
                    : () {
                        if (bleService.isScanning) {
                          bleService.stopScan();
                        } else {
                          bleService.startScan();
                        }
                      },
              ),
            ),
          ),

          // ── Barre de progression pendant le scan ──────────────────────────
          if (bleService.isScanning)
            const LinearProgressIndicator(
              backgroundColor: Color(0xFF333333),
              valueColor: AlwaysStoppedAnimation<Color>(_orange),
              minHeight: 2,
            ),

          // ── Compteur d'appareils ──────────────────────────────────────────
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.devices, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 6),
                Text(
                  '${bleService.scanResults.length} appareil(s) détecté(s)',
                  style: TextStyle(
                      color: Colors.grey.shade500, fontSize: 12),
                ),
                if (bleService.statusMessage.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Text(
                    bleService.statusMessage,
                    style: const TextStyle(
                        color: Color(0xFFAAAAAA), fontSize: 12),
                  ),
                ],
              ],
            ),
          ),

          // ── Liste des appareils ───────────────────────────────────────────
          Expanded(
            child: bleService.scanResults.isEmpty
                ? _buildEmptyState(bleService.isScanning)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: bleService.scanResults.length,
                    itemBuilder: (ctx, i) {
                      final result = bleService.scanResults[i];
                      return _buildDeviceTile(
                          result, bleService, nameFilter);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Tuile d'un appareil BLE détecté
  Widget _buildDeviceTile(
      ScanResult result, BleService bleService, String nameFilter) {
    final eflex = _isEflex(result, nameFilter);

    // Nom de l'appareil (priorité : platformName, sinon advName, sinon "Inconnu")
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : 'Appareil inconnu';

    return Card(
      color: eflex ? const Color(0xFF3A2010) : const Color(0xFF2A2A2A),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Indicateur signal + RSSI
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSignalBars(result.rssi),
                const SizedBox(height: 2),
                Text(
                  '${result.rssi} dBm',
                  style: const TextStyle(
                      fontSize: 9, color: Color(0xFFAAAAAA)),
                ),
              ],
            ),
            const SizedBox(width: 12),

            // Nom + adresse MAC
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Badge orange si probablement eFlexFuel
                      if (eflex) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _orange,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'eFlexFuel?',
                            style: TextStyle(
                                fontSize: 9,
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    result.device.remoteId.str,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFFAAAAAA),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Bouton Connecter
            bleService.isConnecting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _orange),
                  )
                : ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          eflex ? _orange : const Color(0xFF444444),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () =>
                        _connectToDevice(bleService, result.device),
                    child: const Text('Connecter'),
                  ),
          ],
        ),
      ),
    );
  }

  /// Écran vide quand aucun appareil n'est détecté
  Widget _buildEmptyState(bool isScanning) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isScanning
                ? Icons.bluetooth_searching
                : Icons.bluetooth_disabled,
            size: 72,
            color: isScanning ? _orange : const Color(0xFF444444),
          ),
          const SizedBox(height: 16),
          Text(
            isScanning
                ? 'Recherche en cours...'
                : 'Aucun appareil détecté\nLancez un scan BLE',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
          ),
        ],
      ),
    );
  }
}
