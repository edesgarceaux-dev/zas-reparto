-- ============================================================
-- REVISAR CÓMO QUEDÓ LA RED
-- Supabase → SQL Editor → New query → pegar → Run
-- Son 3 consultas: mirá las 3 pestañas de resultados.
-- No cambia nada, solo mira.
-- ============================================================

-- 1) ¿Existe la invitación? ¿En qué estado quedó y quién la pidió?
select ce.cliente_id,
       c.nombre                as cliente,
       ce.empresa_reparto_id,
       e.nombre                as empresa,
       ce.estado,                       -- pendiente | activa | rechazada
       ce.solicitado_por,               -- cliente = la mandó el cliente
       ce.activo,
       ce.solicitado_en,
       ce.respondido_en
  from public.cliente_empresas ce
  left join public.clientes           c on c.id = ce.cliente_id
  left join public.empresas_reparto   e on e.id = ce.empresa_reparto_id
 order by ce.solicitado_en desc nulls last;

-- 2) ¿Cada cuenta está donde tiene que estar?
--    El admin de la empresa nueva TIENE que tener empresa_reparto_id.
--    Si le sale NULL, esa es la razón por la que no ve la invitación.
select p.nombre,
       p.correo,
       p.rol,
       p.superadmin,
       p.empresa_reparto_id,
       e.nombre  as empresa_de_reparto,
       p.cliente_id,
       c.nombre  as portal_del_cliente,
       p.activo
  from public.perfiles p
  left join public.empresas_reparto e on e.id = p.empresa_reparto_id
  left join public.clientes         c on c.id = p.cliente_id
 order by p.creado_en;

-- 3) Las empresas que existen hoy
select id, nombre, plan, activo, creado_en
  from public.empresas_reparto
 order by id;
