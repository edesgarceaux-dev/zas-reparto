-- ============================================================
-- ASIGNAR ES QUEDÁRSELO
--
-- Correr en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-comunas-alias.sql.
--
-- QUÉ PASABA
-- ----------
-- Antes de sumar otras empresas de reparto, asignar un pedido era una sola
-- cosa: le escribías el repartidor y listo. El repartidor lo veía en su
-- teléfono, la ruta se ordenaba sola, el mapa lo dibujaba.
--
-- Con la red apareció el pedido COMPARTIDO: uno que todavía no es de nadie
-- porque el cliente habilitó a más de una empresa. A un pedido así no se le
-- puede escribir el repartidor encima —sería pisarle el pedido a la otra
-- empresa—, así que el panel guardaba una INTENCIÓN en `plan_reparto`: eso
-- es el famoso «previsto». El pedido recién pasaba a ser tuyo cuando alguien
-- lo escaneaba en bodega.
--
-- El problema es que entre «asignado» y «escaneado» hay horas, y en el medio
-- el pedido está en tierra de nadie:
--   · su repartidor vive en `plan_reparto`, no en `pedidos`
--   · su orden de ruta también
--   · el mapa, los contadores y la app tienen que ir a buscarlo a otro lado
--   · y cualquier arreglo hay que hacerlo dos veces, una por cada lado
-- De ahí salieron, uno atrás de otro: el mapa vacío, «0 activos», el orden
-- de ruta que se perdía, el «previsto» que no se iba al desasignar.
--
-- QUÉ HACE ESTO
-- -------------
-- Le da al panel una forma de asignar EN FIRME: en una sola operación el
-- pedido pasa a ser de tu empresa Y queda a nombre del repartidor, con su
-- posición de ruta escrita en `pedidos` como toda la vida.
--
-- Desde el momento en que le ponés repartidor, el pedido deja de ser un caso
-- especial: mapa, optimizar ruta, app del repartidor y contadores vuelven a
-- funcionar como funcionaban antes de la red.
--
-- Lo que NO cambia:
--   · Un pedido que las reglas del cliente le dieron a otra empresa sigue
--     siendo intocable.
--   · Un pedido fuera de la zona de cobertura sigue rebotando.
--   · `planificar_pedidos()` sigue existiendo para planificar sin quedárselo
--     (sirve cuando querés dejar armada la ruta y que decida el escaneo).
--   · El tope de «tomados sin repartidor» sigue vigente para tomar_pedidos().
--     Acá no aplica: ese tope existe para que nadie acapare el pool dejando
--     pedidos parados sin repartidor, y esto sale con repartidor puesto.
-- ============================================================


