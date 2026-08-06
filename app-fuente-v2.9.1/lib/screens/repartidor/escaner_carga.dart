import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../main.dart';

/// Lo que la etiqueta permite buscar en la base: cada formato de QR aporta
/// un identificador distinto.
class DatosEtiqueta {
  final String? codigo;     // ZAS-00123
  final String? envioId;    // n° de envío de MercadoLibre Flex
  final String? externoId;  // n° de pedido en la tienda (Jumpseller / ML)
  const DatosEtiqueta({this.codigo, this.envioId, this.externoId});
  bool get vacia => codigo == null && envioId == null && externoId == null;
}

/// Traduce lo leído por la cámara a los identificadores que entiende la base.
DatosEtiqueta leerEtiqueta(String texto) {
  final t = texto.trim();
  if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t);
      if (j is Map) {
        // MercadoLibre Flex: {"id": 44001122333}
        if (j['id'] != null) return DatosEtiqueta(envioId: j['id'].toString());
        // Jumpseller timbrado desde el portal: {"t":"ZJS","o":82652,...}
        if (j['o'] != null) return DatosEtiqueta(externoId: j['o'].toString());
      }
    } catch (_) {}
    return const DatosEtiqueta();
  }
  if (t.isEmpty) return const DatosEtiqueta();
  if (t.toUpperCase().startsWith('ZAS-')) return DatosEtiqueta(codigo: t.toUpperCase());
  // un número pelado puede ser el n° de pedido de la tienda o el de envío
  return DatosEtiqueta(envioId: t, externoId: t);
}

const _gris = Color(0xFF9A978F);

/// Número que el repartidor ve en la etiqueta: el de la tienda si existe
/// (Jumpseller / MercadoLibre) y si no, el código interno de ZAS.
String numeroDeOrden(Map<String, dynamic> p) {
  final externo = (p['externo_id'] ?? '').toString();
  if (externo.isNotEmpty) return externo;
  final codigo = (p['codigo'] ?? '').toString();
  if (codigo.isNotEmpty) return codigo;
  return '#${p['id']}';
}

/// Quita tildes, pasa a minúscula y deja solo letras/números/espacios, para
/// poder comparar direcciones de forma tolerante a mayúsculas, tildes o
/// pequeñas diferencias de tipeo.
String _normalizar(String s) {
  const con = 'áéíóúÁÉÍÓÚñÑ';
  const sin = 'aeiouAEIOUnN';
  var r = s;
  for (var i = 0; i < con.length; i++) {
    r = r.replaceAll(con[i], sin[i]);
  }
  return r
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Resultado de buscar un pedido a partir de lo leído por la cámara: el
/// pedido encontrado y si, además del identificador principal, un segundo
/// dato de la etiqueta (la dirección) coincide también con el pedido.
class Hallazgo {
  final Map<String, dynamic> pedido;
  final bool confirmado;
  Hallazgo(this.pedido, this.confirmado);
}

/// Reconoce 4 tipos de etiqueta:
/// 1. ZAS (manifiesto del panel): el QR trae el código, ej "ZAS-00123".
/// 2. MercadoLibre Flex: el QR trae un JSON con el n° de envío en "id"
///    → se compara con el envio_id guardado al entrar la venta.
/// 3. Jumpseller timbrado desde el portal de la empresa: el QR trae un
///    JSON con t=ZJS, o=n° de pedido, r=RUT y d=dirección → "o" se compara
///    con el Cód. envío (externo_id) y, si viene "d", se contrasta además
///    con la dirección del pedido para confirmar que el bulto es el
///    correcto (al menos 2 datos: pedido + rut y/o dirección).
/// 4. Un número pelado (QR o código de barras): se compara con el
///    "Cód. envío" (n° de pedido Jumpseller / orden ML) y el n° de envío.
Hallazgo? buscarPedidoEnRuta(List<Map<String, dynamic>> pedidos, String texto) {
  final t = texto.trim();
  String? mlId;
  String? jsOrden, jsDir;
  if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t);
      if (j is Map) {
        if (j['id'] != null) mlId = j['id'].toString();
        if (j['o'] != null) jsOrden = j['o'].toString();
        if (j['d'] != null) jsDir = j['d'].toString();
      }
    } catch (_) {}
  }
  for (final p in pedidos) {
    final codigo = (p['codigo'] ?? '').toString();
    final externo = (p['externo_id'] ?? '').toString();
    final envio = (p['envio_id'] ?? '').toString();
    if (codigo == t || '#${p['id']}' == t) return Hallazgo(p, true);
    if (t.isNotEmpty &&
        (externo == t ||
            externo == 'ML-$t' ||
            (envio.isNotEmpty && envio == t))) {
      return Hallazgo(p, true);
    }
    if (mlId != null && (envio == mlId || externo == 'ML-$mlId')) {
      return Hallazgo(p, true);
    }
    if (jsOrden != null && jsOrden.isNotEmpty && externo == jsOrden) {
      final dirPedido = _normalizar((p['direccion'] ?? '').toString());
      final dirQr = jsDir != null ? _normalizar(jsDir) : '';
      final confirmado = dirQr.isEmpty ||
          dirPedido.contains(dirQr) ||
          dirQr.contains(dirPedido) ||
          dirPedido
              .split(' ')
              .where((w) => w.length > 2)
              .any((w) => dirQr.contains(w));
      return Hallazgo(p, confirmado);
    }
  }
  return null;
}

