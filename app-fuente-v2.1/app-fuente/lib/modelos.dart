import 'package:flutter/material.dart';

/// Estados posibles de un pedido y su presentación.
class EstadoPedido {
  static const flujo = [
    'pendiente',
    'asignado',
    'aceptado',
    'en_camino',
    'entregado',
  ];

  static String etiqueta(String estado) => switch (estado) {
        'pendiente' => 'Pendiente',
        'asignado' => 'Asignado',
        'aceptado' => 'Aceptado',
        'en_camino' => 'En camino',
        'entregado' => 'Entregado',
        'no_entregado' => 'No entregado',
        'cancelado' => 'Cancelado',
        _ => estado,
      };

  static Color color(String estado) => switch (estado) {
        'pendiente' => Colors.grey,
        'asignado' => Colors.blueGrey,
        'aceptado' => Colors.blue,
        'en_camino' => Colors.orange,
        'entregado' => Colors.green,
        'no_entregado' => Colors.red,
        'cancelado' => Colors.red.shade900,
        _ => Colors.grey,
      };

  static IconData icono(String estado) => switch (estado) {
        'pendiente' => Icons.schedule,
        'asignado' => Icons.assignment_ind,
        'aceptado' => Icons.thumb_up,
        'en_camino' => Icons.local_shipping,
        'entregado' => Icons.check_circle,
        'no_entregado' => Icons.cancel,
        'cancelado' => Icons.block,
        _ => Icons.help,
      };

  /// Siguiente estado que puede marcar el repartidor.
  static String? siguiente(String estado) => switch (estado) {
        'asignado' => 'aceptado',
        'aceptado' => 'en_camino',
        'en_camino' => 'entregado',
        _ => null,
      };

  static String accion(String siguiente) => switch (siguiente) {
        'aceptado' => 'Aceptar pedido',
        'en_camino' => 'Iniciar reparto',
        'entregado' => 'Marcar entregado',
        _ => siguiente,
      };
}

String formatoMonto(dynamic monto) {
  if (monto == null) return '';
  final n = num.tryParse(monto.toString()) ?? 0;
  final s = n.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.');
  return '\$$s';
}
