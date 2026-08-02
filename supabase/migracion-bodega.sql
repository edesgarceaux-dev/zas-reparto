-- ============================================================
-- APLICACION ZAS - Migración: ubicación exacta de la bodega del cliente
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================
alter table public.clientes add column lat double precision;
alter table public.clientes add column lng double precision;
