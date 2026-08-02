-- ============================================================
-- APLICACION ZAS - Migración: cuentas MercadoLibre conectadas
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================
create table public.ml_cuentas (
  ml_user_id bigint primary key,          -- id del vendedor en MercadoLibre
  cliente_id bigint not null references public.clientes(id),
  access_token text not null,
  refresh_token text not null,
  expires_en timestamptz not null,
  creado_en timestamptz not null default now()
);

-- Solo las funciones del servidor pueden leer/escribir (sin políticas = bloqueada)
alter table public.ml_cuentas enable row level security;
