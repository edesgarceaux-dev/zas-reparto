import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../main.dart';
import '../../modelos.dart';

class RepartidorHome extends StatefulWidget {
  final Map<String, dynamic> perfil;
  const RepartidorHome({super.key, required this.perfil});

  @override
  State<RepartidorHome> createState() => _RepartidorHomeState();
}

class _RepartidorHomeState extends State<RepartidorHome> {
  late final Stream<List<Map<String, dynamic>>> _stream;
  int _cantidadAnterior = -1;
  Map<int, Map<String, dynamic>> _clientes = {};

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

  @override
  void initState() {
    super.initState();
    _cargarClientes();
    _stream = supa
        .from('pedidos')
        .stream(primaryKey: ['id'])
        .eq('repartidor_id', supa.auth.currentUser!.id)
        .order('creado_en', ascending: false)
        .limit(100);
  }

  Future<void> _cambiarEstado(Map<String, dynamic> p, String nuevo) async {
    String? nota;
    if (nuevo == 'entregado' || nuevo == 'no_entregado') {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(nuevo == 'entregado'
              ? 'Confirmar entrega'
              : 'Marcar como no entregado'),
          content: TextField(
            controller: ctrl,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: nuevo == 'entregado'
                  ? 'Comentario (opcional)'
                  : 'Motivo *',
              border: const OutlineInputBorder(),
            ),
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
      if (ok != true) return;
      nota = ctrl.text.trim().isEmpty ? null : ctrl.text.trim();
      if (nuevo == 'no_entregado' && nota == null) return;
    }
    try {
      await supa.from('pedidos').update({
        'estado': nuevo,
        if (nota != null) 'nota_entrega': nota,
      }).eq('id', p['id']);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _abrirMapa(Map<String, dynamic> p) async {
    final dir = Uri.encodeComponent(
        '${p['direccion']}${p['comuna'] != null ? ', ${p['comuna']}' : ''}');
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$dir');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _llamar(Map<String, dynamic> p) async {
    final tel = p['cliente_telefono'];
    if (tel == null) return;
    await launchUrl(Uri.parse('tel:$tel'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Hola, ${widget.perfil['nombre']}'),
        actions: [
          IconButton(
            tooltip: 'Salir',
            icon: const Icon(Icons.logout),
            onPressed: () => supa.auth.signOut(),
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final activos = snap.data!
              .where((p) => !['entregado', 'cancelado', 'no_entregado']
                  .contains(p['estado']))
              .toList()
            ..sort((a, b) {
              final oa = (a['ruta_orden'] as int?) ?? 999;
              final ob = (b['ruta_orden'] as int?) ?? 999;
              if (oa != ob) return oa.compareTo(ob);
              return (a['id'] as int).compareTo(b['id'] as int);
            });
          final terminadosHoy = snap.data!
              .where((p) =>
                  ['entregado', 'no_entregado'].contains(p['estado']))
              .take(20)
              .toList();

          // Aviso simple cuando llega un pedido nuevo con la app abierta
          if (_cantidadAnterior >= 0 && activos.length > _cantidadAnterior) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('¡Tienes un pedido nuevo!'),
                    backgroundColor: Colors.green));
              }
            });
          }
          _cantidadAnterior = activos.length;

          if (activos.isEmpty && terminadosHoy.isEmpty) {
            return const Center(
                child: Text('No tienes pedidos asignados por ahora.'));
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (activos.isNotEmpty) ...[
                Text('Pedidos activos (${activos.length})',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final p in activos) _tarjeta(p, true),
              ],
              if (terminadosHoy.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Terminados recientes',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final p in terminadosHoy) _tarjeta(p, false),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _tarjeta(Map<String, dynamic> p, bool activo) {
    final estado = p['estado'] as String;
    final siguiente = EstadoPedido.siguiente(estado);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (activo && p['ruta_orden'] != null) ...[
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: const Color(0xFFE85D04),
                        borderRadius: BorderRadius.circular(99)),
                    child: Text('${p['ruta_orden']}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ),
                  const SizedBox(width: 6),
                ],
                Icon(EstadoPedido.icono(estado),
                    color: EstadoPedido.color(estado), size: 20),
                const SizedBox(width: 6),
                Text(EstadoPedido.etiqueta(estado),
                    style: TextStyle(
                        color: EstadoPedido.color(estado),
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(p['codigo'] ?? '#${p['id']}',
                    style: TextStyle(color: Colors.grey.shade600)),
              ],
            ),
            const SizedBox(height: 8),
            if (p['cliente_id'] != null && _clientes[p['cliente_id']] != null)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(6)),
                child: Text(
                  'Retiro: ${_clientes[p['cliente_id']]!['nombre']}'
                  '${_clientes[p['cliente_id']]!['direccion_retiro'] != null ? ' · ${_clientes[p['cliente_id']]!['direccion_retiro']}' : ''}',
                  style: TextStyle(
                      fontSize: 12, color: Colors.orange.shade900),
                ),
              ),
            Text(p['cliente_nombre'],
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
            Text([
              p['direccion'],
              if (p['comuna'] != null) p['comuna'],
            ].join(', ')),
            if (p['referencia'] != null)
              Text('Ref: ${p['referencia']}',
                  style: TextStyle(color: Colors.grey.shade700)),
            if (activo) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Ver en mapa',
                    icon: const Icon(Icons.map),
                    onPressed: () => _abrirMapa(p),
                  ),
                  const SizedBox(width: 8),
                  if (p['cliente_telefono'] != null)
                    IconButton.filledTonal(
                      tooltip: 'Llamar',
                      icon: const Icon(Icons.phone),
                      onPressed: () => _llamar(p),
                    ),
                  const Spacer(),
                  if (siguiente != null)
                    FilledButton(
                      onPressed: () => _cambiarEstado(p, siguiente),
                      child: Text(EstadoPedido.accion(siguiente)),
                    ),
                ],
              ),
              if (estado == 'en_camino')
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _cambiarEstado(p, 'no_entregado'),
                    child: const Text('No pude entregar',
                        style: TextStyle(color: Colors.red)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
