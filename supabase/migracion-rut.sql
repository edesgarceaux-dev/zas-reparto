-- ============================================================
-- APLICACION ZAS - Migración: RUT del cliente (queda guardado cuando se
-- genera una etiqueta con QR desde el portal de la empresa, a partir del
-- PDF de Jumpseller)
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================
alter table public.pedidos add column if not exists rut text;
