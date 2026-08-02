-- ============================================================
-- APLICACION ZAS - Migración: seguimiento online público
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================

-- Código secreto del link de seguimiento (nadie puede adivinarlo)
alter table public.pedidos add column token_seguimiento text
  default substr(md5(random()::text || clock_timestamp()::text), 1, 10);

-- Generarlo para los pedidos ya existentes
update public.pedidos
set token_seguimiento = substr(md5(random()::text || clock_timestamp()::text || id::text), 1, 10)
where token_seguimiento is null;

-- Consulta pública: SOLO entrega datos si el código y el token coinciden.
-- No expone monto, teléfono completo del sistema, ni nada más de la base.
create or replace function public.seguimiento_publico(cod text, tok text)
returns json language sql stable security definer as $$
  select json_build_object(
    'codigo', p.codigo,
    'estado', p.estado,
    'direccion', p.direccion,
    'comuna', p.comuna,
    'cliente', split_part(p.cliente_nombre, ' ', 1),
    'empresa', c.nombre,
    'fecha_despacho', p.fecha_pedido,
    'creado_en', p.creado_en,
    'asignado_en', p.asignado_en,
    'entregado_en', p.entregado_en,
    'nota', case when p.estado in ('entregado','no_entregado') then p.nota_entrega end,
    'repartidor', split_part(coalesce(pf.nombre,''), ' ', 1),
    'dest_lat', p.lat, 'dest_lng', p.lng,
    'rep_lat', case when p.estado = 'en_camino' then u.lat end,
    'rep_lng', case when p.estado = 'en_camino' then u.lng end,
    'rep_actualizado', case when p.estado = 'en_camino' then u.actualizado_en end,
    'historial', (
      select json_agg(json_build_object('estado', h.estado, 'en', h.creado_en) order by h.creado_en)
      from public.pedido_historial h where h.pedido_id = p.id
    )
  )
  from public.pedidos p
  left join public.clientes c on c.id = p.cliente_id
  left join public.perfiles pf on pf.id = p.repartidor_id
  left join public.ubicaciones u on u.repartidor_id = p.repartidor_id
  where p.codigo = cod and p.token_seguimiento = tok;
$$;

grant execute on function public.seguimiento_publico(text, text) to anon;
