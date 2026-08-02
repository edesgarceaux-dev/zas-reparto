-- ============================================================
-- APLICACION ZAS - Migración: rutas y coordenadas
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================

-- Coordenadas del punto de entrega (se llenan automáticamente)
alter table public.pedidos add column lat double precision;
alter table public.pedidos add column lng double precision;

-- Orden de visita dentro de la ruta del repartidor (1, 2, 3, ...)
alter table public.pedidos add column ruta_orden int;
