-- ============================================================
-- ASIGNAR REPARTIDOR ESCANEANDO, DESDE LA MISMA APP
--
-- Correr en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-plan-y-carga.sql.
--
-- QUÉ RESUELVE
-- ------------
-- Hoy, para asignar un pedido a un repartidor hay que estar en el panel,
-- buscarlo en una lista y elegirlo. En la bodega eso no se puede hacer:
-- los bultos están sobre la mesa, no en una pantalla.
--
-- Con esto, el que reparte la pega en bodega abre la MISMA app, elige
-- «Juan» arriba, y va pasando bulto por bulto frente a la cámara. Cada
-- escaneo hace dos cosas de un saque:
--   1. si el pedido era compartido, se lo queda tu empresa (el bulto está
--      físicamente acá, así que el filtro físico se cumple igual);
--   2. queda asignado a Juan.
-- Cambia a «Pedro» y sigue con la pila de Pedro.
--
-- QUIÉN PUEDE
-- -----------
-- Solo las cuentas con el permiso `puede_asignar` prendido. Se prende y
-- se apaga desde el panel, en la ficha de cada persona. Los admin lo
-- reciben prendido (ya podían asignar desde el panel); el resto, apagado.
-- ============================================================


-- ============================================================
-- 1. EL PERMISO
-- ============================================================
alter table public.perfiles
  add column if not exists puede_asignar boolean not null default false;

comment on column public.perfiles.puede_asignar is
  'Deja usar «Asignar por QR» en la app: escanear bultos y mandárselos a un repartidor.';

-- los admin ya podían asignar desde el panel: no les cambiamos la vida
update public.perfiles
   set puede_asignar = true
 where rol = 'admin' and puede_asignar = false;


-- ============================================================
-- 2. LA LISTA DE REPARTIDORES QUE VE EL QUE ASIGNA
--
-- Un jefe de bodega puede tener rol 'repartidor' y aun así asignar. Ese
-- rol no puede leer la tabla de perfiles (y está bien: ahí hay correos y
-- teléfonos). Así que la app pide esta función, que devuelve solo lo
-- justo: nombre y id de los repartidores activos de SU empresa.
-- ============================================================
create or replace function public.repartidores_para_asignar()
returns table (id uuid, nombre text, pedidos_hoy int)
language plpgsql security definer set search_path = public as $$
declare
  v_emp bigint;
  v_uid uuid := auth.uid();
begin
  select pf.empresa_reparto_id into v_emp
    from public.perfiles pf
   where pf.id = v_uid and pf.activo and pf.puede_asignar;

  if v_emp is null then
    return;                     -- sin permiso: lista vacía, sin filtrar datos
  end if;

  return query
    select pf.id,
           coalesce(nullif(pf.nombre,''), split_part(coalesce(pf.correo,'?'),'@',1)),
           (select count(*)::int from public.pedidos q
             where q.repartidor_id = pf.id
               and q.empresa_reparto_id = v_emp
               and q.creado_en >= (now() at time zone 'America/Santiago')::date)
      from public.perfiles pf
     where pf.empresa_reparto_id = v_emp
       and pf.activo
       and pf.rol in ('repartidor','admin')
     order by 2;
end $$;

grant execute on function public.repartidores_para_asignar() to authenticated;


