import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../main.dart';
import 'entrega_prueba.dart';

const _gris = Color(0xFF9A978F);
const _tinta = Color(0xFF161616);
const _verde = Color(0xFF0CA30C);

class RepartidorHome extends StatefulWidget {
  final Map<String, dynamic> perfil;
  const RepartidorHome({super.key, required this.perfil});

  @override
  State<RepartidorHome> createState() => _RepartidorHomeState();
}

class _RepartidorHomeState extends State<RepartidorHome>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _pedidos = [];
  bool _cargado = false;
  Timer? _sincronizador;
  RealtimeChannel? _canal;
  Map<int, Map<String, dynamic>> _clientes = {};
  bool _bioActiva = false;
  bool _repartiendo = false;
  final Set<int> _validados = {};
  StreamSubscription<Position>? _gps;

  // ---------- carga inicial ----------
  Future<void> _cargarClientes() async {
    final rows = await supa
        .from('clientes')
        .select('id, nombre, direccion_retiro, comuna');
    if (mounted) {
      setState(() => _clientes = {
            for (final c in rows) c['id'] as int: Map<String, dynamic>.from(c)
          });
    }
  }

  Future<void> _cargarPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _bioActiva = prefs.getBool('bio_activa') ?? false;
        _repartiendo = prefs.getBool('repartiendo') ?? false;
      });
      if (_repartiendo) _iniciarGps();
    }
    if (!(prefs.getBool('bio_ofrecida') ?? false)) {
      await prefs.setBool('bio_ofrecida', true);
      try {
        if (await LocalAuthentication().isDeviceSupported() && mounted) {
          Future.delayed(const Duration(milliseconds: 600), _ofrecerHuella);
        }
      } catch (_) {}
    }
  }

  /// Recarga la lista completa desde la base (fuente de la verdad).
  Future<void> _recargar() async {
    try {
      final rows = await supa
          .from('pedidos')
          .select()
          .eq('repartidor_id', supa.auth.currentUser!.id)
          .order('creado_en', ascending: false)
          .limit(100);
      if (mounted) {
        setState(() {
          _pedidos = List<Map<String, dynamic>>.from(rows);
          _cargado = true;
        });
      }
    } catch (_) {/* sin red: se reintenta en el próximo ciclo */}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cargarClientes();
    _cargarPrefs();
    _recargar();
    // 1) en vivo: cambios que llegan a mis pedidos
    _canal = supa
        .channel('mis-pedidos-app')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'pedidos',
          callback: (_) => _recargar(),
        )
        .subscribe();
    // 2) resincronización periódica: detecta pedidos QUITADOS o reasignados
    _sincronizador =
        Timer.periodic(const Duration(seconds: 20), (_) => _recargar());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    // 3) al volver a la app, refrescar de inmediato
    if (estado == AppLifecycleState.resumed) _recargar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sincronizador?.cancel();
    if (_canal != null) supa.removeChannel(_canal!);
    _gps?.cancel();
    super.dispose();
  }

  // ---------- GPS en vivo ----------
  Future<bool> _pedirUbicacion() async {
    var activado = await Geolocator.isLocationServiceEnabled();
    if (!activado) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Activa la ubicación (GPS) del teléfono para continuar')));
      }
      await Geolocator.openLocationSettings();
      return false;
    }
    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }
    if (permiso == LocationPermission.denied ||
        permiso == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Sin permiso de ubicación no se puede iniciar el reparto')));
      }
      return false;
    }
    return true;
  }

  void _iniciarGps() {
    _gps?.cancel();
    _gps = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 25),
    ).listen((pos) {
      supa.from('ubicaciones').upsert({
        'repartidor_id': supa.auth.currentUser!.id,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'actualizado_en': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> _empezarRuta() async {
    if (!await _pedirUbicacion()) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('repartiendo', true);
    _iniciarGps();
    if (mounted) setState(() => _repartiendo = true);
  }

  Future<void> _terminarJornada() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('repartiendo', false);
    _gps?.cancel();
    _validados.clear();
    if (mounted) setState(() => _repartiendo = false);
  }

  // ---------- huella ----------
  Future<void> _ofrecerHuella() async {
    if (!mounted) return;
    final activar = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fingerprint, size: 56, color: naranjaZas),
            const SizedBox(height: 12),
            const Text('¿Proteger la app con tu huella?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text(
                'Cada vez que abras ZAS Reparto se pedirá tu huella o el desbloqueo del teléfono.',
                textAlign: TextAlign.center),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Sí, activar huella')),
            ),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Ahora no')),
          ],
        ),
      ),
    );
    if (activar == true) await _cambiarBio(true);
  }

  Future<void> _cambiarBio(bool activar) async {
    if (activar) {
      try {
        final ok = await LocalAuthentication().authenticate(
          localizedReason: 'Confirma tu huella para activar el bloqueo',
          options: const AuthenticationOptions(stickyAuth: true),
        );
        if (!ok) return;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Tu teléfono no tiene huella configurada')));
        }
        return;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bio_activa', activar);
    if (mounted) {
      setState(() => _bioActiva = activar);
    }
  }

  // ---------- acciones sobre pedidos ----------
  Future<void> _cambiar(Map<String, dynamic> p, String nuevo) async {
    try {
      await supa.from('pedidos').update({'estado': nuevo}).eq('id', p['id']);
      await _recargar();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _noEntregado(Map<String, dynamic> p) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('No pude entregar'),
        content: TextField(
          controller: ctrl,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Motivo *'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Volver')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    await supa.from('pedidos').update({
      'estado': 'no_entregado',
      'nota_entrega': ctrl.text.trim(),
    }).eq('id', p['id']);
    await _recargar();
  }

  Future<void> _abrirMapa(Map<String, dynamic> p) async {
    final dir = Uri.encodeComponent(
        '${p['direccion']}${p['comuna'] != null ? ', ${p['comuna']}' : ''}');
    await launchUrl(
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$dir'),
        mode: LaunchMode.externalApplication);
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Hola, ${widget.perfil['nombre'].toString().split(' ').first} 👋',
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800, color: _tinta)),
            Text(_repartiendo ? 'Ruta en curso' : 'Tus repartos de hoy',
                style: TextStyle(
                    fontSize: 12,
                    color: _repartiendo ? naranjaZas : _gris,
                    fontWeight:
                        _repartiendo ? FontWeight.w700 : FontWeight.w400)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: _gris),
            onSelected: (v) {
              if (v == 'bio') _cambiarBio(!_bioActiva);
              if (v == 'salir') supa.auth.signOut();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'bio',
                  child: Text(_bioActiva
                      ? 'Desactivar huella'
                      : 'Activar huella')),
              const PopupMenuItem(value: 'salir', child: Text('Cerrar sesión')),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _recargar,
        child: Builder(builder: (context) {
          if (!_cargado) {
            return const Center(child: CircularProgressIndicator());
          }
          final activos = _pedidos
              .where((p) => !['entregado', 'cancelado', 'no_entregado']
                  .contains(p['estado']))
              .toList()
            ..sort((a, b) {
              final oa = (a['ruta_orden'] as int?) ?? 999;
              final ob = (b['ruta_orden'] as int?) ?? 999;
              if (oa != ob) return oa.compareTo(ob);
              return (a['id'] as int).compareTo(b['id'] as int);
            });
          final hechosHoy = _pedidos
              .where((p) =>
                  ['entregado', 'no_entregado'].contains(p['estado']))
              .toList();

          if (activos.isEmpty && !_repartiendo) {
            return _conScroll(_vacio(hechosHoy));
          }
          if (!_repartiendo) return _validacion(activos);
          if (activos.isEmpty) return _conScroll(_rutaCompletada(hechosHoy));
          return _paradaActual(activos, hechosHoy);
        }),
      ),
    );
  }

  /// Permite "deslizar para refrescar" incluso en pantallas sin lista.
  Widget _conScroll(Widget hijo) {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(height: c.maxHeight, child: hijo),
      ),
    );
  }

  // --- sin pedidos ---
  Widget _vacio(List<Map<String, dynamic>> hechos) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('📭', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 12),
            const Text('Sin pedidos asignados',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
                hechos.isEmpty
                    ? 'Cuando te asignen una ruta aparecerá aquí.'
                    : 'Hoy completaste ${hechos.length} entregas. ¡Buen trabajo!',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _gris)),
          ],
        ),
      ),
    );
  }

  // --- paso 1: validar la carga ---
  Widget _validacion(List<Map<String, dynamic>> activos) {
    final listos = activos.where((p) => _validados.contains(p['id'])).length;
    final completo = listos == activos.length;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            children: [
              const Text('Revisa tu carga',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              Text(
                  'Marca cada pedido cuando lo tengas contigo · $listos de ${activos.length}',
                  style: const TextStyle(fontSize: 12.5, color: _gris)),
              const SizedBox(height: 14),
              for (var i = 0; i < activos.length; i++)
                _filaValidacion(activos[i], i + 1),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: completo ? _empezarRuta : null,
                child: Text(completo
                    ? '🚚 Empezar a repartir'
                    : 'Marca todos los pedidos para empezar'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _filaValidacion(Map<String, dynamic> p, int n) {
    final marcado = _validados.contains(p['id']);
    return InkWell(
      onTap: () => setState(() =>
          marcado ? _validados.remove(p['id']) : _validados.add(p['id'])),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: marcado ? _verde : Colors.black.withValues(alpha: .06),
              width: marcado ? 1.6 : 1),
        ),
        child: Row(
          children: [
            Text('$n',
                style: const TextStyle(
                    color: naranjaZas,
                    fontWeight: FontWeight.w800,
                    fontSize: 15)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p['cliente_nombre'],
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  Text(
                      '${p['direccion']}${p['comuna'] != null ? ', ${p['comuna']}' : ''}',
                      style:
                          const TextStyle(fontSize: 12.5, color: _gris)),
                ],
              ),
            ),
            Icon(marcado ? Icons.check_circle : Icons.circle_outlined,
                color: marcado ? _verde : Colors.grey.shade300),
          ],
        ),
      ),
    );
  }

  // --- paso 2: una parada a la vez ---
  Widget _paradaActual(
      List<Map<String, dynamic>> activos, List<Map<String, dynamic>> hechos) {
    final p = activos.first;
    final estado = p['estado'] as String;
    final total = activos.length + hechos.length;
    final nParada = hechos.length + 1;
    final cli = p['cliente_id'] != null ? _clientes[p['cliente_id']] : null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        // progreso
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: hechos.length / total,
                  minHeight: 6,
                  backgroundColor: Colors.black.withValues(alpha: .06),
                  color: _verde,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text('${hechos.length}/$total',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: _gris)),
          ],
        ),
        const SizedBox(height: 20),
        // tarjeta principal (estilo Aire)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.black.withValues(alpha: .05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  estado == 'en_camino'
                      ? '●  EN CAMINO'
                      : '●  PARADA ACTUAL',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .6,
                      color: estado == 'en_camino' ? naranjaZas : _gris)),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('$nParada',
                      style: const TextStyle(
                          color: naranjaZas,
                          fontWeight: FontWeight.w800,
                          fontSize: 30)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(p['cliente_nombre'],
                        style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 19,
                            color: _tinta)),
                  ),
                  Text(p['codigo'] ?? '',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFC2BEB4))),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                  '${p['direccion']}${p['comuna'] != null ? ', ${p['comuna']}' : ''}',
                  style: const TextStyle(fontSize: 15, color: _tinta)),
              if (p['referencia'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('Ref: ${p['referencia']}',
                      style:
                          const TextStyle(fontSize: 13, color: _gris)),
                ),
              if (cli != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                      'Retiro: ${cli['nombre']}${cli['direccion_retiro'] != null ? ' · ${cli['direccion_retiro']}' : ''}',
                      style:
                          const TextStyle(fontSize: 12.5, color: _gris)),
                ),
              Container(
                  height: 1,
                  color: const Color(0xFFF0EFE9),
                  margin: const EdgeInsets.symmetric(vertical: 16)),
              Row(
                children: [
                  _accion('🗺️', 'Mapa', () => _abrirMapa(p)),
                  const SizedBox(width: 20),
                  if (p['cliente_telefono'] != null)
                    _accion('📞', 'Llamar',
                        () => launchUrl(Uri.parse('tel:${p['cliente_telefono']}'))),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: switch (estado) {
                  'asignado' => FilledButton(
                      onPressed: () => _cambiar(p, 'en_camino'),
                      child: const Text('Voy en camino →')),
                  'aceptado' => FilledButton(
                      onPressed: () => _cambiar(p, 'en_camino'),
                      child: const Text('Voy en camino →')),
                  _ => FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: _verde),
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  EntregaPruebaScreen(pedido: p)),
                        );
                        _recargar();
                      },
                      child: const Text('Llegué — registrar entrega ✓')),
                },
              ),
              if (estado == 'en_camino')
                Center(
                  child: TextButton(
                    onPressed: () => _noEntregado(p),
                    child: const Text('No pude entregar',
                        style: TextStyle(color: Color(0xFFB3261E))),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
              'Quedan ${activos.length} paradas · la siguiente aparece al finalizar esta',
              style: const TextStyle(fontSize: 12, color: _gris)),
        ),
      ],
    );
  }

  // --- paso 3: ruta completada ---
  Widget _rutaCompletada(List<Map<String, dynamic>> hechos) {
    final entregados =
        hechos.where((p) => p['estado'] == 'entregado').length;
    final fallidos = hechos.length - entregados;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('🎉', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 12),
            const Text('¡Ruta completada!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
                '$entregados entregados${fallidos > 0 ? ' · $fallidos no entregados' : ''}',
                style: const TextStyle(color: _gris)),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _terminarJornada,
                child: const Text('Terminar jornada'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accion(String emoji, String texto, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 6),
          Text(texto,
              style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Color(0xFF6B6961))),
        ]),
      ),
    );
  }
}
