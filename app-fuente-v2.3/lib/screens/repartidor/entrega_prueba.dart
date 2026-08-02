import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../main.dart';
import '../../servicios/cola_offline.dart';

/// Pantalla de cierre de entrega: nombre + RUT + 3 fotos obligatorias.
class EntregaPruebaScreen extends StatefulWidget {
  final Map<String, dynamic> pedido;
  const EntregaPruebaScreen({super.key, required this.pedido});

  @override
  State<EntregaPruebaScreen> createState() => _EntregaPruebaScreenState();
}

class _EntregaPruebaScreenState extends State<EntregaPruebaScreen> {
  final _nombre = TextEditingController();
  final _rut = TextEditingController();
  final Map<String, XFile?> _fotos = {
    'domicilio': null,
    'pedido': null,
    'receptor': null,
  };
  bool _subiendo = false;
  String? _error;

  static const _slots = [
    ('domicilio', '🏠 Domicilio', 'Fachada donde se vea el número'),
    ('pedido', '📦 Pedido', 'El pedido que estás entregando'),
    ('receptor', '🤝 Receptor', 'Persona con el pedido en la mano'),
  ];

  bool get _completo =>
      _nombre.text.trim().length >= 3 &&
      _rutValido(_rut.text) &&
      _fotos.values.every((f) => f != null);

  /// Validación de RUT chileno (formato + dígito verificador).
  bool _rutValido(String texto) {
    final limpio =
        texto.replaceAll('.', '').replaceAll('-', '').toUpperCase().trim();
    if (limpio.length < 8) return false;
    final cuerpo = limpio.substring(0, limpio.length - 1);
    final dv = limpio.substring(limpio.length - 1);
    if (int.tryParse(cuerpo) == null) return false;
    int suma = 0, mult = 2;
    for (int i = cuerpo.length - 1; i >= 0; i--) {
      suma += int.parse(cuerpo[i]) * mult;
      mult = mult == 7 ? 2 : mult + 1;
    }
    final resto = 11 - (suma % 11);
    final dvCalc = resto == 11 ? '0' : (resto == 10 ? 'K' : '$resto');
    return dv == dvCalc;
  }

  Future<void> _tomarFoto(String slot) async {
    try {
      final foto = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 55,
        maxWidth: 1280,
      );
      if (foto != null) setState(() => _fotos[slot] = foto);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo abrir la cámara')));
      }
    }
  }

  /// La entrega SIEMPRE pasa por la cola: si hay señal se sube al instante;
  /// si no, queda guardada en el teléfono y se sube sola después.
  Future<void> _finalizar() async {
    setState(() {
      _subiendo = true;
      _error = null;
    });
    try {
      final id = widget.pedido['id'];
      // copiar las fotos a la carpeta permanente de la app
      final rutas = <String, String>{};
      for (final slot in _fotos.keys) {
        try {
          rutas[slot] =
              await ColaOffline.copiarPermanente(_fotos[slot]!.path, slot);
        } catch (_) {
          rutas[slot] = _fotos[slot]!.path;
        }
      }
      await ColaOffline.agregar({
        'tipo': 'entrega',
        'pedido_id': id,
        'nombre': _nombre.text.trim(),
        'rut': _rut.text.trim().toUpperCase(),
        'fotos': rutas,
      });
      await ColaOffline.procesar();
      final pendientes = await ColaOffline.pendientes();
      if (mounted) {
        Navigator.pop(context, pendientes == 0 ? 'ok' : 'offline');
      }
    } catch (_) {
      setState(() =>
          _error = 'No se pudo guardar. Intenta de nuevo.');
    } finally {
      if (mounted) setState(() => _subiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pedido;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Finalizar entrega',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text('${p['codigo'] ?? ''} · ${p['cliente_nombre']}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(height: 18),
          const Text('¿Quién recibe?',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 10),
          TextField(
            controller: _nombre,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'Nombre de quien recibe',
                prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rut,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'RUT (ej: 12.345.678-9)',
              prefixIcon: const Icon(Icons.badge_outlined),
              suffixIcon: _rut.text.isEmpty
                  ? null
                  : Icon(
                      _rutValido(_rut.text)
                          ? Icons.check_circle
                          : Icons.error_outline,
                      color: _rutValido(_rut.text)
                          ? const Color(0xFF0CA30C)
                          : Colors.red),
            ),
          ),
          const SizedBox(height: 22),
          const Text('Las 3 fotos obligatorias',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 10),
          for (final (slot, titulo, ayuda) in _slots) ...[
            InkWell(
              onTap: _subiendo ? null : () => _tomarFoto(slot),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: _fotos[slot] != null
                          ? const Color(0xFF0CA30C)
                          : Colors.black.withValues(alpha: .1),
                      width: _fotos[slot] != null ? 1.6 : 1),
                ),
                child: Row(
                  children: [
                    if (_fotos[slot] != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(File(_fotos[slot]!.path),
                            width: 54, height: 54, fit: BoxFit.cover),
                      )
                    else
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF1E8),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.photo_camera_outlined,
                            color: naranjaZas),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(titulo,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          Text(_fotos[slot] != null ? 'Lista ✓ (toca para repetir)' : ayuda,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: _fotos[slot] != null
                                      ? const Color(0xFF0CA30C)
                                      : Colors.grey.shade600)),
                        ],
                      ),
                    ),
                    Icon(
                        _fotos[slot] != null
                            ? Icons.check_circle
                            : Icons.chevron_right,
                        color: _fotos[slot] != null
                            ? const Color(0xFF0CA30C)
                            : Colors.grey.shade400),
                  ],
                ),
              ),
            ),
          ],
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                  color: const Color(0xFFFDECEC),
                  borderRadius: BorderRadius.circular(12)),
              child: Text(_error!,
                  style: const TextStyle(color: Color(0xFFB3261E))),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _completo && !_subiendo ? _finalizar : null,
            child: _subiendo
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('✓ Finalizar entrega'),
          ),
          if (!_completo)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Completa nombre, RUT válido y las 3 fotos para finalizar.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }
}
