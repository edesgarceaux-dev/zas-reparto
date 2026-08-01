-- ============================================================
-- APLICACION ZAS - Migración: clientes + ingesta automática (Jumpseller)
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> pegar -> Run
-- ============================================================

-- ---------- 1. TABLA CLIENTES (empresas a las que ZAS reparte) ----------
create table public.clientes (
  id bigint generated always as identity primary key,
  nombre text not null,
  rut text,
  telefono text,
  email text,
  direccion_retiro text,          -- de dónde se retiran los pedidos
  comuna text,
  notas text,
  integracion text not null default 'manual'
    check (integracion in ('manual','jumpseller')),
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

-- ---------- 2. PEDIDOS: vínculo con cliente y antiduplicados ----------
alter table public.pedidos add column cliente_id bigint references public.clientes(id);
alter table public.pedidos add column externo_id text;  -- nº de orden en la tienda externa

-- un mismo pedido de la tienda no puede entrar dos veces
create unique index idx_pedidos_externo
  on public.pedidos (cliente_id, externo_id);
-- (los pedidos manuales tienen externo_id NULL y no chocan entre sí)

create index idx_pedidos_cliente on public.pedidos (cliente_id, fecha_pedido);

-- ---------- 3. SEGURIDAD ----------
alter table public.clientes enable row level security;

-- admin administra clientes; cualquier usuario conectado puede leer
-- (el repartidor necesita ver el nombre y dirección de retiro del cliente)
create policy clientes_select on public.clientes for select
  using (auth.uid() is not null);
create policy clientes_admin_all on public.clientes for all
  using (public.es_admin()) with check (public.es_admin());

-- ---------- 4. PRIMER CLIENTE: LA DISTRIBUIDORA ----------
-- Edita el nombre antes de ejecutar si quieres:
insert into public.clientes (nombre, integracion)
values ('Distribuidora Pepitos', 'jumpseller');
