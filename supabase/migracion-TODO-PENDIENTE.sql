-- ============================================================
-- APLICACION ZAS — TODAS LAS MIGRACIONES PENDIENTES, EN UNA SOLA
--
-- CÓMO USARLA:
--   Supabase → SQL Editor → New query → pegar TODO esto → Run
--
-- Es SEGURA de correr aunque algunas partes ya estén hechas: todo usa
-- "if not exists" o vuelve a crear la regla desde cero. Se puede correr
-- las veces que sea sin romper nada ni borrar datos.
--
-- QUÉ ARREGLA:
--   1. envio_id  → el n° de envío de MercadoLibre Flex. SIN ESTO la app
--                  NO puede escanear las etiquetas Flex. ← lo que faltaba
--   2. rut       → el RUT que se guarda al generar etiquetas Jumpseller
--   3. perfiles  → ficha del repartidor (dirección, correo, comunas de
--                  preferencia, punto de término propio)
--   4. portal empresa + motivo de no-entrega
-- ============================================================

-- ---------- 1. N° DE ENVÍO DE MERCADOLIBRE FLEX ----------
-- El QR de la etiqueta Flex trae el n° de ENVÍO, no el de la orden.
alter table public.pedidos add column if not exists envio_id text;

-- ---------- 2. RUT DEL CLIENTE FINAL ----------
alter table public.pedidos add column if not exists rut text;

-- ---------- 3. MOTIVO DE NO-ENTREGA ----------
alter table public.pedidos add column if not exists motivo_no_entrega text;

-- ---------- 4. FICHA DEL REPARTIDOR ----------
alter table public.perfiles add column if not exists direccion text;
alter table public.perfiles add column if not exists correo text;
-- comunas de preferencia separadas por coma; "Repartir auto" las respeta por orden
alter table public.perfiles add column if not exists comuna_preferida text;
-- punto donde cierra su ruta (ej: su casa)
alter table public.perfiles add column if not exists termino_lat double precision;
alter table public.perfiles add column if not exists termino_lng double precision;
alter table public.perfiles add column if not exists termino_nombre text;

-- rellenar el correo de contacto con el de acceso, solo donde esté vacío
update public.perfiles p
set correo = u.email
from auth.users u
where u.id = p.id and p.correo is null;

-- ---------- 5. PORTAL DE LA EMPRESA (solo lectura, por cliente) ----------
alter table public.perfiles drop constraint if exists perfiles_rol_check;
alter table public.perfiles add constraint perfiles_rol_check
  check (rol in ('admin', 'repartidor', 'empresa'));

alter table public.perfiles add column if not exists cliente_id bigint
  references public.clientes(id);

-- ¿a qué cliente pertenece el usuario conectado? (solo rol empresa y activo)
create or replace function public.cliente_de_usuario()
returns bigint language sql stable security definer as $$
  select cliente_id from public.perfiles
  where id = auth.uid() and rol = 'empresa' and activo;
$$;

-- la empresa ve SOLO sus pedidos
drop policy if exists pedidos_empresa_select on public.pedidos;
create policy pedidos_empresa_select on public.pedidos for select
  using (cliente_id is not null and cliente_id = public.cliente_de_usuario());

-- ... su propia ficha de cliente
drop policy if exists clientes_empresa_select on public.clientes;
create policy clientes_empresa_select on public.clientes for select
  using (id = public.cliente_de_usuario());

-- ... el historial de estados de sus pedidos
drop policy if exists historial_empresa_select on public.pedido_historial;
create policy historial_empresa_select on public.pedido_historial for select
  using (exists (select 1 from public.pedidos p
    where p.id = pedido_id and p.cliente_id = public.cliente_de_usuario()));

-- ... y las pruebas de entrega
drop policy if exists pruebas_empresa_select on public.entregas_prueba;
create policy pruebas_empresa_select on public.entregas_prueba for select
  using (exists (select 1 from public.pedidos p
    where p.id = pedido_id and p.cliente_id = public.cliente_de_usuario()));

-- ============================================================
-- COMPROBACIÓN: al terminar deberías ver las 4 columnas nuevas
-- ============================================================
select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'pedidos'  and column_name in ('envio_id','rut','motivo_no_entrega'))
    or (table_name = 'perfiles' and column_name in
        ('direccion','correo','comuna_preferida','termino_lat','termino_lng','termino_nombre','cliente_id'))
  )
order by table_name, column_name;
