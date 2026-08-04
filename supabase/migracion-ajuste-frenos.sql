-- ============================================================
-- AJUSTE DE LOS FRENOS ANTI-ACAPARAMIENTO
--
-- Correr una sola vez en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-red-empresas.sql.
--
-- QUÉ ESTABA MAL
-- --------------
-- El tope y el plazo se armaron para frenar al que TOMA DEL POOL pedidos
-- que no va a repartir. Pero los estaba aplicando a TODOS los pedidos de
-- la empresa, incluidos los que le llegan solos por las reglas del
-- cliente. Consecuencias:
--
--   1. Una empresa con 400 pedidos del día esperando que se les asigne
--      repartidor quedaba pasada de tope y NO PODÍA TOMAR NADA del pool,
--      aunque no hubiera tomado un solo pedido del pool en su vida.
--
--   2. 🔴 Más grave: a los pedidos que entran por las reglas del cliente
--      también les corría el reloj. Si la empresa reparte a la tarde y
--      los pedidos entran a la mañana, a las 2 horas se le iban SOLOS al
--      pool y otra empresa se los podía llevar. Nunca fue la idea.
--
-- QUÉ HACE ESTO
-- -------------
--   · El tope cuenta SOLO los pedidos que la empresa se llevó del pool y
--     todavía no tienen repartidor. Lo que llega por reglas no cuenta.
--   · El reloj corre SOLO para lo que se tomó del pool.
--   · Apaga el reloj de los pedidos que ya lo tenían corriendo sin haber
--     salido del pool.
--
-- Cómo distingue uno de otro: `pedidos.tomado_por` tiene el usuario que
-- apretó "Tomar" en el pool. Los que se asignan solos por regla lo tienen
-- en NULL.
-- ============================================================


-- ============================================================
-- 1. EL RELOJ NO CORRE PARA LOS QUE LLEGAN POR REGLA
-- ============================================================
create or replace function public.fn_asignar_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_mia       bigint;
  v_n         int;
  v_activas   int;
  v_todas_pct boolean;
  v_elegida   bigint;
  v_empates   int;
  v_prio      int;
