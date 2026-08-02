-- ============================================================
-- APLICACION ZAS - Migración: días de despacho por cliente
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================
-- 7 caracteres: lunes..domingo. 1 = despacha ese día, 0 = no.
-- Si un pedido cae en día sin despacho, salta al siguiente día hábil.
alter table public.clientes add column dias_despacho text not null default '1111111';

-- Distribuidora Pepito: lunes a sábado (domingo no)
update public.clientes set dias_despacho = '1111110' where id = 1;
