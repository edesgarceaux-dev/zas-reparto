import 'dart:async';
import 'package:flutter/material.dart';
import '../../main.dart';
import '../../modelos.dart';
import 'crear_pedido.dart';
import 'repartidores.dart';
import 'detalle_pedido.dart';

class AdminHome extends StatefulWidget {
  final Map<String, dynamic> perfil;
  const AdminHome({super.key, required this.perfil});

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == 0 ? 'Pedidos' : 'Repartidores'),
        actions: [
          IconButton(
            tooltip: 'Salir',
            icon: const Icon(Icons.logout),
            onPressed: () => supa.auth.signOut(),
          ),
        ],
      ),
      body: _tab == 0 ? const _ListaPedidos() : const RepartidoresScreen(),
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Nuevo pedido'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CrearPedidoScreen()),
              ),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.receipt_long), label: 'Pedidos'),
          NavigationDestination(
              icon: Icon(Icons.people), label: 'Repartidores'),
        ],
      ),
    );
  }
}

class _ListaPedidos extends StatefulWidget {
  const _ListaPedidos();

  @override
  State<_ListaPedidos> createState() => _ListaPedidosState();
}

class _ListaPedidosState extends State<_ListaPedidos> {
  String _filtro = 'activos';
  late final Stream<List<Map<String, dynamic>>> _stream;
  Map<String, String> _nombres = {}; // id repartidor -> nombre

  @override
  void initState() {
    super.initState();
    _stream = supa
        .from('pedidos')
        .stream(primaryKey: ['id'])
        .order('creado_en', ascending: false)
        .limit(400);
    _cargarNombres();
  }

  Future<void> _cargarNombres() async {
    final rows = await supa.from('perfiles').select('id, nombre');
    if (!mounted) return;
    setState(() => _nombres = {
          for (final r in rows) r['id'] as String: r['nombre'] as String
        });
  }

  bool _pasaFiltro(Map<String, dynamic> p) {
    final hoy = DateTime.now();
    final fecha = DateTime.tryParse(p['fecha_pedido'] ?? '');
    final esHoy = fecha != null &&
        fecha.year == hoy.year && fecha.month == hoy.month && fecha.day == hoy.day;
    return switch (_filtro) {
      'activos' => !['entregado', 'cancelado', 'no_entregado']
          .contains(p['estado']),
      'sin_asignar' => p['estado'] == 'pendiente',
      'hoy' => esHoy,
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (k, v) in [
                  ('activos', 'Activos'),
                  ('sin_asignar', 'Sin asignar'),
                  ('hoy', 'Hoy'),
                  ('todos', 'Todos'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(v),
                      selected: _filtro == k,
                      onSelected: (_) => setState(() => _filtro = k),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _stream,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final pedidos = snap.data!.where(_pasaFiltro).toList();
              if (pedidos.isEmpty) {
                return const Center(child: Text('No hay pedidos aquí.'));
              }
              return ListView.builder(
                itemCount: pedidos.length,
                itemBuilder: (context, i) {
                  final p = pedidos[i];
                  final estado = p['estado'] as String;
                  final rep = p['repartidor_id'] != null
                      ? _nombres[p['repartidor_id']] ?? '...'
                      : null;
                  return Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            EstadoPedido.color(estado).withValues(alpha: .15),
                        child: Icon(EstadoPedido.icono(estado),
                            color: EstadoPedido.color(estado), size: 22),
                      ),
                      title: Text(
                          '${p['codigo'] ?? '#${p['id']}'} · ${p['cliente_nombre']}'),
                      subtitle: Text([
                        p['direccion'],
                        if (rep != null) 'Rep: $rep',
                      ].join('\n')),
                      isThreeLine: rep != null,
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(EstadoPedido.etiqueta(estado),
                              style: TextStyle(
                                  color: EstadoPedido.color(estado),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                          if (p['monto'] != null)
                            Text(formatoMonto(p['monto']),
                                style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => DetallePedidoScreen(pedido: p)),
                        );
                        _cargarNombres();
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
