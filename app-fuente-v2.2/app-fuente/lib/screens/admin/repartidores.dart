import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config.dart';
import '../../main.dart';

class RepartidoresScreen extends StatefulWidget {
  const RepartidoresScreen({super.key});

  @override
  State<RepartidoresScreen> createState() => _RepartidoresScreenState();
}

class _RepartidoresScreenState extends State<RepartidoresScreen> {
  List<Map<String, dynamic>> _lista = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final rows = await supa
        .from('perfiles')
        .select()
        .eq('rol', 'repartidor')
        .order('nombre');
    if (mounted) {
      setState(() {
        _lista = List<Map<String, dynamic>>.from(rows);
        _cargando = false;
      });
    }
  }

  /// Crea la cuenta del repartidor usando un cliente Supabase secundario,
  /// para no cerrar la sesión del administrador.
  Future<void> _crearRepartidor() async {
    final nombre = TextEditingController();
    final email = TextEditingController();
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nuevo repartidor'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nombre,
                decoration: const InputDecoration(labelText: 'Nombre')),
            TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Correo')),
            TextField(
                controller: pass,
                decoration: const InputDecoration(
                    labelText: 'Contraseña (mín. 6)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Crear')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final aux = SupabaseClient(Config.supabaseUrl, Config.supabaseAnonKey);
      await aux.auth.signUp(
        email: email.text.trim(),
        password: pass.text,
        data: {'nombre': nombre.text.trim()},
      );
      aux.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Repartidor ${nombre.text} creado')));
      }
      await Future.delayed(const Duration(seconds: 1));
      _cargar();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView(
          children: [
            if (_lista.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                    child:
                        Text('Aún no hay repartidores. Crea el primero.')),
              ),
            for (final r in _lista)
              ListTile(
                leading: CircleAvatar(
                  child: Text(r['nombre']
                      .toString()
                      .substring(0, 1)
                      .toUpperCase()),
                ),
                title: Text(r['nombre']),
                subtitle:
                    Text(r['activo'] == true ? 'Activo' : 'Desactivado'),
                trailing: Switch(
                  value: r['activo'] == true,
                  onChanged: (v) async {
                    await supa
                        .from('perfiles')
                        .update({'activo': v}).eq('id', r['id']);
                    _cargar();
                  },
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'nuevo_rep',
        icon: const Icon(Icons.person_add),
        label: const Text('Nuevo repartidor'),
        onPressed: _crearRepartidor,
      ),
    );
  }
}