-- ============================================================
-- 3. EL ESCANEO QUE ASIGNA
--
-- Mismo criterio que reclamar_pedido() —el que lo carga se lo lleva—
-- pero además deja el pedido a nombre del repartidor elegido.
--
-- Se puede llamar con p_repartidor = null: en ese caso solo se lo queda
-- la empresa, sin repartidor, para asignarlo después desde el panel.
-- ============================================================
create or replace function public.asignar_por_escaneo(
  p_codigo      text default null,
  p_envio_id    text default null,
  p_externo_id  text default null,
  p_repartidor  uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_emp     bigint;
  v_uid     uuid;
  v_yo      text;
  v_miemp   text;
  v_rep     text;
  v_antes   uuid;
  v_antes_n text;
  v_n       int;
  p         record;
  v_upd     int;
  v_dueno   text;
  v_total   int;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('ok', false, 'motivo', 'Tu sesión se cerró. Volvé a entrar.');
  end if;

  -- ---------- ¿tengo permiso? ----------
  select pf.empresa_reparto_id, pf.nombre into v_emp, v_yo
    from public.perfiles pf
   where pf.id = v_uid and pf.activo and pf.puede_asignar;

  if v_emp is null then
    return jsonb_build_object('ok', false,
      'motivo', 'Tu cuenta no puede asignar pedidos. Pedile a tu administrador que te lo habilite.');
  end if;
  select nombre into v_miemp from public.empresas_reparto where id = v_emp;

  -- ---------- ¿el repartidor elegido es de mi empresa? ----------
  if p_repartidor is not null then
    select coalesce(nullif(pf.nombre,''), 'el repartidor') into v_rep
      from public.perfiles pf
     where pf.id = p_repartidor
       and pf.activo
       and pf.empresa_reparto_id = v_emp;
    if v_rep is null then
      return jsonb_build_object('ok', false,
        'motivo', 'Ese repartidor no es de tu empresa o está desactivado.');
    end if;
  end if;

  -- ---------- buscar el pedido ----------
  select count(*) into v_n
    from public.pedidos q
   where (p_codigo     is not null and q.codigo     = p_codigo)
      or (p_envio_id   is not null and q.envio_id   = p_envio_id)
      or (p_externo_id is not null and q.externo_id = p_externo_id
          and (q.empresa_reparto_id is null or q.empresa_reparto_id = v_emp));

  if v_n = 0 then
    return jsonb_build_object('ok', false,
      'motivo', 'No encontramos ese pedido. Puede ser de otro día o de otra empresa.');
  elsif v_n > 1 then
    return jsonb_build_object('ok', false,
      'motivo', 'Ese código coincide con más de un pedido. Escaneá el código ZAS de la etiqueta.');
  end if;

  select * into p
    from public.pedidos q
   where (p_codigo     is not null and q.codigo     = p_codigo)
      or (p_envio_id   is not null and q.envio_id   = p_envio_id)
      or (p_externo_id is not null and q.externo_id = p_externo_id
          and (q.empresa_reparto_id is null or q.empresa_reparto_id = v_emp));

  if p.estado in ('entregado','cancelado') then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Ese pedido ya está ' || p.estado || '.');
  end if;

  -- ============================================================
  -- CASO A: ya es de mi empresa → solo cambia de manos
  -- ============================================================
  if p.empresa_reparto_id = v_emp then
    v_antes := p.repartidor_id;
    if v_antes is not null and v_antes <> coalesce(p_repartidor, v_antes) then
      select nullif(pf.nombre,'') into v_antes_n from public.perfiles pf where pf.id = v_antes;
    end if;

    update public.pedidos q
       set repartidor_id = coalesce(p_repartidor, q.repartidor_id),
           cargado_en    = coalesce(q.cargado_en, now()),
           estado        = case when q.estado = 'pendiente' then 'asignado' else q.estado end
     where q.id = p.id;

    select count(*)::int into v_total from public.pedidos q
     where q.repartidor_id = coalesce(p_repartidor, p.repartidor_id)
       and q.empresa_reparto_id = v_emp
       and q.creado_en >= (now() at time zone 'America/Santiago')::date;

    return jsonb_build_object('ok', true, 'ya_era_mio', true,
      'pedido_id', p.id, 'codigo', p.codigo, 'comuna', p.comuna,
      'direccion', p.direccion, 'cliente_final', p.cliente_nombre,
      'repartidor', v_rep, 'total_repartidor', v_total,
      'quitado_a', v_antes_n,
      'mensaje', case when p_repartidor is null then 'Bulto cargado'
                      else 'Asignado a ' || v_rep end);
  end if;

  -- ============================================================
  -- CASO B: es de otra empresa → no se toca
  -- ============================================================
  if p.empresa_reparto_id is not null then
    select e.nombre into v_dueno from public.empresas_reparto e where e.id = p.empresa_reparto_id;
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Este pedido es de ' || coalesce(v_dueno,'otra empresa') || '. No lo cargues.');
  end if;

  -- ============================================================
  -- CASO C: compartido → me lo quedo y lo asigno
  -- ============================================================
  if p.zona = 'fuera' then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Va a ' || coalesce(nullif(p.comuna,''),'una comuna') ||
                ', fuera de la zona de reparto. Devolvelo al mesón.');
  elsif p.zona = 'revisar' then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Este pedido no trae comuna. Que la completen antes de cargarlo.');
  end if;

  if not exists (select 1 from public.cliente_empresas ce
                  where ce.cliente_id = p.cliente_id
                    and ce.empresa_reparto_id = v_emp
                    and ce.activo and ce.estado = 'activa') then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Ese cliente no trabaja con tu empresa.');
  end if;

  -- un solo UPDATE con "empresa_reparto_id is null": si otra empresa lo
  -- escanea en el mismo segundo, la base deja pasar a una sola
  update public.pedidos q
     set empresa_reparto_id  = v_emp,
         repartidor_id       = p_repartidor,
         tomado_por          = v_uid,
         tomado_en           = now(),
         cargado_en          = now(),
         estado              = case when q.estado = 'pendiente' and p_repartidor is not null
                                    then 'asignado' else q.estado end,
         vence_asignacion_en = null,
         asignacion_motivo   = 'lo cargó ' || coalesce(v_yo,'la oficina') ||
                               ' en bodega' ||
                               case when v_rep is null then '' else ', para ' || v_rep end
   where q.id = p.id
     and q.empresa_reparto_id is null;

  get diagnostics v_upd = row_count;

  if v_upd = 0 then
    select e.nombre into v_dueno
      from public.pedidos q join public.empresas_reparto e on e.id = q.empresa_reparto_id
     where q.id = p.id;
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Se adelantó ' || coalesce(v_dueno,'otra empresa') || '. No lo cargues.');
  end if;

  -- avisarle a las empresas que lo tenían planificado
  insert into public.avisos_red (empresa_reparto_id, repartidor_id, pedido_id, codigo, tipo, texto)
  select pr.empresa_reparto_id, pr.repartidor_id, p.id, p.codigo, 'perdido',
         'El pedido ' || coalesce(p.codigo,'#'||p.id) ||
         ' (' || coalesce(nullif(p.comuna,''),'sin comuna') || ') lo cargó ' ||
         coalesce(v_miemp,'otra empresa') || ': salió de tu ruta.'
    from public.plan_reparto pr
   where pr.pedido_id = p.id and pr.empresa_reparto_id <> v_emp;

  delete from public.plan_reparto where pedido_id = p.id;

  insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id, nota)
  values (p.id, v_emp, 'tomado', v_uid,
          'asignado en bodega escaneando' || case when v_rep is null then '' else ' → ' || v_rep end);

  select count(*)::int into v_total from public.pedidos q
   where q.repartidor_id = p_repartidor
     and q.empresa_reparto_id = v_emp
     and q.creado_en >= (now() at time zone 'America/Santiago')::date;

  return jsonb_build_object('ok', true, 'ya_era_mio', false,
    'pedido_id', p.id, 'codigo', p.codigo, 'comuna', p.comuna,
    'direccion', p.direccion, 'cliente_final', p.cliente_nombre,
    'repartidor', v_rep, 'total_repartidor', v_total,
    'mensaje', case when p_repartidor is null
                    then 'Lo cargaste: ya es tuyo'
                    else 'Tuyo y asignado a ' || v_rep end);