/// Cuando el código no calza con ningún pedido de la ruta, explica por qué:
/// no es lo mismo "esta etiqueta no la entiendo" que "esta etiqueta la leí
/// bien pero ese pedido no es tuyo hoy" o "falta un dato en el sistema".
String porQueNoCalza(List<Map<String, dynamic>> pedidos, String texto) {
  final t = texto.trim();
  if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t);
      if (j is Map) {
        if (j['t'] == 'ZJS' && j['o'] != null) {
          return '❌ Pedido ${j['o']} — no está asignado a tu ruta de hoy';
        }
        if (j['id'] != null) {
          // Caso típico: la venta de MercadoLibre entró antes de que ZAS
          // guardara el n° de envío, así que la etiqueta Flex no tiene con
          // qué calzar. No es culpa del repartidor: hay que sincronizar.
          final faltaEnvio = pedidos.any((p) {
            final ext = (p['externo_id'] ?? '').toString();
            final env = (p['envio_id'] ?? '').toString();
            return ext.startsWith('ML-') && env.isEmpty;
          });
          if (faltaEnvio) {
            return '⚠️ Etiqueta Flex leída OK, pero a tus ventas de MercadoLibre '
                'les falta el n° de envío en el sistema — avisa a la oficina';
          }
          return '❌ Envío ${j['id']} — no está en tu ruta de hoy';
        }
      }
    } catch (_) {}
    return '❌ Etiqueta no reconocida';
  }
  if (t.length <= 24) return '❌ $t — no está en tu ruta de hoy';
  return '❌ Este código no es una etiqueta de ZAS, Flex ni Jumpseller';
}

/// Escáner de etiquetas QR para validar la carga.
///
/// Se usa como pantalla previa a la ruta: el repartidor NO ve el listado de
/// pedidos asignados, solo la cámara y un contador (ej. "7/20"). Los bultos
/// se van cargando de a uno al escanearlos y recién cuando están todos
/// puede partir la ruta.
class EscanerCargaScreen extends StatefulWidget {
  final List<Map<String, dynamic>> pedidos;
  final Set<int> validados;

  /// true cuando se usa incrustado dentro de otra pantalla (sin su propio
  /// Scaffold ni botón de "volver") — así lo usa repartidor_home.dart.
  final bool embebido;

  /// se llama cada vez que cambia el conjunto de pedidos validados
  /// (solo aplica en modo embebido).
  final ValueChanged<Set<int>>? onCambio;

