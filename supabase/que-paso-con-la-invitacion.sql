-- ============================================================
-- ¿QUÉ PASÓ CON LA INVITACIÓN?
--
-- Pegá esto entero en el SQL Editor y apretá Run. Es UNA sola consulta.
-- No cambia nada.
--
-- Te devuelve, para cada vínculo cliente ↔ empresa de reparto:
--   · en qué estado quedó,
--   · quién tiene que aceptarlo,
--   · y CON QUÉ CORREO hay que entrar para verlo.
--
-- Ojo: una invitación NO se ve desde el panel de otra empresa. Si la
-- mandaste a "Empresa Nueva", hay que entrar con el correo del admin de
-- Empresa Nueva. Desde el panel maestro (Clientes de la red) las ves
-- todas, sea de quien sea.
-- ============================================================

select
  coalesce(c.nombre, '(cliente borrado)')                    as cliente,
  coalesce(e.nombre, '(empresa borrada)')                    as empresa,
  ce.estado,
  case
    when ce.estado = 'activa'    then 'ya está andando, no falta nadie'
    when ce.estado = 'rechazada' then 'fue rechazada'
    when ce.solicitado_por = 'cliente' then 'LA EMPRESA: ' || coalesce(e.nombre,'?')
    when ce.solicitado_por = 'empresa' then 'EL CLIENTE: ' || coalesce(c.nombre,'?')
    else 'nadie'
  end                                                        as quien_tiene_que_aceptar,
  case
    when ce.estado <> 'pendiente' then '—'
    when ce.solicitado_por = 'cliente' then
      'Panel de empresa → pestaña CLIENTES, entrando con: ' ||
      coalesce((select string_agg(u.email, ' o ')
                  from public.perfiles p join auth.users u on u.id = p.id
                 where p.empresa_reparto_id = e.id and p.rol = 'admin' and p.activo),
               '⚠️ NADIE — esa empresa no tiene ninguna cuenta de administrador')
    else
      'Portal del cliente → MIS EMPRESAS DE REPARTO, entrando con: ' ||
      coalesce((select string_agg(u.email, ' o ')
                  from public.perfiles p join auth.users u on u.id = p.id
                 where p.cliente_id = c.id and p.rol = 'empresa' and p.activo),
               '⚠️ NADIE — ese cliente no tiene cuenta de portal')
  end                                                        as donde_y_con_que_correo,
  ce.solicitado_en

from public.cliente_empresas ce
left join public.clientes         c on c.id = ce.cliente_id
left join public.empresas_reparto e on e.id = ce.empresa_reparto_id

union all

select '—', '—', 'NO HAY NINGUNA',
       'La invitación que mandaste no quedó guardada',
       'Volvé a mandarla desde el portal del cliente y avisame si tira algún error',
       null
 where not exists (select 1 from public.cliente_empresas)

order by 3, 6 desc nulls last;
