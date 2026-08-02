-- ============================================================
-- APLICACION ZAS - Migración: número de envío (para escanear
-- etiquetas de MercadoLibre Flex con la app)
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================
alter table public.pedidos add column if not exists envio_id text;
