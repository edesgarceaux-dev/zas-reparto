-- ============================================================
-- RESPALDO Y LIMPIEZA DE LAS FOTOS DE ENTREGA
--
-- Correr en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-permisos.sql.
--
-- EL PROBLEMA, EN NÚMEROS
-- -----------------------
-- Lo que se llena NO es la base de datos: es el ALMACENAMIENTO de fotos.
-- Una fila de pedido pesa ~1 KB; 7.700 pedidos al mes son 8 MB. Nada.
-- Pero cada entrega sube 3 fotos de ~180 KB. A 258 pedidos por día:
--
--     258 × 3 × 180 KB  ≈  140 MB por día  ≈  4,2 GB por mes
--
-- Eso es lo que hay que administrar. La base puede crecer tranquila
-- durante años; las fotos no.
--
-- LA SOLUCIÓN, EN TRES PIEZAS
-- ---------------------------
-- 1. Desde el panel se descarga un ZIP por período (semana, quincena o
--    mes) con la planilla de pedidos y las fotos. Ese es el respaldo.
-- 2. Acá queda anotado qué período se descargó y cuándo.
-- 3. Recién entonces se pueden borrar del servidor las fotos de más de
--    90 días. Nunca se borra algo que no esté respaldado.
--
-- Los DATOS del pedido no se borran nunca: son livianos y sirven para
-- las estadísticas. Lo único que se va son los archivos de imagen.
-- ============================================================


-- ============================================================
-- 1. QUÉ PERÍODOS YA ESTÁN RESPALDADOS
-- ============================================================
create table if not exists public.archivos_periodo (
  id                 bigint generated always as identity primary key,
  empresa_reparto_id bigint not null references public.empresas_reparto(id) on delete cascade,
  desde              date not null,
  hasta              date not null,
  pedidos            int  not null default 0,
  fotos              int  not null default 0,
  descargado_en      timestamptz not null default now(),
  descargado_por     uuid references public.perfiles(id) on delete set null,
  fotos_borradas_en  timestamptz,
  fotos_borradas     int not null default 0,
  unique (empresa_reparto_id, desde, hasta)
);
create index if not exists idx_archivos_empresa
  on public.archivos_periodo (empresa_reparto_id, hasta desc);

comment on table public.archivos_periodo is
  'Un renglón por período descargado. Sin un renglón que lo cubra, las fotos de ese período NO se pueden borrar.';

alter table public.archivos_periodo enable row level security;
drop policy if exists archivos_super on public.archivos_periodo;
create policy archivos_super on public.archivos_periodo for all
  using (public.es_superadmin()) with check (public.es_superadmin());
drop policy if exists archivos_empresa on public.archivos_periodo;
create policy archivos_empresa on public.archivos_periodo for all
  using (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto())
  with check (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto());


-- ============================================================
-- 2. LO QUE ENTRA EN EL REPORTE DE UN PERÍODO
--    Un renglón por pedido entregado, con sus fotos.
-- ============================================================
create or replace function public.reporte_periodo(p_desde date, p_hasta date)
returns table (
  pedido_id      bigint,
  n_envio        text,
  codigo         text,
  cliente        text,
  cliente_final  text,
  telefono       text,
  direccion      text,
  comuna         text,
  repartidor     text,
  estado         text,
  fecha_pedido   date,
  entregado_en   timestamptz,
  recibio        text,
  rut_recibe     text,
  motivo_no_entrega text,
  nota_entrega   text,
  foto_domicilio text,
  foto_pedido    text,
  foto_receptor  text,
  foto_extra     text)