end $$;

grant execute on function public.asignar_por_escaneo(text, text, text, uuid) to authenticated;


-- ============================================================
-- 4. DESHACER EL ÚLTIMO
--
-- En bodega se escanea rápido y a veces el bulto que pasó frente a la
-- cámara era el de al lado. Esto lo saca del repartidor. Si el pedido
-- había llegado compartido, vuelve a quedar compartido.
-- ============================================================
create or replace function public.deshacer_asignacion(p_pedido_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_emp bigint;
  v_uid uuid := auth.uid();
  p     record;
begin
  select pf.empresa_reparto_id into v_emp
    from public.perfiles pf
   where pf.id = v_uid and pf.activo and pf.puede_asignar;
  if v_emp is null then
    return jsonb_build_object('ok', false, 'motivo', 'Tu cuenta no puede asignar pedidos.');
  end if;

  select * into p from public.pedidos where id = p_pedido_id and empresa_reparto_id = v_emp;
  if p.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'Ese pedido ya no es de tu empresa.');
  end if;
  if p.estado in ('entregado','cancelado','en_ruta') then
    return jsonb_build_object('ok', false,
      'motivo', 'Ese pedido ya está ' || p.estado || ': no se puede deshacer desde acá.');
  end if;

  -- ¿había llegado por una regla del cliente, o lo tomamos nosotros?
  if p.tomado_por is not null then
    update public.pedidos
       set empresa_reparto_id = null, repartidor_id = null,
           tomado_por = null, tomado_en = null, cargado_en = null,
           estado = case when estado = 'asignado' then 'pendiente' else estado end,
           asignacion_motivo = 'se deshizo el escaneo: vuelve a estar compartido'
     where id = p.id;
    insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id, nota)
    values (p.id, v_emp, 'devuelto', v_uid, 'deshecho desde la app');
    return jsonb_build_object('ok', true, 'pedido_id', p.id, 'codigo', p.codigo,
      'mensaje', 'Deshecho: el pedido volvió a quedar compartido');
  end if;

  update public.pedidos
     set repartidor_id = null, cargado_en = null,
         estado = case when estado = 'asignado' then 'pendiente' else estado end
   where id = p.id;
  return jsonb_build_object('ok', true, 'pedido_id', p.id, 'codigo', p.codigo,
    'mensaje', 'Deshecho: el pedido quedó sin repartidor');
end $$;

grant execute on function public.deshacer_asignacion(bigint) to authenticated;


-- ============================================================
-- COMPROBACIÓN — mirá esta tabla al terminar
-- ============================================================
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='perfiles'
      and column_name='puede_asignar')                       as permiso_creado,
  (select count(*) from public.perfiles where puede_asignar) as cuentas_que_pueden_asignar,
  (select count(*) from pg_proc
    where proname in ('asignar_por_escaneo','repartidores_para_asignar','deshacer_asignacion'))
                                                             as funciones_creadas;
-- permiso_creado = 1 · funciones_creadas = 3
-- cuentas_que_pueden_asignar: son tus admin. Los demás los prendés desde
-- el panel, en Personas → la ficha de cada uno.
