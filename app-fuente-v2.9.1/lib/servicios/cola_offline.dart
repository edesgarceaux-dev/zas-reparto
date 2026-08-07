import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';

/// Cola de trabajos pendientes para cuando no hay señal.
/// Cada cierre de entrega / no-entrega / cambio de estado se guarda en el
/// teléfono y se reintenta automáticamente hasta lograr subirse.
///
/// v2.9.2 — dos arreglos de fondo:
///  1. NO se congela: antes, cualquier error (incluso uno permanente como una
///     sesión vencida) frenaba TODA la cola. Ahora se separa "sin señal"
///     (reintentar entero) de un error permanente (se saltea ese trabajo para
///     que los demás suban; tras varios intentos se aparca sin perderlo).
///  2. NO duplica: cada trabajo lleva un `uid`. La foto se sube con nombre
///     estable (re-subir sobrescribe) y la fila de entregas_prueba se inserta
///     con ese uid + índice único (upsert que ignora duplicados), así reintentar
///     un trabajo a medio subir no crea entregas ni fotos repetidas.
///     Requiere la columna entregas_prueba.cola_uid (migracion-cola-idempotente.sql).
class ColaOffline {
  static const _clave = 'cola_offline_v1';
  static const _claveFallidos = 'cola_offline_fallidos_v1';
  static const _maxIntentos = 8;
  static bool _procesando = false;

  static String _nuevoUid() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

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
    trabajo['uid'] ??= _nuevoUid();     // identidad estable del trabajo
    trabajo['intentos'] ??= 0;
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

  /// ¿El error es de red (no hay señal) o permanente (RLS, datos, sesión)?
  /// Los de red frenan el ciclo y se reintenta entero; los permanentes se
  /// saltean para no bloquear al resto de la cola.
  static bool _esErrorDeRed(Object e) {
    if (e is SocketException || e is TimeoutException || e is HttpException) {
      return true;
    }
    final s = e.toString();
    return s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Connection closed') ||
        s.contains('Connection refused') ||
        s.contains('Connection reset') ||
        s.contains('timed out') ||
        s.contains('Network is unreachable');
  }

  static Future<void> _aparcarFallido(Map<String, dynamic> t) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_claveFallidos);
    final lista = raw == null ? <dynamic>[] : (jsonDecode(raw) as List);
    lista.add(t);
    await prefs.setString(_claveFallidos, jsonEncode(lista));
  }

  /// Intenta subir todo lo pendiente. Devuelve cuántos trabajos subió.
  /// Un trabajo con error permanente NO frena a los que vienen atrás.
  static Future<int> procesar() async {
    if (_procesando) return 0;
    _procesando = true;
    var subidos = 0;
    try {
      final pendientes = await _leer();
      final quedan = <Map<String, dynamic>>[];
      var sinSenal = false;
      for (final t in pendientes) {
        if (sinSenal) { quedan.add(t); continue; }   // ya no hay red: guardar el resto
        try {
          await _ejecutar(t);
          subidos++;                                  // subió: no se re-agrega
        } catch (e) {
          if (_esErrorDeRed(e)) {
            sinSenal = true;
            quedan.add(t);                            // se reintenta entero luego
          } else {
            final intentos = ((t['intentos'] as int?) ?? 0) + 1;
            t['intentos'] = intentos;
            if (intentos < _maxIntentos) {
              quedan.add(t);                          // error puntual: reintentar
            } else {
              await _aparcarFallido(t);               // demasiados: aparcar, no perder
            }
          }
        }
      }
      await _guardar(quedan);
    } finally {
      _procesando = false;
    }
    return subidos;
  }

  static Future<String?> _subirFoto(
      dynamic pedidoId, String slot, String? ruta, String uid) async {
    if (ruta == null || !File(ruta).existsSync()) return null;
    // nombre ESTABLE (uid del trabajo): re-subir sobrescribe, no duplica
    final destino = '$pedidoId/${slot}_$uid.jpg';
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
    final uid = (t['uid'] as String?) ?? '${id}_${t['tipo']}';
    switch (t['tipo']) {
      case 'estado':
        await supa
            .from('pedidos')
            .update({'estado': t['estado']}).eq('id', id);
      case 'no_entrega':
        final fotoUrl = await _subirFoto(id, 'no_entrega', t['foto'] as String?, uid);
        if (fotoUrl != null) {
          await supa.from('entregas_prueba').upsert({
            'cola_uid': uid,
            'pedido_id': id,
            'foto_domicilio': fotoUrl,
            'comentario': 'No entregado: ${t['motivo']}',
          }, onConflict: 'cola_uid', ignoreDuplicates: true);
        }
        await _marcarNoEntregado(
            id, t['motivo'] as String, (t['nota'] as String?) ?? '');
        _borrarArchivo(t['foto'] as String?);
      case 'entrega':
        final fotos = Map<String, dynamic>.from(t['fotos'] as Map);
        final urls = <String, String?>{};
        for (final slot in fotos.keys) {
          urls[slot] = await _subirFoto(id, slot, fotos[slot] as String?, uid);
        }
        await supa.from('entregas_prueba').upsert({
          'cola_uid': uid,
          'pedido_id': id,
          'nombre_recibe': t['nombre'],
          'rut_recibe': t['rut'],
          'foto_domicilio': urls['domicilio'],
          'foto_pedido': urls['pedido'],
          'foto_receptor': urls['receptor'],
        }, onConflict: 'cola_uid', ignoreDuplicates: true);
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
