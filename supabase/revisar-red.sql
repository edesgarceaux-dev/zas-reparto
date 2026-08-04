-- ============================================================
-- REVISAR CÓMO QUEDÓ LA RED  (solo mira, no cambia nada)
-- Supabase → SQL Editor → New query → pegar TODO → Run
-- Son 3 consultas; mirá las 3 pestañas de resultados.
-- La columna DIAGNOSTICO te dice en castellano qué está mal.
-- ============================================================

-- ---------- 1) LAS CUENTAS ----------
-- Acá se ve si el admin de la empresa nueva quedó suelto.
select coalesce(u.email, '(sin correo)')                as cuenta,
       p.nombre,
       p.rol,
       case when p.superadmin then 'sí' else '' end     as es_dueño,
       coalesce(e.nombre, '— NINGUNA —')                as empresa_de_reparto,
       coalesce(c.nombre, '—')                          as portal_del_cliente,
       case
         when not p.activo
           then '⚠️ Cuenta desactivada: no puede entrar'
         when p.superadmin
           then 'OK · dueño del sistema, ve todo'
         when p.rol = 'empresa' and p.cliente_id is null
           then '⚠️ Portal de cliente SIN cliente asignado'
         when p.rol = 'empresa'
           then 'OK · portal del cliente'
         when p.rol in ('admin','repartidor') and p.empresa_reparto_id is null
           then '⚠️ ACÁ ESTÁ EL PROBLEMA: no pertenece a ninguna empresa de reparto, por eso no ve nada'
         when p.rol = 'admin'
           then 'OK · administra su empresa'
         else 'OK · repartidor'
       end                                              as diagnostico
  from public.perfiles p
  left join auth.users              u on u.id = p.id
  left join public.empresas_reparto e on e.id = p.empresa_reparto_id
  left join public.clientes         c on c.id = p.cliente_id
 order by p.superadmin desc, p.empresa_reparto_id nulls first, p.creado_en;


-- ---------- 2) LOS VÍNCULOS (las invitaciones) ----------
select c.nombre                                          as cliente,
       e.nombre                                          as empresa,
       ce.estado,
       ce.solicitado_por,
       case when ce.activo then '' else 'en pausa' end   as pausa,
       ce.solicitado_en,
       case
         when ce.estado = 'activa' and ce.activo
           then 'OK · le está repartiendo'
         when ce.estado = 'activa'
           then 'El cliente la puso en pausa'
         when ce.estado = 'pendiente' and ce.solicitado_por = 'cliente'
           then '⏳ La mandó el CLIENTE: la tiene que aceptar la EMPRESA (pestaña Clientes de su panel)'
         when ce.estado = 'pendiente' and ce.solicitado_por = 'empresa'
           then '⏳ La mandó la EMPRESA: la tiene que aceptar el CLIENTE (su portal)'
         when ce.estado = 'rechazada'
           then 'Rechazada'
         else ce.estado
       end                                               as diagnostico
  from public.cliente_empresas ce
  left join public.clientes         c on c.id = ce.cliente_id
  left join public.empresas_reparto e on e.id = ce.empresa_reparto_id
 order by ce.solicitado_en desc nulls last;


-- ---------- 3) LAS EMPRESAS Y SI TIENEN QUIÉN LAS MANEJE ----------
select e.id,
       e.nombre,
       e.plan,
       case when e.activo then 'sí' else 'NO' end        as activa,
       (select count(*) from public.perfiles p
         where p.empresa_reparto_id = e.id and p.rol = 'admin')      as admins,
       (select count(*) from public.perfiles p
         where p.empresa_reparto_id = e.id and p.rol = 'repartidor') as repartidores,
       (select count(*) from public.cliente_empresas ce
         where ce.empresa_reparto_id = e.id and ce.estado = 'activa') as clientes_activos,
       case
         when not exists (select 1 from public.perfiles p
                           where p.empresa_reparto_id = e.id and p.rol = 'admin')
           then '⚠️ No tiene ningún administrador: nadie puede entrar a manejarla'
         else 'OK'
       end                                               as diagnostico
  from public.empresas_reparto e
 order by e.id;
