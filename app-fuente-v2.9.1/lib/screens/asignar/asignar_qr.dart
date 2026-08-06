import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../main.dart';
import '../repartidor/escaner_carga.dart' show leerEtiqueta;

const _gris = Color(0xFF9A978F);

/// Un repartidor de la empresa, tal como lo devuelve la base.
class RepartidorChip {
  final String? id; // null = «solo cargar», sin repartidor
  final String nombre;

  /// Lo que tiene encima sin terminar. NO es «los de hoy»: los pedidos de
  /// MercadoLibre entran la tarde anterior, y contarlos por fecha de entrada
  /// hacía que se escanearan 20 bultos y el número dijera 14.
  int activos;

  RepartidorChip(this.id, this.nombre, this.activos);
}

/// Lo que se asignó en esta sesión de bodega, para poder deshacerlo.
class Asignado {
  final int pedidoId;
  final String codigo;
  final String repartidor;
  final String comuna;
  Asignado(this.pedidoId, this.codigo, this.repartidor, this.comuna);
}

/// Pantalla de bodega: elegís un repartidor arriba y vas pasando bultos
/// frente a la cámara. Cada escaneo deja el pedido a nombre de esa persona
/// (y, si estaba compartido, se lo queda tu empresa en ese mismo momento).
///
/// Solo la ven las cuentas con el permiso `puede_asignar`.
class AsignarQrScreen extends StatefulWidget {
  const AsignarQrScreen({super.key});

  @override
  State<AsignarQrScreen> createState() => _AsignarQrScreenState();
}

class _AsignarQrScreenState extends State<AsignarQrScreen> {
  List<RepartidorChip> _repartidores = [];
  RepartidorChip? _elegido;
  bool _cargandoLista = true;
  String? _errorLista;

