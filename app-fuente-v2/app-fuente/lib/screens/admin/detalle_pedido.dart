import 'package:flutter/material.dart';
import '../../main.dart';
import '../../modelos.dart';

class DetallePedidoScreen extends StatefulWidget {
  final Map<String, dynamic> pedido;
  const DetallePedidoScreen({super.key, required this.pedido});

  @override
  State<DetallePedidoScreen> createState() => _DetallePedidoScreenState();
}

class _DetallePedidoScreenState extends State<DetallePedidoScreen> {
  late Map<String, dynamic> p;
  List<Map<String, dynamic>> _repartidores = [];
  List<Map<String, dynamic>> _historial = [];
  Map<String, String> _nombres = {};
  Map<int, String> _clientes = {};

  @override
  void initState() {
    super.initState();
    p = Map.of(widget.pedido);
    _cargar();
  }

  Future<void> _cargar() async {
    final reps = await supa
        .from('perfiles')
        .select('id, nombre')
        .order('nombre');
    final hist = await supa
        .from('pedido_historial')
        .select()
        .eq('pedido_id', p['id'])
        .order('creado_en');
    final fresh =
        await supa.from('pedidos').select().eq('id', p['id']).single();
    final clis = await supa.from('clientes').select('id, nombre');
    if (!mounted) return;
    setState(() {
      _repartidores = List<Map<String, dynamic>>.from(
          reps.where((r) => true));
      _nombres = {
        for (final r in reps) r['id'] as String: r['nombre'] as String
      };
      _historial = List<Map<String, dynamic>>.from(hist);
      _clientes = {
        for (final c in clis) c['id'] as int: c['nombre'] as String
      };
      p = fresh;
    });
  }

  Future<void> _actualizar(Map<String, dynamic> cambios) async {
    try {
      await supa.from('pedidos').update(cambios).eq('id', p['id']);
      await _cargar();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _reasignar() async {
    final activos = _repartidores;
    final elegido = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Asignar a:',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final r in activos)
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(r['nombre']),
              onTap: () => Navigator.pop(context, r['id'] as String),
            ),
        ],
      ),
    );
    if (elegido != null) {
      await _actualizar({'repartidor_id': elegido, 'estado': 'asignado'});
    }
  }

  String _hora(String? ts) {
    if (ts == null) return '';
    final d = DateTime.tryParse(ts)?.toLocal();
    if (d == null) return '';
    return '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final estado = p['estado'] as String;
    final rep =
        p['repartidor_id'] != null ? _nombres[p['repartidor_id']] : null;
    return Scaffold(
      appBar: AppBar(title: Text(p['codigo'] ?? 'Pedido #${p['id']}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(EstadoPedido.icono(estado),
                          color: EstadoPedido.color(estado)),
                      const SizedBox(width: 8),
                      Text(EstadoPedido.etiqueta(estado),
                          style: TextStyle(
                              color: EstadoPedido.color(estado),
                              fontWeight: FontWeight.bold,
                              fontSize: 18)),
                    ],
                  ),
                  const Divider(height: 24),
                  _fila(
                      'Empresa',
                      p['cliente_id'] != null
                          ? '${_clientes[p['cliente_id']] ?? ''}${p['origen'] == 'jumpseller' ? ' (auto Jumpseller)' : ''}'
                          : null),
                  _fila('Cliente', p['cliente_nombre']),
                  _fila('Teléfono', p['cliente_telefono']),
                  _fila('Dirección', p['direccion']),
                  _fila('Comuna', p['comuna']),
                  _fila('Referencia', p['referencia']),
                  _fila('Detalle', p['detalle']),
                  _fila('Monto', formatoMonto(p['monto'])),
                  _fila('Pago', p['metodo_pago']),
                  _fila('Repartidor', rep ?? 'Sin asignar'),
                  _fila('Nota entrega', p['nota_entrega']),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.person_add),
                label: Text(rep == null ? 'Asignar' : 'Reasignar'),
                onPressed: _reasignar,
              ),
              if (estado != 'cancelado' && estado != 'entregado')
                OutlinedButton.icon(
                  icon: const Icon(Icons.block),
                  label: const Text('Cancelar pedido'),
                  onPressed: () => _actualizar({'estado': 'cancelado'}),
                ),
              if (estado == 'no_entregado')
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar (pendiente)'),
                  onPressed: () => _actualizar(
                      {'estado': 'pendiente', 'repartidor_id': null}),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Historial', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final h in _historial)
            ListTile(
              dense: true,
              leading: Icon(EstadoPedido.icono(h['estado']),
                  color: EstadoPedido.color(h['estado']), size: 20),
              title: Text(EstadoPedido.etiqueta(h['estado'])),
              subtitle: h['usuario_id'] != null
                  ? Text(_nombres[h['usuario_id']] ?? '')
                  : null,
              trailing: Text(_hora(h['creado_en'])),
            ),
        ],
      ),
    );
  }

  Widget _fila(String k, dynamic v) {
    if (v == null || v.toString().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 100,
              child: Text(k,
                  style: TextStyle(color: Colors.grey.shade600))),
          Expanded(child: Text(v.toString())),
        ],
      ),
    );
  }
}
