-- ============================================================
-- CANDADOS DE SEGURIDAD DE LA RED  (auditoría 05-08-2026)
--
-- Correr en el SQL Editor. Es seguro repetirlo.
-- Va AL FINAL: después de migracion-permisos.sql (archivo 11+).
--
-- QUÉ CIERRA (cada punto salió de la auditoría del 05-08):
--   1. Un admin de una empresa arrendataria podía fabricarse una cuenta
--      de portal apuntando a CUALQUIER cliente de la red y ver todos sus
--      pedidos, historial y fotos. Ahora solo puede crear portal para
--      clientes con vínculo ACTIVO con su propia empresa.
--   2. tomar_pedidos (el pool viejo) seguía ejecutable: un pedido tomado
--      por ahí volvía SOLO al pool a las 2 horas aunque el bulto ya
--      estuviera cargado. Se revoca. (devolver_pedidos NO se toca:
--      el botón "Soltar el pedido" del modelo nuevo la usa.)
--   3. liberar_vencidos la podía disparar cualquier cuenta, hasta un
--      portal. Ahora solo hace algo para el superadmin (para los demás
--      devuelve 0 sin tocar nada, así el panel viejo no se rompe).
--   4. El cliente podía activar un vínculo sin que la empresa aceptara
--      (pendiente → rechazada → activa saltaba la guardia).
--   5. Un REPARTIDOR podía descargar la cartera completa de su empresa
--      (teléfonos, direcciones, RUT, fotos) llamando reporte_periodo /
--      uso_fotos por consola. Ahora exigen ser admin.
--   6. Faltaban índices para el escaneo en bodega (envio_id, externo_id):
--      cada escaneo hacía 2 lecturas completas de la tabla.
-- ============================================================


-- ============================================================
-- 1. NADIE SE FABRICA UN PORTAL AJENO NI SE CAMBIA DE EMPRESA
--
-- Se amplía fn_frenar_permisos (de migracion-permisos.sql): ahora
-- cliente_id y empresa_reparto_id también son campos vigilados, y el
-- trigger corre en INSERT además de UPDATE.
--
-- Reglas nuevas para un admin común (el superadmin puede todo):
--   · empresa_reparto_id: o queda suelta (null) o es LA SUYA.
--   · cliente_id: solo clientes con vínculo estado='activa' con su
--     empresa. Esto deja intacto el flujo real del panel (crear acceso
--     de portal desde la ficha del cliente) y bloquea el ataque.
-- ============================================================
create or replace function public.fn_frenar_permisos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  yo record;
  v_cliente_antes bigint;
  v_empresa_antes bigint;
begin
  if auth.uid() is null then return new; end if;   -- backend / migraciones

  if tg_op = 'UPDATE' then
    v_cliente_antes := old.cliente_id;
    v_empresa_antes := old.empresa_reparto_id;
    if new.puede_panel          is not distinct from old.puede_panel
       and new.puede_app        is not distinct from old.puede_app
       and new.puede_asignar    is not distinct from old.puede_asignar
       and new.rol              is not distinct from old.rol
       and new.superadmin       is not distinct from old.superadmin
       and new.cliente_id       is not distinct from old.cliente_id
       and new.empresa_reparto_id is not distinct from old.empresa_reparto_id
    then
      return new;                                  -- no se tocó nada sensible
    end if;
  end if;

  select pf.rol, pf.superadmin, pf.empresa_reparto_id into yo
    from public.perfiles pf where pf.id = auth.uid() and pf.activo;

  if yo.superadmin then return new; end if;        -- el dueño de la red puede todo

  if yo.rol is distinct from 'admin' then
    raise exception 'Solo un administrador puede cambiar los permisos de una cuenta.';
  end if;

  -- un admin manda sobre su propia empresa (y sobre las cuentas sueltas)
  if tg_op = 'UPDATE'
     and old.empresa_reparto_id is not null
     and old.empresa_reparto_id is distinct from yo.empresa_reparto_id then
    raise exception 'Esa cuenta es de otra empresa.';
  end if;

  if (tg_op = 'UPDATE' and new.superadmin is distinct from old.superadmin)
     or (tg_op = 'INSERT' and new.superadmin) then
    raise exception 'Solo el administrador de la red puede tocar el superadmin.';
  end if;

  -- 🔒 la empresa de una cuenta: o suelta, o LA MÍA
  if new.empresa_reparto_id is distinct from v_empresa_antes
     and new.empresa_reparto_id is not null
     and new.empresa_reparto_id is distinct from yo.empresa_reparto_id then
    raise exception 'Una cuenta solo se puede sumar a tu propia empresa.';
  end if;

  -- 🔒 portal de cliente: solo para clientes que trabajan CON MI empresa
  if new.cliente_id is distinct from v_cliente_antes
     and new.cliente_id is not null
     and not exists (select 1 from public.cliente_empresas ce
                      where ce.cliente_id         = new.cliente_id
                        and ce.empresa_reparto_id = yo.empresa_reparto_id
                        and ce.estado             = 'activa') then
    raise exception 'Solo puedes crear acceso de portal para un cliente vinculado a tu empresa.';
  end if;

  return new;