language sql stable security definer set search_path = public as $$
  select p.id,
         coalesce(nullif(p.envio_id,''), replace(coalesce(p.externo_id,''),'ML-',''), p.codigo),
         p.codigo,
         c.nombre,
         p.cliente_nombre,
         p.cliente_telefono,
         p.direccion,
         p.comuna,
         pf.nombre,
         p.estado,
         p.fecha_pedido,
         p.entregado_en,
         e.nombre_recibe,
         e.rut_recibe,
         p.motivo_no_entrega,
         p.nota_entrega,
         e.foto_domicilio, e.foto_pedido, e.foto_receptor, e.foto_url
    from public.pedidos p
    left join public.clientes  c  on c.id  = p.cliente_id
    left join public.perfiles  pf on pf.id = p.repartidor_id
    left join lateral (
      select * from public.entregas_prueba x
       where x.pedido_id = p.id
       order by x.creado_en desc limit 1) e on true
   where p.fecha_pedido between p_desde and p_hasta
     and p.empresa_reparto_id = public.mi_empresa_reparto()
   order by p.fecha_pedido, p.id;
$$;
grant execute on function public.reporte_periodo(date, date) to authenticated;


-- ============================================================
-- 3. CUÁNTO ESPACIO HAY OCUPADO, MES A MES
--    Se estima a 180 KB por foto: no hace falta pedirle el peso real a
--    cada archivo (serían miles de llamadas).
-- ============================================================
create or replace function public.uso_fotos()
returns table (
  mes            text,
  pedidos        bigint,
  fotos          bigint,
  mb_estimados   numeric,
  respaldado     boolean,
  borrable       boolean)
language sql stable security definer set search_path = public as $$
  with base as (
    select to_char(p.fecha_pedido,'YYYY-MM')                      as mes,
           min(p.fecha_pedido)                                    as desde,
           max(p.fecha_pedido)                                    as hasta,
           count(*)                                               as pedidos,
           count(e.foto_domicilio) + count(e.foto_pedido)
             + count(e.foto_receptor) + count(e.foto_url)         as fotos
      from public.pedidos p
      left join public.entregas_prueba e on e.pedido_id = p.id
     where p.empresa_reparto_id = public.mi_empresa_reparto()
     group by 1)
  select b.mes, b.pedidos, b.fotos,
         round(b.fotos * 180.0 / 1024, 1),
         exists (select 1 from public.archivos_periodo a
                  where a.empresa_reparto_id = public.mi_empresa_reparto()
                    and a.desde <= b.desde and a.hasta >= b.hasta),
         (b.hasta < current_date - 90)
           and exists (select 1 from public.archivos_periodo a
                        where a.empresa_reparto_id = public.mi_empresa_reparto()
                          and a.desde <= b.desde and a.hasta >= b.hasta)
    from base b
   order by b.mes desc;
$$;
grant execute on function public.uso_fotos() to authenticated;


-- ============================================================
-- 4. ANOTAR QUE UN PERÍODO YA SE DESCARGÓ
-- ============================================================
create or replace function public.marcar_respaldado(
  p_desde date, p_hasta date, p_pedidos int, p_fotos int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp bigint;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null or not public.es_admin() then
    raise exception 'Solo un administrador de una empresa puede respaldar';
  end if;
  if p_hasta < p_desde then
    raise exception 'El período está al revés: "hasta" es anterior a "desde".';
  end if;

  insert into public.archivos_periodo
    (empresa_reparto_id, desde, hasta, pedidos, fotos, descargado_por)
  values (v_emp, p_desde, p_hasta, coalesce(p_pedidos,0), coalesce(p_fotos,0), auth.uid())
  on conflict (empresa_reparto_id, desde, hasta) do update
     set pedidos = excluded.pedidos,
         fotos = excluded.fotos,
         descargado_en = now(),
         descargado_por = excluded.descargado_por;

  return jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta);
end $$;
grant execute on function public.marcar_respaldado(date, date, int, int) to authenticated;


