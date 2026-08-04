-- ============================================================
-- EL QUE LO ESCANEA SE LO LLEVA
--
-- Correr una sola vez en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-zona-cobertura.sql.
--
-- EL CAMBIO
-- ---------
-- Antes, un pedido del pool se reclamaba apretando "✋ Tomar" en el panel:
-- una carrera de clicks entre empresas. Ahora se reclama de la única
-- forma que no se puede hacer trampa: **cargándolo**. El repartidor
-- escanea la etiqueta con su app y en ese momento el pedido pasa a ser
-- de su empresa y queda asignado a él.
--
-- Nadie puede acaparar lo que no se llevó en la moto, así que el tope y
-- el plazo dejan de hacer falta (las funciones quedan, pero ya no se usan
-- desde el panel).
--
-- LAS REGLAS SIGUEN MANDANDO
-- --------------------------
-- El escaneo decide SOLO sobre los pedidos que están en el pool. Si el
-- cliente le asignó esa comuna a una empresa, el repartidor de otra que
-- escanee esa etiqueta recibe "este pedido es de Envíos ZAS" y no se lo
-- puede llevar.
-- ============================================================

create or replace function public.reclamar_pedido(
  p_codigo     text default null,
  p_envio_id   text default null,
  p_externo_id text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_emp    bigint;
  v_uid    uuid;
  v_nombre text;
  v_n      int;
  p        record;
  v_upd    int;
  v_dueno  text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('ok', false, 'motivo', 'Tu sesión se cerró. Volvé a entrar.');
  end if;

  select pf.empresa_reparto_id, pf.nombre into v_emp, v_nombre
    from public.perfiles pf where pf.id = v_uid and pf.activo;

  if v_emp is null then
    return jsonb_build_object('ok', false,
      'motivo', 'Tu cuenta no está asignada a ninguna empresa de reparto. Avisale a tu administrador.');
  end if;

  -- ---------- buscar el pedido ----------
  -- Se busca entre TODOS (esta función pasa por encima de los permisos a
  -- propósito): si no, un repartidor no podría ni ver un pedido del pool.
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

  -- ---------- ya tiene dueño ----------
  if p.empresa_reparto_id is not null then
    if p.empresa_reparto_id = v_emp then
      -- es de mi empresa: la app sigue con su flujo normal de carga
      return jsonb_build_object('ok', true, 'ya_era_mio', true,
        'pedido_id', p.id, 'codigo', p.codigo, 'comuna', p.comuna,
        'direccion', p.direccion, 'cliente_final', p.cliente_nombre,
        'mensaje', 'Pedido de tu empresa');
    end if;
    select e.nombre into v_dueno from public.empresas_reparto e where e.id = p.empresa_reparto_id;
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Este pedido es de ' || coalesce(v_dueno,'otra empresa') || '. No lo cargues.');
  end if;

  -- ---------- está en el pool: ¿lo puedo reclamar? ----------
  if p.estado in ('entregado','cancelado') then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Ese pedido ya está ' || p.estado || '.');
  end if;

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

  -- ---------- reclamarlo ----------
  -- Un solo UPDATE con "empresa_reparto_id is null": si dos repartidores
  -- de empresas distintas escanean la misma etiqueta en el mismo segundo,
  -- la base deja pasar a uno solo.
  update public.pedidos q
     set empresa_reparto_id  = v_emp,
         repartidor_id       = v_uid,
         tomado_por          = v_uid,
         tomado_en           = now(),
         estado              = case when q.estado = 'pendiente' then 'asignado' else q.estado end,
         vence_asignacion_en = null,
         asignacion_motivo   = 'lo cargó ' || coalesce(v_nombre,'un repartidor') || ' al escanearlo'
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

  insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id, nota)
  values (p.id, v_emp, 'tomado', v_uid, 'reclamado al escanear la etiqueta');

  return jsonb_build_object('ok', true, 'ya_era_mio', false,
    'pedido_id', p.id, 'codigo', p.codigo, 'comuna', p.comuna,
    'direccion', p.direccion, 'cliente_final', p.cliente_nombre,
    'mensaje', 'Lo tomaste del pool: ya es tuyo');
end $$;

grant execute on function public.reclamar_pedido(text, text, text) to authenticated;


-- ============================================================
-- El repartidor tiene que poder ver el pedido que acaba de reclamar.
-- La política de siempre ya lo cubre (repartidor_id = él), porque el
-- escaneo se lo asigna en el mismo movimiento.
-- ============================================================


-- ============================================================
-- COMPROBACIÓN
-- ============================================================
select proname as funcion_creada
  from pg_proc where proname = 'reclamar_pedido';
