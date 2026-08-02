-- ============================================================
-- APLICACION ZAS - Migración: hora de corte por cliente
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================
-- Pedidos pagados DESPUÉS de esta hora quedan programados para el
-- día siguiente (fecha_pedido = mañana). Vacío = sin corte.
alter table public.clientes add column hora_corte time;

-- Distribuidora Pepito: corte a las 12:00
update public.clientes set hora_corte = '12:00' where id = 1;
