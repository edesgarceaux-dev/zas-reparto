import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../main.dart';
import '../../servicios/cola_offline.dart';
import '../asignar/asignar_qr.dart';
import 'entrega_prueba.dart';
import 'escaner_carga.dart';

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
  // --- modo sin señal ---
  Map<int, String> _cerradosLocal = {}; // cierres guardados en el teléfono (id -> tipo)
  Map<int, String> _estadoLocal = {};   // cambios de estado aún no subidos
  int _pendientesOffline = 0;
  Timer? _colaTimer;
  DateTime? _rutaInicio;

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
        final inicio = prefs.getString('ruta_inicio');
        _rutaInicio = inicio != null ? DateTime.tryParse(inicio) : null;
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
  ///
  /// Son DOS cosas:
  ///  1. los pedidos que ya son de mi empresa y me tocan a mí;
  ///  2. los pedidos COMPARTIDOS que mi oficina me planificó y todavía no
  ///     cargué — no son de nadie hasta que alguien los escanea, así que
  ///     los traigo de plan_reparto.
  /// Los planificados se marcan con `_previsto` para pintarlos distinto.
  Future<void> _recargar() async {
    final uid = supa.auth.currentUser?.id;
    if (uid == null) return; // sesión cerrada: no hay a quién cargarle
    try {
      final mios = await supa
          .from('pedidos')
          .select()
          .eq('repartidor_id', uid)
          .order('creado_en', ascending: false)
          .limit(100);
      final lista = List<Map<String, dynamic>>.from(mios);

      // lo que me planificaron pero todavía no es de la empresa
      try {
        final planes = await supa
            .from('plan_reparto')
            .select('pedido_id, orden, pedidos(*)')
            .eq('repartidor_id', uid)
            .limit(100);
        for (final fila in List<Map<String, dynamic>>.from(planes)) {
          final p = fila['pedidos'];
          if (p is Map && p['empresa_reparto_id'] == null) {
            final m = Map<String, dynamic>.from(p);
            m['_previsto'] = true;   // hay que escanearlo para que sea nuestro
            // El orden de la ruta de un pedido compartido vive en el plan, no
            // en el pedido: todavía no es de la empresa. Sin esto la ruta
            // planificada le llegaba desordenada al repartidor.
            if (fila['orden'] != null) m['ruta_orden'] = fila['orden'];
            if (!lista.any((x) => x['id'] == m['id'])) lista.add(m);
          }
        }
      } catch (_) {/* base sin plan_reparto todavía: se ignora */}

      if (mounted) {
        setState(() {
          _pedidos = lista;
          _cargado = true;
        });
      }
    } catch (_) {/* sin red: se reintenta en el próximo ciclo */}
  }

  /// Avisos de pedidos que otra empresa cargó primero.
  Future<void> _revisarAvisos() async {
    final uid = supa.auth.currentUser?.id;
    if (uid == null) return; // sesión cerrada
    try {
      final rows = await supa
          .from('avisos_red')
          .select()
          .eq('repartidor_id', uid)
          .eq('visto', false)
          .limit(20);
      final avisos = List<Map<String, dynamic>>.from(rows);
      if (avisos.isEmpty || !mounted) return;
      final textos = avisos.map((a) => (a['texto'] ?? '').toString()).join('\n\n');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(avisos.length == 1
              ? 'Un pedido salió de tu ruta'
              : '${avisos.length} pedidos salieron de tu ruta'),
          content: Text(textos),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Entendido')),
          ],
        ),
      );
      await supa.from('avisos_red').update({'visto': true}).inFilter(
          'id', avisos.map((a) => a['id']).toList());
    } catch (_) {/* sin avisos o base vieja: no molesta */}
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
    // 3) cola offline: intenta subir lo pendiente cada 30 s
    _procesarCola();
    _colaTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _procesarCola());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    // al volver a la app, refrescar y subir lo pendiente de inmediato
    if (estado == AppLifecycleState.resumed) {
      _recargar();
      _procesarCola();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sincronizador?.cancel();
    _colaTimer?.cancel();
    if (_canal != null) supa.removeChannel(_canal!);
    _gps?.cancel();
    super.dispose();
  }

  // ---------- cola offline ----------
  Future<void> _procesarCola() async {
    final subidos = await ColaOffline.procesar();
    final cerrados = await ColaOffline.cierresPendientes();
    final estados = await ColaOffline.estadosPendientes();
    final n = await ColaOffline.pendientes();
    if (mounted) {
      setState(() {
        _cerradosLocal = cerrados;
        _estadoLocal = estados;
        _pendientesOffline = n;
      });
    }
    if (subidos > 0) {
      await _recargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '✅ Volvió la señal: $subidos registro(s) guardados se subieron solos')));
      }
    }
  }

  Widget _avisoOffline() {
    if (_pendientesOffline == 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6DE),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0DFA8)),
      ),
      child: Row(
        children: [
          const Text('📴', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                '$_pendientesOffline registro(s) guardados sin señal — se subirán solos al volver la conexión',
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xFF7A6410))),
          ),
        ],
      ),
    );
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
      final uid = supa.auth.currentUser?.id;
      if (uid == null) {           // sesión cerrada: cortar el GPS, no escribir
        _gps?.cancel();
        _gps = null;
        return;
      }
      supa.from('ubicaciones').upsert({
        'repartidor_id': uid,
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
    final inicio = DateTime.now();
    await prefs.setString('ruta_inicio', inicio.toIso8601String());
    _iniciarGps();
    if (mounted) {
      setState(() {
        _repartiendo = true;
        _rutaInicio = inicio;
      });
    }
  }

  Future<void> _terminarJornada() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('repartiendo', false);
    await prefs.remove('ruta_inicio');
    _gps?.cancel();
    _validados.clear();
    if (mounted) {
      setState(() {
        _repartiendo = false;
        _rutaInicio = null;
      });
    }
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
    } catch (_) {
      // sin señal: se guarda en el teléfono y se sube solo después
      await ColaOffline.agregar(
          {'tipo': 'estado', 'pedido_id': p['id'], 'estado': nuevo});
      if (mounted) {
        setState(() {
          _estadoLocal[p['id'] as int] = nuevo;
          _pendientesOffline++;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                '📴 Sin señal: el cambio quedó guardado y se subirá solo')));
      }
    }
  }

  static const _motivosNoEntrega = [
    'No había nadie',
    'Dirección incorrecta',
    'Rechazado por el cliente',
    'No se alcanzó en la jornada',
    'Otro',
  ];

  Future<void> _noEntregado(Map<String, dynamic> p) async {
    String? motivo;
    XFile? foto;
    final nota = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('No pude entregar',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                const Text('¿Qué pasó? *',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _motivosNoEntrega
                      .map((m) => ChoiceChip(
                            label: Text(m,
                                style: const TextStyle(fontSize: 13)),
                            selected: motivo == m,
                            selectedColor: const Color(0xFFFFE3D1),
                            onSelected: (_) => setS(() => motivo = m),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: nota,
                  decoration: const InputDecoration(
                      labelText: 'Detalle adicional (opcional)'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: Icon(
                      foto == null
                          ? Icons.photo_camera_outlined
                          : Icons.check_circle,
                      color: foto == null
                          ? null
                          : const Color(0xFF0CA30C)),
                  label: Text(foto == null
                      ? 'Foto del domicilio (respaldo recomendado)'
                      : 'Foto lista ✓ — toca para repetir'),
                  onPressed: () async {
                    final f = await ImagePicker().pickImage(
                        source: ImageSource.camera,
                        imageQuality: 55,
                        maxWidth: 1280);
                    if (f != null) setS(() => foto = f);
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFB3261E)),
                    onPressed: motivo == null
                        ? null
                        : () => Navigator.pop(ctx, true),
                    child: const Text('Confirmar no entregado'),
                  ),
                ),
                Center(
                  child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Volver')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || motivo == null) return;
    // la foto se guarda en carpeta permanente por si hay que subirla después
    String? rutaFoto;
    if (foto != null) {
      try {
        rutaFoto =
            await ColaOffline.copiarPermanente(foto!.path, 'domicilio');
      } catch (_) {
        rutaFoto = foto!.path;
      }
    }
    await ColaOffline.agregar({
      'tipo': 'no_entrega',
      'pedido_id': p['id'],
      'motivo': motivo,
      'nota': nota.text.trim(),
      'foto': rutaFoto,
    });
    if (mounted) {
      setState(() => _cerradosLocal[p['id'] as int] = 'no_entrega');
    }
    await _procesarCola(); // si hay señal se sube al instante
    if (_pendientesOffline == 0) {
      await _recargar();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              '📴 Sin señal: quedó registrado y se subirá solo al volver la conexión')));
    }
  }

  Future<void> _abrirMapa(Map<String, dynamic> p) async {
    final dir = Uri.encodeComponent(
        '${p['direccion']}${p['comuna'] != null ? ', ${p['comuna']}' : ''}');
    await launchUrl(
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$dir'),
        mode: LaunchMode.externalApplication);
  }

  Future<void> _abrirWhatsApp(Map<String, dynamic> p) async {
    var num = (p['cliente_telefono'] ?? '')
        .toString()
        .replaceAll(RegExp(r'[^0-9]'), '');
    if (num.length == 9 && num.startsWith('9')) {
      num = '56$num';
    } else if (num.length == 8) {
      num = '569$num';
    } else if (!num.startsWith('56')) {
      num = '56$num';
    }
    final msg = Uri.encodeComponent(
        'Hola 👋 Soy tu repartidor de ZAS Reparto 🛵. Voy en camino con tu pedido${p['codigo'] != null ? ' ${p['codigo']}' : ''}.');
    await launchUrl(Uri.parse('https://wa.me/$num?text=$msg'),
        mode: LaunchMode.externalApplication);
  }

  // ---------- asignar por QR (solo cuentas habilitadas) ----------
  /// Prendido desde el panel, en la ficha de la persona. Deja usar esta
  /// misma app para repartir bultos entre los repartidores, en bodega.
  bool get _puedeAsignar => widget.perfil['puede_asignar'] == true;

  Future<void> _abrirAsignar() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => const AsignarQrScreen()));
    if (!mounted) return;
    await _recargar();          // puede haberse asignado algo a sí mismo
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
          if (_puedeAsignar)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton.icon(
                onPressed: _abrirAsignar,
                icon: const Icon(Icons.qr_code_scanner, size: 20),
                label: const Text('Asignar',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                style: TextButton.styleFrom(foregroundColor: naranjaZas),
              ),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: _gris),
            onSelected: (v) {
              if (v == 'asignar') _abrirAsignar();
              if (v == 'bio') _cambiarBio(!_bioActiva);
              if (v == 'salir') {
                // cortar GPS y timers ANTES de cerrar sesión: si no, el stream
                // dispara un upsert con currentUser null y la app crashea.
                _gps?.cancel();
                _gps = null;
                _sincronizador?.cancel();
                _colaTimer?.cancel();
                supa.auth.signOut();
              }
            },
            itemBuilder: (_) => [
              if (_puedeAsignar)
                const PopupMenuItem(
                    value: 'asignar', child: Text('Asignar por QR')),
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
          // aplicar cambios guardados sin señal sobre lo que trae la base
          final efectivos = _pedidos.map((p) {
            final local = _estadoLocal[p['id']];
            return local == null ? p : {...p, 'estado': local};
          }).toList();
          final activos = efectivos
              .where((p) =>
                  !['entregado', 'cancelado', 'no_entregado']
                      .contains(p['estado']) &&
                  !_cerradosLocal.containsKey(p['id']))
              .toList()
            ..sort((a, b) {
              final oa = (a['ruta_orden'] as int?) ?? 999;
              final ob = (b['ruta_orden'] as int?) ?? 999;
              if (oa != ob) return oa.compareTo(ob);
              return (a['id'] as int).compareTo(b['id'] as int);
            });
          final hechosHoy = efectivos
              .where((p) =>
                  ['entregado', 'no_entregado'].contains(p['estado']) ||
                  _cerradosLocal.containsKey(p['id']))
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
            if (_puedeAsignar) ...[
              const SizedBox(height: 26),
              FilledButton.icon(
                onPressed: _abrirAsignar,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Asignar bultos por QR'),
              ),
              const SizedBox(height: 8),
              const Text('Elegís un repartidor y vas pasando los bultos',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _gris, fontSize: 12.5)),
            ],
          ],
        ),
      ),
    );
  }

  // --- paso 1: validar la carga (solo escáner, sin lista manual) ---
  Widget _validacion(List<Map<String, dynamic>> activos) {
    final listos = activos.where((p) => _validados.contains(p['id'])).length;
    final completo = activos.isNotEmpty && listos == activos.length;
    return Column(
      children: [
        if (_pendientesOffline > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: _avisoOffline(),
          ),
        Expanded(
          child: ClipRRect(
            child: EscanerCargaScreen(
              pedidos: activos,
              validados: _validados,
              embebido: true,
              onReclamado: () async {
                await _recargar();
                await _revisarAvisos();
              },
              onCambio: (set) {
                if (!mounted) return;
                setState(() {
                  _validados
                    ..clear()
                    ..addAll(set);
                });
              },
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: completo ? _empezarRuta : null,
                child: Text(completo
                    ? '🚚 Empezar a repartir'
                    : 'Escanea los bultos · $listos/${activos.length}'),
              ),
            ),
          ),
        ),
      ],
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
        _avisoOffline(),
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
                    child: Text((p['cliente_nombre'] ?? 'Sin nombre').toString(),
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
                  const SizedBox(width: 18),
                  if (p['cliente_telefono'] != null) ...[
                    _accion('📞', 'Llamar',
                        () => launchUrl(Uri.parse('tel:${p['cliente_telefono']}'))),
                    const SizedBox(width: 18),
                    _accion('💬', 'WhatsApp', () => _abrirWhatsApp(p)),
                  ],
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
                        final res = await Navigator.push<String>(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  EntregaPruebaScreen(pedido: p)),
                        );
                        await _procesarCola();
                        await _recargar();
                        if (res == 'offline' && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      '📴 Sin señal: la entrega quedó guardada en el teléfono y se subirá sola')));
                        }
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

  // --- paso 3: ruta completada + resumen del día ---
  Widget _rutaCompletada(List<Map<String, dynamic>> hechos) {
    final entregados = hechos
        .where((p) =>
            p['estado'] == 'entregado' ||
            _cerradosLocal[p['id']] == 'entrega')
        .length;
    final fallidos = hechos.length - entregados;
    final fin = DateTime.now();
    final dur = _rutaInicio != null ? fin.difference(_rutaInicio!) : null;
    String hora(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    String duracion(Duration d) => d.inHours > 0
        ? '${d.inHours} h ${d.inMinutes % 60} min'
        : '${d.inMinutes} min';

    Widget fila(String emoji, String titulo, String valor) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 17)),
              const SizedBox(width: 10),
              Text(titulo, style: const TextStyle(color: _gris)),
              const Spacer(),
              Text(valor,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ],
          ),
        );

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _avisoOffline(),
            const Text('🎉', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 12),
            const Text('¡Ruta completada!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Colors.black.withValues(alpha: .06)),
              ),
              child: Column(
                children: [
                  const Text('Resumen de tu jornada',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
                  const SizedBox(height: 8),
                  fila('✅', 'Entregados', '$entregados'),
                  if (fallidos > 0)
                    fila('❌', 'No entregados', '$fallidos'),
                  if (_rutaInicio != null)
                    fila('🕒', 'Inicio de ruta', hora(_rutaInicio!)),
                  fila('🏁', 'Término', hora(fin)),
                  if (dur != null) fila('⏱️', 'Duración', duracion(dur)),
                ],
              ),
            ),
            const SizedBox(height: 20),
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
