-- ============================================================
-- ZONA DE COBERTURA — que no entren pedidos de región
--
-- Correr una sola vez en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-red-empresas.sql y migracion-ajuste-frenos.sql.
--
-- EL PROBLEMA
-- -----------
-- Si llega un pedido a Valparaíso, ninguna empresa cubre esa comuna, así
-- que cae al pool… y cualquiera se lo puede tomar. El pool no sabe que
-- eso está a 100 km.
--
-- QUÉ HACE
-- --------
-- La red ahora tiene una LISTA DE COMUNAS QUE REPARTE (las 52 de la
-- Región Metropolitana, editables desde el panel maestro). Cada pedido
-- queda clasificado:
--
--   zona = 'ok'       → adentro, se reparte normal
--   zona = 'fuera'    → comuna fuera de la lista. No se asigna a nadie ni
--                       aparece en el pool. Solo lo ve el CLIENTE en su
--                       portal, marcado, para que lo despache por otro lado.
--   zona = 'revisar'  → llegó sin comuna. Tampoco se reparte: queda
--                       apartado hasta que alguien la complete.
--
-- Los pedidos cargados A MANO por una empresa no se bloquean: si un
-- administrador lo carga sabiendo lo que hace, es su decisión. Igual
-- quedan marcados.
-- ============================================================


-- ============================================================
-- 1. LA LISTA DE COMUNAS QUE REPARTE LA RED
-- ============================================================
alter table public.config_red add column if not exists comunas_cobertura text[] not null default '{}';

-- Las 52 comunas de la Región Metropolitana. Solo se cargan si la lista
-- está vacía: si ya la editaste, no se te pisa.
update public.config_red
   set comunas_cobertura = array[
     -- Provincia de Santiago (32)
     'Cerrillos','Cerro Navia','Conchalí','El Bosque','Estación Central','Huechuraba',
     'Independencia','La Cisterna','La Florida','La Granja','La Pintana','La Reina',
     'Las Condes','Lo Barnechea','Lo Espejo','Lo Prado','Macul','Maipú','Ñuñoa',
     'Pedro Aguirre Cerda','Peñalolén','Providencia','Pudahuel','Quilicura',
     'Quinta Normal','Recoleta','Renca','San Joaquín','San Miguel','San Ramón',
     'Santiago','Vitacura',
     -- Provincia Cordillera (3)
     'Puente Alto','Pirque','San José de Maipo',
     -- Provincia Chacabuco (3)
     'Colina','Lampa','Tiltil',
     -- Provincia Maipo (4)
     'San Bernardo','Buin','Calera de Tango','Paine',
     -- Provincia Melipilla (5)
     'Melipilla','Alhué','Curacaví','María Pinto','San Pedro',
     -- Provincia Talagante (5)
     'Talagante','El Monte','Isla de Maipo','Padre Hurtado','Peñaflor'
   ]
 where coalesce(array_length(comunas_cobertura,1),0) = 0;


-- ============================================================
-- 2. CADA PEDIDO SABE SI ESTÁ ADENTRO O AFUERA
-- ============================================================
alter table public.pedidos add column if not exists zona text not null default 'ok';
alter table public.pedidos drop constraint if exists pedidos_zona_check;
alter table public.pedidos add constraint pedidos_zona_check
  check (zona in ('ok','fuera','revisar'));
create index if not exists idx_pedidos_zona on public.pedidos (zona) where zona <> 'ok';


-- ============================================================
-- 3. ¿ESTA COMUNA ESTÁ EN LA ZONA?
--    Compara sin tildes ni mayúsculas: "ÑUÑOA", "nunoa" y "Ñuñoa" son
--    la misma. Si la lista de cobertura está vacía, no bloquea nada.
-- ============================================================
create or replace function public.zona_de(p_comuna text)
returns text language sql stable security definer set search_path = public as $$
  select case
    when (select coalesce(array_length(comunas_cobertura,1),0) from public.config_red) = 0
      then 'ok'                                   -- sin lista cargada, no se bloquea nada
    when public.norm_txt(p_comuna) = ''
      then 'revisar'                              -- llegó sin comuna
    when exists (select 1 from public.config_red r, unnest(r.comunas_cobertura) x
                  where public.norm_txt(x) = public.norm_txt(p_comuna))
      then 'ok'
    else 'fuera'
  end;
$$;
grant execute on function public.zona_de(text) to authenticated;