end $$;

drop trigger if exists tr_frenar_permisos on public.perfiles;
create trigger tr_frenar_permisos
  before insert or update on public.perfiles
  for each row execute function public.fn_frenar_permisos();


-- ============================================================
-- 2. EL POOL VIEJO DEJA DE SER EJECUTABLE
--    (las funciones quedan por si hay que mirar historia, pero nadie
--     las puede llamar: ni el panel ni una consola de navegador)
-- ============================================================
revoke execute on function public.tomar_pedidos(bigint[]) from public, anon, authenticated;

-- y de paso: ningún pedido queda con el reloj viejo corriendo
update public.pedidos
   set vence_asignacion_en = null
 where vence_asignacion_en is not null;


-- ============================================================
-- 3. liberar_vencidos: SOLO EL SUPERADMIN
--    Para cualquier otra cuenta devuelve 0 sin tocar nada (así los
--    paneles viejos que todavía la llaman no ven ningún error).
-- ============================================================
create or replace function public.liberar_vencidos()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if auth.uid() is not null and not public.es_superadmin() then
    return 0;                                      -- 🔒 no-op silencioso
  end if;
  with vencidos as (
    select p.id, p.empresa_reparto_id
      from public.pedidos p
     where p.vence_asignacion_en is not null
       and p.vence_asignacion_en < now()
       and p.empresa_reparto_id is not null
       and p.repartidor_id is null
       and p.estado = 'pendiente'
       and p.cliente_id is not null
       and p.tomado_por is not null
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
-- 4. LA GUARDIA DEL VÍNCULO YA NO SE SALTA EN DOS PASOS
--    Antes: el cliente no podía pasar pendiente→activa… pero sí
--    pendiente→rechazada y después rechazada→activa. Ahora TODO paso
--    a 'activa' de una solicitud hecha por el cliente lo tiene que
--    dar la empresa (responder_vinculo).
-- ============================================================
create or replace function public.fn_cliente_empresas_guardia()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_soy_cliente boolean;
begin
  if auth.uid() is null then return new; end if;
  if coalesce(current_setting('zas.vinculo', true), '') = '1' then return new; end if;
  if public.es_superadmin() then return new; end if;
  v_soy_cliente := public.cliente_de_usuario() is not null
                   and public.cliente_de_usuario() = new.cliente_id;

  if tg_op = 'INSERT' then
    if v_soy_cliente then
      new.estado := 'pendiente';
      new.solicitado_por := 'cliente';
      new.solicitado_por_usuario := auth.uid();
      new.respondido_en := null;
    end if;
    return new;
  end if;

  -- UPDATE
  if not v_soy_cliente then
    -- una empresa solo puede pausar o despausar SU fila
    if new.cliente_id       is distinct from old.cliente_id
    or new.empresa_reparto_id is distinct from old.empresa_reparto_id
    or new.estado           is distinct from old.estado
    or new.comunas          is distinct from old.comunas
    or new.cuota_diaria     is distinct from old.cuota_diaria
    or new.porcentaje       is distinct from old.porcentaje
    or new.prioridad        is distinct from old.prioridad then
      raise exception 'Las reglas de reparto las define el cliente';
    end if;
  else
    -- 🔒 lo que pidió el cliente solo lo puede ACTIVAR la empresa,
    --    venga del estado que venga (antes solo frenaba desde 'pendiente')
    if new.estado = 'activa'
       and old.estado is distinct from 'activa'
       and old.solicitado_por = 'cliente' then
      raise exception 'Esa invitación la tiene que aceptar la empresa';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_cliente_empresas_guardia on public.cliente_empresas;
create trigger trg_cliente_empresas_guardia
before insert or update on public.cliente_empresas
for each row execute function public.fn_cliente_empresas_guardia();


-- ============================================================
-- 5. LOS REPORTES CON DATOS PERSONALES SON SOLO PARA ADMINS
--    (mismo cuerpo que migracion-archivo-fotos.sql + "and es_admin()":
--     para un repartidor devuelven vacío, sin error)
-- ============================================================
create or replace function public.reporte_periodo(p_desde date, p_hasta date)
returns table (
  pedido_id      bigint,
  n_envio        text,
  codigo         text,
  cliente        text,
  cliente_final  text,
  telefono       text,
  direccion      text,
  comuna         text,
  repartidor     text,
  estado         text,
  fecha_pedido   date,
  entregado_en   timestamptz,
  recibio        text,
  rut_recibe     text,
  motivo_no_entrega text,
  nota_entrega   text,
  foto_domicilio text,
  foto_pedido    text,
  foto_receptor  text,
  foto_extra     text)
language sql stable security definer set search_path = public as $$
  select p.id,
         coalesce(nullif(p.envio_id,''), replace(coalesce(p.externo_id,''),'ML-',''), p.codigo),
         p.codigo,
         c.nombre,
         p.cliente_nombre,
         p.cliente_telefono,
         p.direccion,
         p.comuna,
         pf.nombre,
         p.estado,
         p.fecha_pedido,
         p.entregado_en,
         e.nombre_recibe,
         e.rut_recibe,
         p.motivo_no_entrega,
         p.nota_entrega,
         e.foto_domicilio, e.foto_pedido, e.foto_receptor, e.foto_url
    from public.pedidos p
    left join public.clientes  c  on c.id  = p.cliente_id
    left join public.perfiles  pf on pf.id = p.repartidor_id
    left join lateral (
      select * from public.entregas_prueba x
       where x.pedido_id = p.id
       order by x.creado_en desc limit 1) e on true
   where p.fecha_pedido between p_desde and p_hasta
     and p.empresa_reparto_id = public.mi_empresa_reparto()
     and public.es_admin()                          -- 🔒
   order by p.fecha_pedido, p.id;
$$;

create or replace function public.uso_fotos()
returns table (
  mes            text,
  pedidos        bigint,
  fotos          bigint,
  mb_estimados   numeric,
  respaldado     boolean,
  borrable       boolean)
language sql stable security definer set search_path = public as $$
  with base as (
    select to_char(p.fecha_pedido,'YYYY-MM')                      as mes,
           min(p.fecha_pedido)                                    as desde,
           max(p.fecha_pedido)                                    as hasta,
           count(*)                                               as pedidos,
           count(e.foto_domicilio) + count(e.foto_pedido)
             + count(e.foto_receptor) + count(e.foto_url)         as fotos
      from public.pedidos p
      left join public.entregas_prueba e on e.pedido_id = p.id
     where p.empresa_reparto_id = public.mi_empresa_reparto()
       and public.es_admin()                                      -- 🔒
     group by 1)
  select b.mes, b.pedidos, b.fotos,
         round(b.fotos * 180.0 / 1024, 1),
         exists (select 1 from public.archivos_periodo a
                  where a.empresa_reparto_id = public.mi_empresa_reparto()
                    and a.desde <= b.desde and a.hasta >= b.hasta),
         (b.hasta < current_date - 90)
           and exists (select 1 from public.archivos_periodo a
                        where a.empresa_reparto_id = public.mi_empresa_reparto()
                          and a.desde <= b.desde and a.hasta >= b.hasta)
    from base b
   order by b.mes desc;
$$;


-- ============================================================
-- 6. ÍNDICES PARA EL ESCANEO EN BODEGA
-- ============================================================
create index if not exists idx_pedidos_envio_id
  on public.pedidos (envio_id) where envio_id is not null;
create index if not exists idx_pedidos_externo_solo
  on public.pedidos (externo_id) where externo_id is not null;


-- ============================================================
-- COMPROBACIÓN — mirá esto al terminar
-- ============================================================
select
  (select count(*) from pg_trigger
    where tgname = 'tr_frenar_permisos')                          as guardia_perfiles,   -- 1
  (select not has_function_privilege('authenticated',
          'public.tomar_pedidos(bigint[])', 'execute'))           as pool_viejo_cerrado, -- true
  (select count(*) from public.pedidos
    where vence_asignacion_en is not null)                        as relojes_viejos,     -- 0
  (select count(*) from pg_indexes
    where indexname in ('idx_pedidos_envio_id',
                        'idx_pedidos_externo_solo'))              as indices_escaneo;    -- 2