  final List<Asignado> _hechos = [];
  String _mensaje = 'Elegí a quién le vas a asignar los bultos';
  Color _color = Colors.white;
  String? _ultimoCodigo;
  DateTime _ultimaVez = DateTime.fromMillisecondsSinceEpoch(0);
  bool _ocupado = false;
  final _sonido = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _sonido.setReleaseMode(ReleaseMode.stop);
    _sonido.setPlayerMode(PlayerMode.lowLatency);
    _cargarRepartidores();
  }

  @override
  void dispose() {
    _sonido.dispose();
    super.dispose();
  }

  Future<void> _cargarRepartidores() async {
    setState(() {
      _cargandoLista = true;
      _errorLista = null;
    });
    try {
      final rows = await supa
          .rpc('repartidores_para_asignar')
          .timeout(const Duration(seconds: 15));
      final lista = <RepartidorChip>[];
      for (final r in List<Map<String, dynamic>>.from(rows as List)) {
        lista.add(RepartidorChip(
          r['id'] as String?,
          (r['nombre'] ?? 'Sin nombre').toString(),
          // `pedidos_hoy` es el nombre viejo: queda de respaldo por si la
          // base todavía no corrió la migración actualizada.
          ((r['pedidos_activos'] ?? r['pedidos_hoy']) as num?)?.toInt() ?? 0,
        ));
      }
      if (!mounted) return;
      setState(() {
        _repartidores = lista;
        _cargandoLista = false;
        // si el que estaba elegido sigue en la lista, se respeta
        if (_elegido?.id != null) {
          _elegido = lista.firstWhere((r) => r.id == _elegido!.id,
              orElse: () => _elegido!);
        }
      });
      if (lista.isEmpty) {
        setState(() => _errorLista =
            'Tu empresa no tiene repartidores activos todavía.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargandoLista = false;
        _errorLista = e.toString().contains('repartidores_para_asignar')
            ? 'Falta correr la migración «asignar por QR» en la base.'
            : 'No se pudo cargar la lista. Revisá tu internet.';
      });
    }
  }

  Future<void> _feedback({required bool ok}) async {
    try {
      if (ok) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.heavyImpact();
        Future.delayed(const Duration(milliseconds: 160),
            () => HapticFeedback.heavyImpact());
      }
    } catch (_) {}
    try {
      await _sonido.stop();
      await _sonido.play(AssetSource(ok ? 'bip-ok.wav' : 'bip-error.wav'),
          volume: 1.0);
    } catch (_) {}
  }

  void _aviso(String m, Color c) {
    if (!mounted) return;
    setState(() {
      _mensaje = m;
      _color = c;
    });
  }

  /// Cuántos bultos lleva asignados en ESTA sesión el repartidor elegido.
  int get _enEstaSesion => _hechos
      .where((h) => h.repartidor == (_elegido?.nombre ?? ''))
      .length;

  Future<void> _onDetect(BarcodeCapture captura) async {
    if (_elegido == null) {
      _aviso('Primero elegí un repartidor arriba ☝️', const Color(0xFFFFD54F));
      return;
    }
    for (final b in captura.barcodes) {
      final texto = b.rawValue?.trim();
      if (texto == null || texto.isEmpty) continue;
      final ahora = DateTime.now();
      if (texto == _ultimoCodigo &&
          ahora.difference(_ultimaVez).inSeconds < 3) {
        continue;
      }
      _ultimoCodigo = texto;
      _ultimaVez = ahora;
      await _asignar(texto);
    }
  }

  Future<void> _asignar(String texto) async {
    if (_ocupado) return;
    final datos = leerEtiqueta(texto);
    if (datos.vacia) {
      await _feedback(ok: false);
      _aviso('❌ Etiqueta no reconocida', const Color(0xFFFF8A80));
      return;
    }
    final destino = _elegido!;
    _ocupado = true;
    _aviso('Buscando el pedido…', Colors.white);
    try {
      final r = await supa.rpc('asignar_por_escaneo', params: {
        'p_codigo': datos.codigo,
        'p_envio_id': datos.envioId,
        'p_externo_id': datos.externoId,
        'p_repartidor': destino.id,
      }).timeout(const Duration(seconds: 15));

      final m = (r is Map) ? Map<String, dynamic>.from(r) : <String, dynamic>{};
      if (m['ok'] != true) {
        await _feedback(ok: false);
        _aviso('❌ ${m['motivo'] ?? 'No se pudo asignar'}',
            const Color(0xFFFF8A80));
        return;
      }

      final id = (m['pedido_id'] as num?)?.toInt();
      final codigo = (m['codigo'] ?? '').toString();
      final comuna = (m['comuna'] ?? '').toString();
      final quitadoA = (m['quitado_a'] ?? '').toString();
      if (id != null) {
        setState(() {
          // el mismo bulto pasado dos veces cuenta una sola: la tanda tiene
          // que decir cuántos bultos hay, no cuántos escaneos hubo
          _hechos.removeWhere((h) => h.pedidoId == id);
          _hechos.add(Asignado(id, codigo, destino.nombre, comuna));
          destino.activos =
              (m['total_repartidor'] as num?)?.toInt() ?? (destino.activos + 1);
        });
      }
      await _feedback(ok: true);
      final donde = comuna.isEmpty ? '' : ' · $comuna';
      if (destino.id == null) {
        _aviso('✓ Cargado$donde — sin repartidor', const Color(0xFF69F0AE));
      } else if (quitadoA.isNotEmpty) {
        _aviso('🔄 Pasó de $quitadoA a ${destino.nombre}$donde',
            const Color(0xFFFFD54F));
      } else {
        _aviso('✓ ${destino.nombre}$donde  ·  $_enEstaSesion en esta tanda',
            const Color(0xFF69F0AE));
      }
    } catch (e) {
      await _feedback(ok: false);
      _aviso(
          e.toString().contains('asignar_por_escaneo')
              ? '⚠️ Falta correr la migración «asignar por QR» en la base'
              : '⚠️ Sin conexión — probá de nuevo',
          const Color(0xFFFFCC80));
    } finally {
      _ocupado = false;
    }
  }

  Future<void> _deshacerUltimo() async {
    if (_hechos.isEmpty) return;
    final ultimo = _hechos.last;
    _aviso('Deshaciendo ${ultimo.codigo}…', Colors.white);
    try {
      final r = await supa.rpc('deshacer_asignacion',
          params: {'p_pedido_id': ultimo.pedidoId}).timeout(
          const Duration(seconds: 15));
      final m = (r is Map) ? Map<String, dynamic>.from(r) : <String, dynamic>{};
      if (m['ok'] == true) {
        setState(() {
          _hechos.removeLast();
          final rep = _repartidores
              .where((x) => x.nombre == ultimo.repartidor)
              .toList();
          if (rep.isNotEmpty && rep.first.activos > 0) {
            rep.first.activos--;
          }
        });
        await _feedback(ok: true);
        _aviso('↩️ ${ultimo.codigo} deshecho', const Color(0xFFFFD54F));
      } else {
        await _feedback(ok: false);
        _aviso('❌ ${m['motivo'] ?? 'No se pudo deshacer'}',
            const Color(0xFFFF8A80));
      }
    } catch (_) {
      await _feedback(ok: false);
      _aviso('⚠️ Sin conexión para deshacer', const Color(0xFFFFCC80));
    }
  }

  void _verTanda() {
    final porRepartidor = <String, List<Asignado>>{};
    for (final h in _hechos) {
      porRepartidor.putIfAbsent(h.repartidor, () => []).add(h);
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Asignaste ${_hechos.length} bultos',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              const Text('En esta tanda, desde que abriste la pantalla',
                  style: TextStyle(fontSize: 12.5, color: _gris)),
              const SizedBox(height: 14),
              if (_hechos.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('Todavía no escaneaste ningún bulto.',
                      style: TextStyle(color: _gris)),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.5),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: porRepartidor.entries.map((e) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${e.key} · ${e.value.length}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: e.value
                                    .map((h) => Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 7),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF1FAF1),
                                            border: Border.all(
                                                color:
                                                    const Color(0xFFCDE8CD)),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                              h.comuna.isEmpty
                                                  ? h.codigo
                                                  : '${h.codigo} · ${h.comuna}',
                                              style: const TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: Color(0xFF0A6B0A))),
                                        ))
                                    .toList(),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Seguir escaneando')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- selector de repartidor ----------
  Widget _selector() {
    if (_cargandoLista) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
            child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))),
      );
    }
    if (_errorLista != null && _repartidores.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          children: [
            Text(_errorLista!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFCC80))),
            TextButton(
                onPressed: _cargarRepartidores,
                child: const Text('Reintentar',
                    style: TextStyle(color: Colors.white))),
          ],
        ),
      );
    }
    final chips = <RepartidorChip>[
      ..._repartidores,
      RepartidorChip(null, 'Solo cargar', 0),
    ];
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final r = chips[i];
          final sel = _elegido != null &&
              _elegido!.id == r.id &&
              _elegido!.nombre == r.nombre;
          return Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: () {
                setState(() => _elegido = r);
                _aviso(
                    r.id == null
                        ? 'Solo cargar: los bultos quedan de tu empresa, sin repartidor'
                        : 'Escaneá los bultos de ${r.nombre}',
                    Colors.white);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: sel ? naranjaZas : Colors.black54,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                      color: sel ? Colors.white : Colors.white24, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (r.id == null)
                      const Icon(Icons.inventory_2_outlined,
                          color: Colors.white70, size: 17)
                    else
                      Icon(Icons.person,
                          color: sel ? Colors.white : Colors.white70, size: 17),
                    const SizedBox(width: 7),
                    Text(r.nombre,
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight:
                                sel ? FontWeight.w800 : FontWeight.w600,
                            fontSize: 14.5)),
                    if (r.id != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: sel ? Colors.white24 : Colors.white10,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text('${r.activos}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listo = _elegido != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (listo) MobileScanner(onDetect: _onDetect),
          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back,
                          color: Colors.white, size: 28),
                    ),
                    const Expanded(
                      child: Text('Asignar por QR',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800)),
                    ),
                    InkWell(
                      onTap: _verTanda,
                      borderRadius: BorderRadius.circular(99),
                      child: Container(
                        margin: const EdgeInsets.only(right: 12),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${_hechos.length}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 20)),
                            const SizedBox(width: 6),
                            const Icon(Icons.expand_more,
                                color: Colors.white70, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                _selector(),
                const Text('elegí a quién, después pasá los bultos',
                    style: TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                if (listo)
                  Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: naranjaZas, width: 3),
                      borderRadius: BorderRadius.circular(24),
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      children: [
                        Text('👆', style: TextStyle(fontSize: 40)),
                        SizedBox(height: 10),
                        Text(
                            'Elegí un repartidor arriba para encender la cámara',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                const Spacer(),
                Container(
                  margin: const EdgeInsets.fromLTRB(18, 12, 18, 10),
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
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _hechos.isEmpty ? null : _deshacerUltimo,
                          icon: const Icon(Icons.undo, size: 19),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            disabledForegroundColor: Colors.white30,
                            side: BorderSide(
                                color: _hechos.isEmpty
                                    ? Colors.white24
                                    : Colors.white70),
                          ),
                          label: const Text('Deshacer último'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Listo'),
                        ),
                      ),
                    ],
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
