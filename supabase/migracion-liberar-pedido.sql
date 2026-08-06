-- ============================================================
-- LIBERAR UN PEDIDO  (procedimiento simple, 06-08-2026)
--
-- Correr en el SQL Editor. Seguro repetirlo. Va después de las demás.
--
-- QUÉ RESUELVE
-- -----------
-- El "Soltar el pedido" viejo (devolver_pedidos) solo funcionaba si el
-- cliente trabajaba con 2+ empresas; si el cliente era solo tuyo, se negaba
-- ("no hay pool donde devolverlo"). Por eso los pedidos "no volvían a la
-- cola". Ahora LIBERAR siempre deja el pedido en "Sin asignar":
--   · le quita el repartidor y el orden de ruta,
--   · lo vuelve a 'pendiente',
--   · si el cliente reparte en modo ABIERTO con 2+ empresas, además lo
--     suelta de la empresa (empresa_reparto_id = null) para que cualquiera
--     lo pueda volver a tomar; si es un cliente tuyo, se queda en tu
--     empresa, sin repartidor, listo para asignárselo a otro.
--   · descarta cualquier "previsto" (plan_reparto) que tuviera.
-- Lo puede hacer el admin de la empresa dueña (o el superadmin), sobre
-- pedidos pendiente/asignado/en_camino (los ya entregados/cancelados no).
-- ============================================================
create or replace function public.liberar_pedido(p_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_emp       bigint;
  v_liberados bigint[];
  v_rechaza   jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede liberar pedidos';
  end if;
  v_emp := public.mi_empresa_reparto();
  if v_emp is null and not public.es_superadmin() then
    raise exception 'Tu cuenta no pertenece a ninguna empresa de reparto';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    return jsonb_build_object('liberados', 0, 'ids', '[]'::jsonb, 'no_pudo', '[]'::jsonb);
  end if;

  with upd as (
    update public.pedidos p
       set repartidor_id = null,
           ruta_orden    = null,
           estado        = 'pendiente',
           -- se suelta de la empresa solo si el cliente reparte abierto con 2+ empresas
           empresa_reparto_id = case
             when (select c.modo_reparto from public.clientes c where c.id = p.cliente_id) = 'abierto'
              and (select count(*) from public.cliente_empresas ce
                    where ce.cliente_id = p.cliente_id and ce.activo and ce.estado = 'activa') >= 2
             then null
             else p.empresa_reparto_id
           end,
           tomado_en          = null,
           tomado_por         = null,
           vence_asignacion_en = null,
           asignacion_motivo  = 'liberado: vuelve a sin asignar'
     where p.id = any(p_ids)
       and (public.es_superadmin() or p.empresa_reparto_id = v_emp)
       and p.estado in ('pendiente','asignado','en_camino')
    returning p.id
  )
  select coalesce(array_agg(id), '{}') into v_liberados from upd;

  -- descartar los "previstos" de esos pedidos (si la tabla existe)
  begin
    delete from public.plan_reparto where pedido_id = any(v_liberados);
  exception when undefined_table then null; end;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'motivo', case
             when p.id is null then 'ya no existe'
             when p.empresa_reparto_id is distinct from v_emp and not public.es_superadmin() then 'no es de tu empresa'
             when p.estado not in ('pendiente','asignado','en_camino') then 'ya está ' || p.estado || ', no se puede liberar'
             else 'no se pudo'
           end)), '[]'::jsonb)
    into v_rechaza
    from unnest(p_ids) as x(id)
    left join public.pedidos p on p.id = x.id
   where not (x.id = any(v_liberados));

  return jsonb_build_object(
    'liberados', coalesce(array_length(v_liberados,1), 0),
    'ids',       to_jsonb(v_liberados),
    'no_pudo',   v_rechaza);
end $$;

grant execute on function public.liberar_pedido(bigint[]) to authenticated;