  /// se llama cuando el repartidor reclamó un pedido del pool escaneándolo:
  /// la pantalla de arriba tiene que recargar su ruta desde la base.
  final Future<void> Function()? onReclamado;

  const EscanerCargaScreen({
    super.key,
    required this.pedidos,
    required this.validados,
    this.embebido = false,
    this.onCambio,
    this.onReclamado,
  });

  @override
  State<EscanerCargaScreen> createState() => _EscanerCargaScreenState();
}

class _EscanerCargaScreenState extends State<EscanerCargaScreen> {
  late final Set<int> _marcados = {...widget.validados};
  String _mensaje = 'Apunta al QR de la etiqueta del bulto';
  Color _color = Colors.white;
  String? _ultimoCodigo;
  DateTime _ultimaVez = DateTime.fromMillisecondsSinceEpoch(0);
  final _sonido = AudioPlayer();
  bool _reclamando = false;

  @override
  void initState() {
    super.initState();
    // el bip debe oírse aunque el teléfono esté en modo bajo/silencioso de medios
    _sonido.setReleaseMode(ReleaseMode.stop);
    _sonido.setPlayerMode(PlayerMode.lowLatency);
  }

  @override
  void dispose() {
    _sonido.dispose();
    super.dispose();
  }

  /// Bip + vibración: el repartidor no tiene que mirar la pantalla para saber
  /// si el bulto quedó cargado.
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
    } catch (_) {/* sin audio disponible: la vibración ya avisó */}
  }

  void _aviso(String m, Color c) {
    if (!mounted) return;
    setState(() {
      _mensaje = m;
      _color = c;
    });
  }

  /// Lista de lo ya cargado, SOLO con el número de orden — sirve para
  /// descubrir rápido cuál bulto falta sin exponer los datos del cliente.
  void _verCargados() {
    final cargados = widget.pedidos
        .where((p) => _marcados.contains(p['id'] as int))
        .map(numeroDeOrden)
        .toList();
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
              Text('Bultos cargados · ${cargados.length} de ${widget.pedidos.length}',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              const Text('N° de orden de lo que ya escaneaste',
                  style: TextStyle(fontSize: 12.5, color: _gris)),
              const SizedBox(height: 14),
              if (cargados.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('Todavía no escaneas ningún bulto.',
                      style: TextStyle(color: _gris)),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.5),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: cargados
                          .map((n) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1FAF1),
                                  border:
                                      Border.all(color: const Color(0xFFCDE8CD)),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(n,
                                    style: const TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF0A6B0A))),
                              ))
                          .toList(),
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



  /// La etiqueta no calza con ningún pedido de la ruta. Puede ser que esté
  /// en el POOL: sin dueño, esperando que alguien lo cargue. Le preguntamos
  /// a la base si este repartidor se lo puede llevar.
  ///
  /// Es el único lugar donde un pedido cambia de empresa: el que lo carga
  /// se lo lleva. Si ya es de otra empresa, la base lo rechaza.
  Future<bool> _intentarReclamar(String texto) async {
    if (_reclamando) return false;
    final datos = leerEtiqueta(texto);
    if (datos.vacia) return false;

    _reclamando = true;
    _aviso('Buscando el pedido…', Colors.white);
    try {
      final r = await supa.rpc('reclamar_pedido', params: {
        'p_codigo': datos.codigo,
        'p_envio_id': datos.envioId,
        'p_externo_id': datos.externoId,
      }).timeout(const Duration(seconds: 12));

      final m = (r is Map) ? Map<String, dynamic>.from(r) : <String, dynamic>{};
      if (m['ok'] == true) {
        final id = m['pedido_id'];
        if (id is int) {
          setState(() => _marcados.add(id));
          widget.onCambio?.call(_marcados);
        }
        await _feedback(ok: true);
        final donde = (m['comuna'] ?? '').toString();
        _aviso(
          m['ya_era_mio'] == true
              ? '✓ Bulto cargado${donde.isEmpty ? '' : ' — $donde'}'
              : '🎉 Lo tomaste del pool: ya es tuyo${donde.isEmpty ? '' : ' — $donde'}',
          const Color(0xFF69F0AE),
        );
        // la ruta cambió: que la pantalla de arriba la vuelva a pedir
        await widget.onReclamado?.call();
        return true;
      }

      final motivo = (m['motivo'] ?? '').toString();
      if (motivo.isNotEmpty) {
        await _feedback(ok: false);
        _aviso('❌ $motivo', const Color(0xFFFF8A80));
        return true;   // ya avisamos con un motivo claro
      }
      return false;
    } catch (e) {
      final txt = e.toString();
      if (txt.contains('reclamar_pedido')) {
        // la migración del escaneo todavía no está corrida en la base
        return false;
      }
      await _feedback(ok: false);
      _aviso('⚠️ Sin conexión para comprobar este bulto — intenta de nuevo',
          const Color(0xFFFFCC80));
      return true;
    } finally {
      _reclamando = false;
    }
  }

  void _marcar(Map<String, dynamic> p, {required bool confirmado}) {
    final id = p['id'] as int;
    setState(() => _marcados.add(id));
    widget.onCambio?.call(_marcados);
    _feedback(ok: true);
    final total = widget.pedidos.length;
    if (_marcados.length >= total) {
      _aviso('🎉 Carga completa — ya puedes empezar a repartir',
          const Color(0xFF69F0AE));
      if (!widget.embebido) {
        Timer(const Duration(milliseconds: 700), () {
          if (mounted) Navigator.pop(context, _marcados);
        });
      }
      return;
    }
    if (confirmado) {
      _aviso('✓ Bulto cargado — faltan ${total - _marcados.length}',
          const Color(0xFF69F0AE));
    }
  }

  Future<void> _onDetect(BarcodeCapture captura) async {
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

      final hallazgo = buscarPedidoEnRuta(widget.pedidos, texto);
      if (hallazgo == null) {
        // no está en la ruta: puede estar en el pool esperando dueño
        final resuelto = await _intentarReclamar(texto);
        if (resuelto) continue;
        _aviso(porQueNoCalza(widget.pedidos, texto), const Color(0xFFFF8A80));
        _feedback(ok: false);
        continue;
      }
      final p = hallazgo.pedido;
      if (_marcados.contains(p['id'] as int)) {
        _aviso('Este bulto ya estaba cargado (${numeroDeOrden(p)})',
            const Color(0xFFFFD54F));
        _feedback(ok: false);
        continue;
      }
      if (!hallazgo.confirmado) {
        _aviso(
            '⚠️ Cargado, pero la dirección de la etiqueta no calza del todo — revisa el bulto',
            const Color(0xFFFFCC80));
        _marcar(p, confirmado: false);
        continue;
      }
      _marcar(p, confirmado: true);
    }
  }

  Widget _contenido() {
    final total = widget.pedidos.length;
    return Stack(
      children: [
        MobileScanner(onDetect: _onDetect),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    if (!widget.embebido)
                      IconButton(
                        onPressed: () => Navigator.pop(context, _marcados),
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white, size: 28),
                      )
                    else
                      const SizedBox(width: 44),
                    const Spacer(),
                    InkWell(
                      onTap: _verCargados,
                      borderRadius: BorderRadius.circular(99),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(22, 10, 16, 10),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text('${_marcados.length}',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 30)),
                                Text('/$total',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 20)),
                              ],
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.expand_more,
                                color: Colors.white70, size: 22),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 44),
                  ],
                ),
              ),
              const Text('toca el contador para ver los cargados',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .3)),
              const SizedBox(height: 2),
              const Text('ZAS Reparto v$versionApp',
                  style: TextStyle(color: Colors.white38, fontSize: 10.5)),
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
                margin: const EdgeInsets.fromLTRB(18, 18, 18, 22),
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
              if (!widget.embebido)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, _marcados),
                      child: const Text('Listo'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embebido) return _contenido();
    return Scaffold(backgroundColor: Colors.black, body: _contenido());
  }
}