begin
  select count(*) into v_activas from public.cliente_empresas ce
   where ce.cliente_id = new.cliente_id and ce.activo and ce.estado = 'activa';

  -- (a) ya viene con dueño puesto a mano
  if new.empresa_reparto_id is not null then
    new.tomado_en := coalesce(new.tomado_en, now());
    new.asignacion_motivo := coalesce(new.asignacion_motivo, 'asignada al cargar el pedido');
    new.vence_asignacion_en := null;          -- no salió del pool: sin reloj
    return new;
  end if;

  v_mia := public.mi_empresa_reparto();

  -- (b) pedido manual sin cliente
  if new.cliente_id is null then
    new.empresa_reparto_id := v_mia;
    if v_mia is not null then
      new.tomado_en := now();
      new.asignacion_motivo := 'pedido cargado a mano';
    end if;
    return new;
  end if;

  -- (c) lo carga una empresa habilitada para ese cliente
  if v_mia is not null and public.puedo_ver_cliente(new.cliente_id) then
    new.empresa_reparto_id := v_mia;
    new.tomado_en := now();
    new.asignacion_motivo := 'lo cargó tu empresa';
    return new;
  end if;

  -- (d) el cliente no tiene a nadie habilitado
  if v_activas = 0 then
    new.asignacion_motivo := 'el cliente todavía no habilitó ninguna empresa';
    return new;
  end if;

  -- (e) una sola empresa
  if v_activas = 1 then
    select ce.empresa_reparto_id into v_elegida from public.cliente_empresas ce
     where ce.cliente_id = new.cliente_id and ce.activo and ce.estado = 'activa';
    new.empresa_reparto_id := v_elegida;
    new.tomado_en := now();
    new.asignacion_motivo := 'única empresa habilitada por el cliente';
    return new;
  end if;

  -- (f) el cliente eligió pool libre
  if coalesce((select modo_reparto from public.clientes where id = new.cliente_id), 'reglas') = 'pool' then
    new.asignacion_motivo := 'el cliente eligió pool libre';
    return new;
  end if;

  -- (g) reglas del cliente
  select count(*), coalesce(bool_and(porcentaje is not null), false)
    into v_n, v_todas_pct
    from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido);

  if v_n = 0 then
    new.asignacion_motivo := 'ninguna empresa cubre ' ||
      coalesce(nullif(new.comuna,''), 'esa comuna') || ' o todas llegaron a su cuota del día';

  elsif v_n = 1 then
    select c.empresa_reparto_id into v_elegida
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c;
    new.empresa_reparto_id := v_elegida;
    new.asignacion_motivo := 'regla del cliente para ' || coalesce(nullif(new.comuna,''), 'esa comuna');

  elsif v_todas_pct then
    select c.empresa_reparto_id into v_elegida
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c
     order by c.atraso desc, c.prioridad, c.empresa_reparto_id limit 1;
    new.empresa_reparto_id := v_elegida;
    new.asignacion_motivo := 'reparto por porcentaje';

  else
    select min(c.prioridad) into v_prio
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c;
    select count(*) into v_empates
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c
     where c.prioridad = v_prio;

    if v_empates = 1 then
      select c.empresa_reparto_id into v_elegida
        from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c
       where c.prioridad = v_prio;
      new.empresa_reparto_id := v_elegida;
      new.asignacion_motivo := 'prioridad que puso el cliente';
    else
      new.asignacion_motivo := v_empates || ' empresas calzan parejo: lo decide el pool';
    end if;
  end if;

  if new.empresa_reparto_id is not null then
    new.tomado_en := now();
    -- 🔧 sin reloj: no lo tomó del pool, se lo dio la regla del cliente
    new.vence_asignacion_en := null;
  end if;

  return new;
end $$;


-- ============================================================
-- 2. EL TOPE CUENTA SOLO LO QUE SE LLEVÓ DEL POOL
-- ============================================================
create or replace function public.tomar_pedidos(p_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_emp     bigint;
  v_tomados bigint[];
  v_rechaza jsonb;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null then
    raise exception 'Tu cuenta no pertenece a ninguna empresa de reparto';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    return jsonb_build_object('tomados', 0, 'ids', '[]'::jsonb, 'no_pudo', '[]'::jsonb);
  end if;

  perform public.liberar_vencidos();

  with pedir as (
    select p.id, p.cliente_id,
           row_number() over (partition by p.cliente_id order by p.id) as rn
      from public.pedidos p
     where p.id = any(p_ids)
       and p.empresa_reparto_id is null
       and p.estado not in ('entregado','cancelado')
       and exists (select 1 from public.cliente_empresas ce
                    where ce.cliente_id = p.cliente_id
                      and ce.empresa_reparto_id = v_emp
                      and ce.activo and ce.estado = 'activa')
  ), cupo as (
    select d.cliente_id,
           greatest(0, (select tope from public.limites_cliente(d.cliente_id))
                     - (select count(*) from public.pedidos q
                         where q.empresa_reparto_id = v_emp
                           and q.cliente_id = d.cliente_id
                           and q.repartidor_id is null
                           and q.estado = 'pendiente'
                           -- 🔧 solo los que salieron del pool
                           and q.tomado_por is not null)) as libre
      from (select distinct cliente_id from pedir) d
  ), elegibles as (
    select pd.id from pedir pd
      join cupo c on c.cliente_id is not distinct from pd.cliente_id
     where pd.rn <= c.libre
  ), upd as (
    update public.pedidos p
       set empresa_reparto_id = v_emp,
           tomado_en          = now(),
           tomado_por         = auth.uid(),
           asignacion_motivo  = 'tomado del pool',
           vence_asignacion_en = now() + make_interval(
             mins => (select plazo_min from public.limites_cliente(p.cliente_id)))
     where p.id in (select id from elegibles)
       and p.empresa_reparto_id is null
    returning p.id
  )
  select coalesce(array_agg(id), '{}') into v_tomados from upd;

  insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id)
  select unnest(v_tomados), v_emp, 'tomado', auth.uid();

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'motivo', case
             when p.id is null then 'ya no existe'
             when p.empresa_reparto_id is not null then
               'se adelantó ' || coalesce((select e.nombre from public.empresas_reparto e
                                            where e.id = p.empresa_reparto_id), 'otra empresa')
             when p.estado in ('entregado','cancelado') then 'ya está ' || p.estado
             when not exists (select 1 from public.cliente_empresas ce
                               where ce.cliente_id = p.cliente_id
                                 and ce.empresa_reparto_id = v_emp
                                 and ce.activo and ce.estado = 'activa')
               then 'ese cliente no habilitó a tu empresa'
             else 'ya tenés ' ||
                  (select tope from public.limites_cliente(p.cliente_id)) ||
                  ' pedidos tomados del pool sin repartidor. Asignales repartidor y volvé'
           end)), '[]'::jsonb)
    into v_rechaza
    from unnest(p_ids) as x(id)
    left join public.pedidos p on p.id = x.id
   where not (x.id = any(v_tomados));

  return jsonb_build_object(
    'tomados', coalesce(array_length(v_tomados,1), 0),
    'ids',     to_jsonb(v_tomados),
    'no_pudo', v_rechaza);