-- ============================================================
-- 5. QUÉ FOTOS SE PUEDEN BORRAR
--
-- Tres condiciones, las tres a la vez:
--   · el pedido tiene más de 90 días
--   · ese período ya se descargó (hay un renglón en archivos_periodo)
--   · las fotos son de MI empresa
--
-- Devuelve las RUTAS dentro del bucket, que es lo que el panel necesita
-- para pedirle a Supabase que las borre.
-- ============================================================
create or replace function public.fotos_para_borrar(p_dias int default 90, p_limite int default 500)
returns table (pedido_id bigint, ruta text)
language sql stable security definer set search_path = public as $$
  with mias as (
    select p.id, p.fecha_pedido, e.foto_domicilio, e.foto_pedido, e.foto_receptor, e.foto_url
      from public.pedidos p
      join public.entregas_prueba e on e.pedido_id = p.id
     where p.empresa_reparto_id = public.mi_empresa_reparto()
       and p.fecha_pedido < current_date - greatest(coalesce(p_dias,90), 30)
       and exists (select 1 from public.archivos_periodo a
                    where a.empresa_reparto_id = public.mi_empresa_reparto()
                      and a.desde <= p.fecha_pedido and a.hasta >= p.fecha_pedido))
  select m.id, r.ruta
    from mias m
    cross join lateral (
      values (m.foto_domicilio), (m.foto_pedido), (m.foto_receptor), (m.foto_url)
    ) as v(url)
    cross join lateral (
      -- de la URL pública sale la ruta dentro del bucket: .../entregas/<ruta>
      select substring(v.url from '/entregas/(.*)$') as ruta
    ) r
   where v.url is not null and r.ruta is not null
   limit greatest(coalesce(p_limite,500), 1);
$$;
grant execute on function public.fotos_para_borrar(int, int) to authenticated;


-- ============================================================
-- 6. OLVIDAR LAS FOTOS YA BORRADAS
--    Los datos del pedido y quién recibió NO se tocan: solo se limpian
--    los links de las imágenes, que ya no apuntan a ningún lado.
-- ============================================================
create or replace function public.olvidar_fotos(p_pedidos bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp bigint; v_n int := 0;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null or not public.es_admin() then
    raise exception 'Solo un administrador de una empresa puede limpiar fotos';
  end if;

  update public.entregas_prueba e
     set foto_domicilio = null, foto_pedido = null,
         foto_receptor = null, foto_url = null
   where e.pedido_id = any(p_pedidos)
     and exists (select 1 from public.pedidos p
                  where p.id = e.pedido_id and p.empresa_reparto_id = v_emp);
  get diagnostics v_n = row_count;

  update public.archivos_periodo a
     set fotos_borradas_en = now(),
         fotos_borradas = a.fotos_borradas + v_n
   where a.empresa_reparto_id = v_emp
     and a.hasta < current_date - 90
     and a.fotos_borradas_en is null;

  return jsonb_build_object('limpiados', v_n);
end $$;
grant execute on function public.olvidar_fotos(bigint[]) to authenticated;


-- ============================================================
-- 7. EL PANEL TIENE QUE PODER LEER LAS PRUEBAS PARA ARMAR EL REPORTE
-- ============================================================
drop policy if exists pruebas_empresa_select on public.entregas_prueba;
create policy pruebas_empresa_select on public.entregas_prueba for select
  using (public.es_superadmin()
      or exists (select 1 from public.pedidos p
                  where p.id = entregas_prueba.pedido_id
                    and (p.empresa_reparto_id = public.mi_empresa_reparto()
                         or p.repartidor_id = auth.uid()
                         or public.puedo_ver_pedido(p.id))));
drop policy if exists pruebas_empresa_update on public.entregas_prueba;
create policy pruebas_empresa_update on public.entregas_prueba for update
  using (public.es_superadmin()
      or (public.es_admin() and exists (select 1 from public.pedidos p
             where p.id = entregas_prueba.pedido_id
               and p.empresa_reparto_id = public.mi_empresa_reparto())));


-- ============================================================
-- COMPROBACIÓN — mirá esta tabla al terminar
-- ============================================================
select
  (select count(*) from information_schema.tables
    where table_schema='public' and table_name='archivos_periodo')      as tabla_creada,
  (select count(*) from pg_proc where proname in
     ('reporte_periodo','uso_fotos','marcar_respaldado',
      'fotos_para_borrar','olvidar_fotos'))                             as funciones_creadas,
  (select count(*) from public.entregas_prueba)                         as entregas_con_fotos;
-- tabla_creada = 1 · funciones_creadas = 5
