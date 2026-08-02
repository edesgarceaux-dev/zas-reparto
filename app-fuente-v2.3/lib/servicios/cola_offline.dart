import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';

/// Cola de trabajos pendientes para cuando no hay señal.
/// Cada cierre de entrega / no-entrega / cambio de estado se guarda en el
/// teléfono y se reintenta automáticamente hasta lograr subirse.
class ColaOffline {
  static const _clave = 'cola_offline_v1';
  static bool _procesando = false;

  static Future<List<Map<String, dynamic>>> _leer() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_clave);
    if (raw == null) return [];
    try {
      return List<Map<String, dynamic>>.from(
          (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e)));
    } catch (_) {
      return [];
    }
  }

  static Future<void> _guardar(List<Map<String, dynamic>> lista) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clave, jsonEncode(lista));
  }

  static Future<int> pendientes() async => (await _leer()).length;

  static Future<void> agregar(Map<String, dynamic> trabajo) async {
    final lista = await _leer();
    lista.add(trabajo);
    await _guardar(lista);
  }

  /// Cierres (entrega o no-entrega) esperando subirse: pedido_id -> tipo.
  /// La app los trata como terminados aunque aún no estén en la base.
  static Future<Map<int, String>> cierresPendientes() async {
    final lista = await _leer();
    return {
      for (final t in lista
          .where((t) => t['tipo'] == 'entrega' || t['tipo'] == 'no_entrega'))
        t['pedido_id'] as int: t['tipo'] as String
    };
  }

  /// Cambios de estado aún no subidos (pedido_id -> estado).
  static Future<Map<int, String>> estadosPendientes() async {
    final lista = await _leer();
    return {
      for (final t in lista.where((t) => t['tipo'] == 'estado'))
        t['pedido_id'] as int: t['estado'] as String
    };
  }

  /// Copia una foto a la carpeta permanente de la app (la carpeta temporal
  /// de la cámara puede borrarse antes de que vuelva la señal).
  static Future<String> copiarPermanente(String origen, String nombre) async {
    final dir = await getApplicationDocumentsDirectory();
    final destino = File(
        '${dir.path}/offline_${DateTime.now().millisecondsSinceEpoch}_$nombre.jpg');
    await File(origen).copy(destino.path);
    return destino.path;
  }

  /// Intenta subir todo lo pendiente en orden. Devuelve cuántos trabajos subió.
  static Future<int> procesar() async {
    if (_procesando) return 0;
    _procesando = true;
    var subidos = 0;
    try {
      var lista = await _leer();
      while (lista.isNotEmpty) {
        final t = lista.first;
        try {
          await _ejecutar(t);
          subidos++;
          lista.removeAt(0);
          await _guardar(lista);
        } catch (_) {
          break; // sigue sin señal: se reintenta en el próximo ciclo
        }
      }
    } finally {
      _procesando = false;
    }
    return subidos;
  }

  static Future<String?> _subirFoto(dynamic pedidoId, String slot, String? ruta) async {
    if (ruta == null || !File(ruta).existsSync()) return null;
    final destino =
        '$pedidoId/${slot}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await supa.storage.from('entregas').uploadBinary(
        destino, await File(ruta).readAsBytes(),
        fileOptions:
            const FileOptions(contentType: 'image/jpeg', upsert: true));
    return supa.storage.from('entregas').getPublicUrl(destino);
  }

  static void _borrarArchivo(String? ruta) {
    if (ruta == null) return;
    try {
      final f = File(ruta);
      if (f.existsSync() && ruta.contains('offline_')) f.deleteSync();
    } catch (_) {}
  }

  /// Marca no entregado tolerando que la columna motivo_no_entrega aún no exista.
  static Future<void> _marcarNoEntregado(
      dynamic id, String motivo, String nota) async {
    try {
      await supa.from('pedidos').update({
        'estado': 'no_entregado',
        'motivo_no_entrega': motivo,
        if (nota.isNotEmpty) 'nota_entrega': nota,
      }).eq('id', id);
    } on PostgrestException catch (e) {
      if (e.message.contains('motivo_no_entrega')) {
        await supa.from('pedidos').update({
          'estado': 'no_entregado',
          'nota_entrega': nota.isEmpty ? motivo : '$motivo — $nota',
        }).eq('id', id);
      } else {
        rethrow;
      }
    }
  }

  static Future<void> _ejecutar(Map<String, dynamic> t) async {
    final id = t['pedido_id'];
    switch (t['tipo']) {
      case 'estado':
        await supa
            .from('pedidos')
            .update({'estado': t['estado']}).eq('id', id);
      case 'no_entrega':
        final fotoUrl = await _subirFoto(id, 'no_entrega', t['foto'] as String?);
        if (fotoUrl != null) {
          await supa.from('entregas_prueba').insert({
            'pedido_id': id,
            'foto_domicilio': fotoUrl,
            'comentario': 'No entregado: ${t['motivo']}',
          });
        }
        await _marcarNoEntregado(
            id, t['motivo'] as String, (t['nota'] as String?) ?? '');
        _borrarArchivo(t['foto'] as String?);
      case 'entrega':
        final fotos = Map<String, dynamic>.from(t['fotos'] as Map);
        final urls = <String, String?>{};
        for (final slot in fotos.keys) {
          urls[slot] = await _subirFoto(id, slot, fotos[slot] as String?);
        }
        await supa.from('entregas_prueba').insert({
          'pedido_id': id,
          'nombre_recibe': t['nombre'],
          'rut_recibe': t['rut'],
          'foto_domicilio': urls['domicilio'],
          'foto_pedido': urls['pedido'],
          'foto_receptor': urls['receptor'],
        });
        await supa.from('pedidos').update({
          'estado': 'entregado',
          'nota_entrega': 'Recibió: ${t['nombre']} (${t['rut']})',
        }).eq('id', id);
        for (final ruta in fotos.values) {
          _borrarArchivo(ruta as String?);
        }
    }
  }
}