end $$;


-- ============================================================
-- 3. SOLO VUELVE AL POOL LO QUE SALIÓ DEL POOL
-- ============================================================
create or replace function public.liberar_vencidos()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  with vencidos as (
    select p.id, p.empresa_reparto_id
      from public.pedidos p
     where p.vence_asignacion_en is not null
       and p.vence_asignacion_en < now()
       and p.empresa_reparto_id is not null
       and p.repartidor_id is null
       and p.estado = 'pendiente'
       and p.cliente_id is not null
       and p.tomado_por is not null          -- 🔧 salió del pool
       and (select count(*) from public.cliente_empresas ce
             where ce.cliente_id = p.cliente_id and ce.activo and ce.estado = 'activa') >= 2
  ), log as (
    insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, nota)
    select v.id, v.empresa_reparto_id, 'vencido',
           'se venció el plazo para asignarle repartidor'
      from vencidos v
    returning 1
  )
  update public.pedidos p
     set empresa_reparto_id = null,
         tomado_en = null,
         tomado_por = null,
         vence_asignacion_en = null,
         veces_devuelto = p.veces_devuelto + 1,
         asignacion_motivo = 'volvió al pool: venció el plazo para asignar repartidor'
    from vencidos v
   where p.id = v.id;

  get diagnostics v_n = row_count;
  return v_n;
end $$;


-- ============================================================
-- 4. APAGAR EL RELOJ DE LOS QUE NUNCA SALIERON DEL POOL
--    (si no, se te van solos al pool los que llegaron por regla)
-- ============================================================
update public.pedidos
   set vence_asignacion_en = null
 where vence_asignacion_en is not null
   and tomado_por is null;


-- ============================================================
-- COMPROBACIÓN
-- ============================================================
select
  (select count(*) from public.pedidos
    where vence_asignacion_en is not null)                       as con_reloj_corriendo,
  (select count(*) from public.pedidos
    where tomado_por is not null and repartidor_id is null
      and estado = 'pendiente')                                  as tomados_del_pool_sin_repartidor,
  (select tope_sin_asignar from public.config_red)               as tope_de_la_red;
-- "con_reloj_corriendo" tiene que ser 0 o igual a los que tomaste del pool
-- y todavía no asignaste. Nunca cientos.