-- ============================================================
-- 4. EL PEDIDO NUEVO SE CLASIFICA ANTES DE REPARTIRSE
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
  -- lo primero: ¿está dentro de la zona que reparte la red?
  new.zona := public.zona_de(new.comuna);

  select count(*) into v_activas from public.cliente_empresas ce
   where ce.cliente_id = new.cliente_id and ce.activo and ce.estado = 'activa';

  -- (a) ya viene con dueño puesto a mano
  if new.empresa_reparto_id is not null then
    new.tomado_en := coalesce(new.tomado_en, now());
    new.asignacion_motivo := coalesce(new.asignacion_motivo, 'asignada al cargar el pedido');
    new.vence_asignacion_en := null;
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

  -- (c) lo carga una empresa habilitada: es su decisión, no se bloquea
  if v_mia is not null and public.puedo_ver_cliente(new.cliente_id) then
    new.empresa_reparto_id := v_mia;
    new.tomado_en := now();
    new.asignacion_motivo := 'lo cargó tu empresa'
      || case when new.zona = 'fuera' then ' (ojo: fuera de la zona de cobertura)' else '' end;
    return new;
  end if;

  -- 🚧 (c-bis) fuera de zona o sin comuna: no se asigna ni va al pool.
  --     Queda a la vista del cliente en su portal, y de nadie más.
  if new.zona = 'fuera' then
    new.asignacion_motivo := 'fuera de la zona de cobertura ('
      || coalesce(nullif(new.comuna,''), 'sin comuna') || '): ninguna empresa reparte ahí';
    return new;
  elsif new.zona = 'revisar' then
    new.asignacion_motivo := 'llegó sin comuna: hay que completarla para poder repartirlo';
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
    new.vence_asignacion_en := null;
  end if;

  return new;
end $$;


-- Si alguien corrige la comuna a mano, el pedido se reclasifica solo.
create or replace function public.fn_pedidos_reloj()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.comuna is distinct from old.comuna then
    new.zona := public.zona_de(new.comuna);
  end if;
  if new.repartidor_id is not null or new.estado not in ('pendiente') then
    new.vence_asignacion_en := null;
  end if;
  return new;
end $$;


-- ============================================================
-- 5. DEL POOL NO SE PUEDE TOMAR LO QUE ESTÁ FUERA DE ZONA
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
       and p.zona = 'ok'                                   -- 🚧 dentro de la zona
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
             when p.zona = 'fuera' then
               'está fuera de la zona de cobertura (' || coalesce(nullif(p.comuna,''),'sin comuna') || ')'
             when p.zona = 'revisar' then 'no tiene comuna: hay que completarla primero'
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
-- 6. NI SIQUIERA APARECEN EN EL POOL DE LAS EMPRESAS
--    (el cliente sí los ve: su política es por cliente_id y no cambia)
-- ============================================================
drop policy if exists pedidos_pool_select on public.pedidos;
create policy pedidos_pool_select on public.pedidos for select
  using (public.es_admin()
     and empresa_reparto_id is null
     and zona = 'ok'
     and public.puedo_ver_cliente(cliente_id));


-- ============================================================
-- 7. CLASIFICAR LO QUE YA ESTÁ CARGADO
--    Solo marca. NO le saca el dueño a ningún pedido que ya tenga
--    empresa: lo que está andando sigue andando.
-- ============================================================
update public.pedidos p
   set zona = public.zona_de(p.comuna)
 where p.zona = 'ok'
   and public.zona_de(p.comuna) <> 'ok';


-- ============================================================
-- COMPROBACIÓN
-- ============================================================
select
  (select array_length(comunas_cobertura,1) from public.config_red)        as comunas_que_reparte,
  (select count(*) from public.pedidos where zona = 'fuera')               as pedidos_fuera_de_zona,
  (select count(*) from public.pedidos where zona = 'revisar')             as pedidos_sin_comuna,
  (select count(*) from public.pedidos
    where zona <> 'ok' and empresa_reparto_id is not null)                 as fuera_pero_ya_asignados;
-- "comunas_que_reparte" tiene que dar 52.
-- "fuera_pero_ya_asignados" son los que ya venían con empresa: quedan como
-- están, solo marcados. Si querés soltarlos, se hace a mano.

select comuna, count(*) as cuantos
  from public.pedidos where zona = 'fuera'
 group by comuna order by 2 desc limit 20;
-- Mirá esta lista: si ves una comuna de la RM mal escrita, agregala a la
-- cobertura desde el panel maestro y esos pedidos se arreglan solos.
