import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../main.dart';

/// Escáner de etiquetas QR para validar la carga: apunta la cámara a la
/// etiqueta de cada bulto (impresa desde el manifiesto del panel) y el
/// pedido queda marcado solo.
class EscanerCargaScreen extends StatefulWidget {
  final List<Map<String, dynamic>> pedidos;
  final Set<int> validados;
  const EscanerCargaScreen(
      {super.key, required this.pedidos, required this.validados});

  @override
  State<EscanerCargaScreen> createState() => _EscanerCargaScreenState();
}

class _EscanerCargaScreenState extends State<EscanerCargaScreen> {
  late final Set<int> _marcados = {...widget.validados};
  String _mensaje = 'Apunta al QR de la etiqueta del bulto';
  Color _color = Colors.white;
  String? _ultimoCodigo;
  DateTime _ultimaVez = DateTime.fromMillisecondsSinceEpoch(0);

  void _aviso(String m, Color c) {
    if (!mounted) return;
    setState(() {
      _mensaje = m;
      _color = c;
    });
  }

  void _onDetect(BarcodeCapture captura) {
    for (final b in captura.barcodes) {
      final texto = b.rawValue?.trim();
      if (texto == null || texto.isEmpty) continue;
      // no repetir el mismo aviso mientras el QR sigue frente a la cámara
      final ahora = DateTime.now();
      if (texto == _ultimoCodigo &&
          ahora.difference(_ultimaVez).inSeconds < 3) {
        continue;
      }
      _ultimoCodigo = texto;
      _ultimaVez = ahora;

      final p = widget.pedidos.firstWhere(
        (x) => (x['codigo'] ?? '') == texto || '#${x['id']}' == texto,
        orElse: () => const <String, dynamic>{},
      );
      if (p.isEmpty) {
        _aviso('❌ $texto no es de esta ruta', const Color(0xFFFF8A80));
        continue;
      }
      final id = p['id'] as int;
      if (_marcados.contains(id)) {
        _aviso('Ya estaba marcado: ${p['codigo']}', const Color(0xFFFFD54F));
        continue;
      }
      setState(() => _marcados.add(id));
      _aviso('✓ ${p['codigo']} · ${p['cliente_nombre']}',
          const Color(0xFF69F0AE));
      if (_marcados.length >= widget.pedidos.length) {
        Timer(const Duration(milliseconds: 700), () {
          if (mounted) Navigator.pop(context, _marcados);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.pedidos.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context, _marcados),
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white, size: 28),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text('${_marcados.length} de $total escaneados',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 15)),
                      ),
                      const Spacer(),
                      const SizedBox(width: 44),
                    ],
                  ),
                ),
                const Spacer(),
                // marco guía
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(color: naranjaZas, width: 3),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                const Spacer(),
                Container(
                  margin: const EdgeInsets.all(18),
                  padding: const EdgeInsets.all(14),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(_mensaje,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _color,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, _marcados),
                      child: const Text('Listo — volver a la lista'),
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
