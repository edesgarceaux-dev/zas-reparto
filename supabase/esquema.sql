-- ============================================================
-- APLICACION ZAS - Esquema de base de datos (Etapa 1 + bases Etapa 2)
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> pegar -> Run
-- ============================================================

-- ---------- 1. PERFILES DE USUARIO ----------
-- Cada usuario de auth.users tiene un perfil con rol: 'admin' o 'repartidor'
create table public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  telefono text,
  rol text not null default 'repartidor' check (rol in ('admin', 'repartidor')),
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

-- ---------- 2. PEDIDOS ----------
create table public.pedidos (
  id bigint generated always as identity primary key,
  codigo text unique,                          -- codigo visible ej: ZAS-0001
  cliente_nombre text not null,
  cliente_telefono text,
  direccion text not null,
  comuna text,
  referencia text,                             -- indicaciones extra de la direccion
  detalle text,                                -- que se entrega
  monto numeric(12,0),                         -- monto a cobrar (CLP, sin decimales)
  metodo_pago text check (metodo_pago in ('pagado','efectivo','transferencia','tarjeta')),
  origen text not null default 'manual',      -- manual | excel | integracion | whatsapp
  estado text not null default 'pendiente'
    check (estado in ('pendiente','asignado','aceptado','en_camino','entregado','no_entregado','cancelado')),
  repartidor_id uuid references public.perfiles(id),
  creado_por uuid references public.perfiles(id),
  fecha_pedido date not null default (now() at time zone 'America/Santiago')::date,
  asignado_en timestamptz,
  entregado_en timestamptz,
  nota_entrega text,                           -- comentario del repartidor al cerrar
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

create index idx_pedidos_repartidor on public.pedidos (repartidor_id, fecha_pedido);
create index idx_pedidos_estado on public.pedidos (estado, fecha_pedido);
create index idx_pedidos_fecha on public.pedidos (fecha_pedido);

-- Codigo automatico ZAS-N y timestamp de actualizacion
create or replace function public.fn_pedidos_before()
returns trigger language plpgsql as $$
begin
  if new.codigo is null then
    new.codigo := 'ZAS-' || lpad(new.id::text, 5, '0');
  end if;
  new.actualizado_en := now();
  if new.estado = 'asignado' and old.estado is distinct from 'asignado' then
    new.asignado_en := now();
  end if;
  if new.estado = 'entregado' and old.estado is distinct from 'entregado' then
    new.entregado_en := now();
  end if;
  return new;
end $$;

create trigger trg_pedidos_before
before insert or update on public.pedidos
for each row execute function public.fn_pedidos_before();

-- ---------- 3. HISTORIAL DE ESTADOS ----------
create table public.pedido_historial (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references public.pedidos(id) on delete cascade,
  estado text not null,
  usuario_id uuid references public.perfiles(id),
  creado_en timestamptz not null default now()
);

create index idx_historial_pedido on public.pedido_historial (pedido_id);

create or replace function public.fn_log_estado()
returns trigger language plpgsql security definer as $$
begin
  if tg_op = 'INSERT' or new.estado is distinct from old.estado then
    insert into public.pedido_historial (pedido_id, estado, usuario_id)
    values (new.id, new.estado, auth.uid());
  end if;
  return new;
end $$;

create trigger trg_log_estado
after insert or update on public.pedidos
for each row execute function public.fn_log_estado();

-- ---------- 4. UBICACIONES GPS (Etapa 2, tabla lista desde ya) ----------
create table public.ubicaciones (
  repartidor_id uuid primary key references public.perfiles(id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  actualizado_en timestamptz not null default now()
);

-- ---------- 5. PRUEBAS DE ENTREGA (Etapa 2) ----------
create table public.entregas_prueba (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references public.pedidos(id) on delete cascade,
  foto_url text,
  firma_url text,
  comentario text,
  creado_en timestamptz not null default now()
);

-- ---------- 6. SEGURIDAD (RLS) ----------
alter table public.perfiles enable row level security;
alter table public.pedidos enable row level security;
alter table public.pedido_historial enable row level security;
alter table public.ubicaciones enable row level security;
alter table public.entregas_prueba enable row level security;

-- Funcion: es admin?
create or replace function public.es_admin()
returns boolean language sql stable security definer as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and rol = 'admin' and activo);
$$;

-- Perfiles: cada uno ve el suyo; admin ve y administra todos
create policy perfiles_select on public.perfiles for select
  using (id = auth.uid() or public.es_admin());
create policy perfiles_admin_all on public.perfiles for all
  using (public.es_admin()) with check (public.es_admin());

-- Pedidos: admin todo; repartidor ve los suyos y solo puede cambiar estado/nota
create policy pedidos_admin_all on public.pedidos for all
  using (public.es_admin()) with check (public.es_admin());
create policy pedidos_repartidor_select on public.pedidos for select
  using (repartidor_id = auth.uid());
create policy pedidos_repartidor_update on public.pedidos for update
  using (repartidor_id = auth.uid())
  with check (repartidor_id = auth.uid());

-- Historial: visible segun acceso al pedido
create policy historial_select on public.pedido_historial for select
  using (public.es_admin() or exists (
    select 1 from public.pedidos p where p.id = pedido_id and p.repartidor_id = auth.uid()));

-- Ubicaciones: repartidor escribe la suya; admin ve todas
create policy ubicaciones_upsert on public.ubicaciones for all
  using (repartidor_id = auth.uid()) with check (repartidor_id = auth.uid());
create policy ubicaciones_admin_select on public.ubicaciones for select
  using (public.es_admin());

-- Pruebas de entrega: repartidor del pedido inserta; admin ve todo
create policy pruebas_insert on public.entregas_prueba for insert
  with check (exists (
    select 1 from public.pedidos p where p.id = pedido_id and p.repartidor_id = auth.uid()));
create policy pruebas_select on public.entregas_prueba for select
  using (public.es_admin() or exists (
    select 1 from public.pedidos p where p.id = pedido_id and p.repartidor_id = auth.uid()));

-- ---------- 7. TIEMPO REAL ----------
alter publication supabase_realtime add table public.pedidos;
alter publication supabase_realtime add table public.ubicaciones;

-- ---------- 8. PERFIL AUTOMATICO AL CREAR USUARIO ----------
-- Crea el perfil cuando se registra un usuario (rol por defecto: repartidor).
-- El primer usuario creado sera admin automaticamente.
create or replace function public.fn_nuevo_usuario()
returns trigger language plpgsql security definer as $$
declare
  total int;
begin
  select count(*) into total from public.perfiles;
  insert into public.perfiles (id, nombre, rol)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
    case when total = 0 then 'admin' else 'repartidor' end
  );
  return new;
end $$;

create trigger trg_nuevo_usuario
after insert on auth.users
for each row execute function public.fn_nuevo_usuario();
