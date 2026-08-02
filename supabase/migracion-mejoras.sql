-- ============================================================
-- APLICACION ZAS - Migración: portal empresa + motivos de no-entrega
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================

-- ---------- 1. MOTIVO DE NO-ENTREGA ESTANDARIZADO ----------
alter table public.pedidos add column motivo_no_entrega text;

-- ---------- 2. ROL "EMPRESA" (portal de solo lectura por cliente) ----------
-- El perfil de una empresa queda ligado a su cliente y solo ve SUS pedidos.
alter table public.perfiles drop constraint if exists perfiles_rol_check;
alter table public.perfiles add constraint perfiles_rol_check
  check (rol in ('admin', 'repartidor', 'empresa'));
alter table public.perfiles add column if not exists cliente_id bigint references public.clientes(id);

-- ¿A qué cliente pertenece el usuario conectado? (solo si su rol es empresa y está activo)
create or replace function public.cliente_de_usuario()
returns bigint language sql stable security definer as $$
  select cliente_id from public.perfiles
  where id = auth.uid() and rol = 'empresa' and activo;
$$;

-- La empresa ve SOLO sus pedidos (nunca los de otras empresas ni los de ZAS)
create policy pedidos_empresa_select on public.pedidos for select
  using (cliente_id is not null and cliente_id = public.cliente_de_usuario());

-- ... su propia ficha de cliente
create policy clientes_empresa_select on public.clientes for select
  using (id = public.cliente_de_usuario());

-- ... el historial de estados de sus pedidos
create policy historial_empresa_select on public.pedido_historial for select
  using (exists (select 1 from public.pedidos p
    where p.id = pedido_id and p.cliente_id = public.cliente_de_usuario()));

-- ... y las pruebas de entrega (fotos, nombre y RUT de quien recibió)
create policy pruebas_empresa_select on public.entregas_prueba for select
  using (exists (select 1 from public.pedidos p
    where p.id = pedido_id and p.cliente_id = public.cliente_de_usuario()));