-- ============================================================
-- 1. TOMARLO Y ASIGNARLO DE UNA
--
-- Los ids vienen EN ORDEN DE RUTA: la posición en el arreglo es la parada.
-- ============================================================
create or replace function public.tomar_y_asignar(
  p_ids        bigint[],
  p_repartidor uuid,
  p_nota       text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_emp     bigint;
  v_uid     uuid := auth.uid();
  v_tomados bigint[];
  v_rechaza jsonb;
  v_miemp   text;
  v_rep     text;
begin
  if not public.es_admin() then
    raise exception 'Solo una cuenta de administración puede asignar pedidos';
  end if;

  v_emp := public.mi_empresa_reparto();
  if v_emp is null then
    raise exception 'Tu cuenta no pertenece a ninguna empresa de reparto';
  end if;
  if p_repartidor is null then
    raise exception 'Hay que elegir un repartidor. Para dejar la ruta armada sin quedarte los pedidos está planificar_pedidos()';
  end if;
  if not exists (select 1 from public.perfiles pf
                  where pf.id = p_repartidor and pf.activo
                    and pf.empresa_reparto_id = v_emp) then
    raise exception 'Ese repartidor no es de tu empresa (o está desactivado)';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    return jsonb_build_object('asignados', 0, 'ids', '[]'::jsonb, 'rechazados', '[]'::jsonb);
  end if;

  select e.nombre into v_miemp from public.empresas_reparto e where e.id = v_emp;
  select coalesce(nullif(pf.nombre,''), 'un repartidor') into v_rep
    from public.perfiles pf where pf.id = p_repartidor;

  -- Un solo UPDATE con «empresa_reparto_id is null» adentro: si otra empresa
  -- lo toma en el mismo segundo, la base deja pasar a una sola.
  with pedir as (
    select x.id, x.pos from unnest(p_ids) with ordinality as x(id, pos)
  ), upd as (
    update public.pedidos p
       set empresa_reparto_id  = v_emp,
           repartidor_id       = p_repartidor,
           ruta_orden          = d.pos::int,
           estado              = case when p.estado = 'pendiente' then 'asignado' else p.estado end,
           tomado_por          = v_uid,
           tomado_en           = now(),
           vence_asignacion_en = null,
           asignacion_motivo   = coalesce(p_nota, 'asignado desde el panel a ' || v_rep)
      from pedir d
     where p.id = d.id
       and p.empresa_reparto_id is null                      -- ← la exclusividad
       and p.estado not in ('entregado','cancelado','no_entregado')
       and coalesce(p.zona, 'ok') = 'ok'
       and exists (select 1 from public.cliente_empresas ce
                    where ce.cliente_id = p.cliente_id
                      and ce.empresa_reparto_id = v_emp
                      and ce.activo and ce.estado = 'activa')
    returning p.id
  )
  select coalesce(array_agg(id), '{}') into v_tomados from upd;

  -- avisarles a las empresas que lo tenían planificado que se les fue
  insert into public.avisos_red (empresa_reparto_id, repartidor_id, pedido_id, codigo, tipo, texto)
  select pr.empresa_reparto_id, pr.repartidor_id, p.id, p.codigo, 'perdido',
         'El pedido ' || coalesce(p.codigo, '#' || p.id) ||
         ' (' || coalesce(nullif(p.comuna,''), 'sin comuna') || ') se lo llevó ' ||
         coalesce(v_miemp, 'otra empresa') || ': salió de tu ruta.'
    from public.plan_reparto pr
    join public.pedidos p on p.id = pr.pedido_id
   where pr.pedido_id = any(v_tomados)
     and pr.empresa_reparto_id <> v_emp;

  -- el plan ya no hace falta: el repartidor está escrito en el pedido
  delete from public.plan_reparto where pedido_id = any(v_tomados);

  insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id, nota)
  select unnest(v_tomados), v_emp, 'tomado', v_uid, 'asignado en firme a ' || v_rep;

  -- por qué quedó afuera cada uno de los que no entraron, en castellano
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'motivo', case
             when p.id is null then 'ya no existe'
             when p.empresa_reparto_id = v_emp then 'ya era tuyo'
             when p.empresa_reparto_id is not null then
               'se adelantó ' || coalesce((select e.nombre from public.empresas_reparto e
                                            where e.id = p.empresa_reparto_id), 'otra empresa')
             when p.estado in ('entregado','cancelado','no_entregado') then 'ya está ' || p.estado
             when coalesce(p.zona,'ok') = 'fuera' then 'fuera de la zona de reparto'
             when coalesce(p.zona,'ok') = 'revisar' then 'no trae comuna'
             else 'ese cliente no trabaja con tu empresa'
           end)), '[]'::jsonb)
    into v_rechaza
    from unnest(p_ids) as x(id)
    left join public.pedidos p on p.id = x.id
   where not (x.id = any(v_tomados));

  return jsonb_build_object(
    'asignados',  coalesce(array_length(v_tomados,1), 0),
    'ids',        to_jsonb(v_tomados),
    'rechazados', v_rechaza);
end $$;

grant execute on function public.tomar_y_asignar(bigint[], uuid, text) to authenticated;


-- ============================================================
-- 2. QUE EL PANEL PUEDA ESCRIBIR EL ORDEN DE RUTA
--
-- `pedidos_empresa_rep_update` ya deja al admin tocar lo que es de su
-- empresa, así que el orden de ruta entra sin tocar nada más. Esto es solo
-- una red de seguridad para bases viejas donde la columna no existía.
-- ============================================================
alter table public.pedidos add column if not exists ruta_orden int;


-- ============================================================
-- COMPROBACIÓN — mirá esta tabla al terminar
-- ============================================================
select
  (select count(*) from pg_proc where proname = 'tomar_y_asignar')          as funcion_creada,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='pedidos'
      and column_name='ruta_orden')                                         as columna_orden,
  (select count(*) from public.pedidos
    where empresa_reparto_id is null and estado = 'pendiente')              as compartidos_sin_dueno,
  (select count(*) from public.plan_reparto)                                as previstos_pendientes;
-- `funcion_creada` = 1 y `columna_orden` = 1.
-- `previstos_pendientes` es lo que todavía está en el limbo del «previsto»:
-- a medida que vayas asignando desde el panel, ese número baja solo.
