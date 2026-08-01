import 'package:flutter/material.dart';
import '../../main.dart';

class CrearPedidoScreen extends StatefulWidget {
  const CrearPedidoScreen({super.key});

  @override
  State<CrearPedidoScreen> createState() => _CrearPedidoScreenState();
}

class _CrearPedidoScreenState extends State<CrearPedidoScreen> {
  final _form = GlobalKey<FormState>();
  final _cliente = TextEditingController();
  final _telefono = TextEditingController();
  final _direccion = TextEditingController();
  final _comuna = TextEditingController();
  final _referencia = TextEditingController();
  final _detalle = TextEditingController();
  final _monto = TextEditingController();
  String _metodoPago = 'pagado';
  String? _repartidorId;
  List<Map<String, dynamic>> _repartidores = [];
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _cargarRepartidores();
  }

  Future<void> _cargarRepartidores() async {
    final rows = await supa
        .from('perfiles')
        .select('id, nombre')
        .eq('rol', 'repartidor')
        .eq('activo', true)
        .order('nombre');
    if (mounted) {
      setState(() => _repartidores = List<Map<String, dynamic>>.from(rows));
    }
  }

  Future<void> _guardar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _guardando = true);
    try {
      await supa.from('pedidos').insert({
        'cliente_nombre': _cliente.text.trim(),
        'cliente_telefono':
            _telefono.text.trim().isEmpty ? null : _telefono.text.trim(),
        'direccion': _direccion.text.trim(),
        'comuna': _comuna.text.trim().isEmpty ? null : _comuna.text.trim(),
        'referencia':
            _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
        'detalle': _detalle.text.trim().isEmpty ? null : _detalle.text.trim(),
        'monto': _monto.text.trim().isEmpty
            ? null
            : num.tryParse(_monto.text.replaceAll('.', '').trim()),
        'metodo_pago': _metodoPago,
        'repartidor_id': _repartidorId,
        'estado': _repartidorId == null ? 'pendiente' : 'asignado',
        'creado_por': supa.auth.currentUser!.id,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Pedido creado')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nuevo pedido')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _cliente,
              decoration: const InputDecoration(
                  labelText: 'Nombre del cliente *',
                  border: OutlineInputBorder()),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Obligatorio' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _telefono,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Teléfono', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _direccion,
              decoration: const InputDecoration(
                  labelText: 'Dirección *', border: OutlineInputBorder()),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Obligatorio' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _comuna,
                    decoration: const InputDecoration(
                        labelText: 'Comuna', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _monto,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Monto \$',
                        border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _referencia,
              decoration: const InputDecoration(
                  labelText: 'Referencia (depto, indicaciones...)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _detalle,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Detalle del pedido',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _metodoPago,
              decoration: const InputDecoration(
                  labelText: 'Pago', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'pagado', child: Text('Ya pagado')),
                DropdownMenuItem(
                    value: 'efectivo', child: Text('Efectivo al entregar')),
                DropdownMenuItem(
                    value: 'transferencia', child: Text('Transferencia')),
                DropdownMenuItem(value: 'tarjeta', child: Text('Tarjeta')),
              ],
              onChanged: (v) => setState(() => _metodoPago = v!),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              value: _repartidorId,
              decoration: const InputDecoration(
                  labelText: 'Asignar a repartidor',
                  border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('Sin asignar (después)')),
                for (final r in _repartidores)
                  DropdownMenuItem(
                      value: r['id'] as String, child: Text(r['nombre'])),
              ],
              onChanged: (v) => setState(() => _repartidorId = v),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _guardando ? null : _guardar,
                child: _guardando
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Guardar pedido'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
