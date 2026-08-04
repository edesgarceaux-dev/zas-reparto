-- ============================================================
-- QUIÉN ENTRA AL PANEL Y QUIÉN A LA APP
--
-- Correr en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-asignar-por-qr.sql.
--
-- QUÉ RESUELVE
-- ------------
-- Hasta ahora, cualquier cuenta activa de tu empresa podía entrar al panel
-- web y ver la vista de repartidor ahí adentro. No todos tienen que poder.
-- Ahora cada persona tiene tres interruptores, que se prenden y apagan
-- desde el panel, en Repartidores → Editar:
--
--   🖥️  puede_panel   → entra al panel web con su cuenta
--   📱  puede_app     → entra a la APK de reparto
--   📲  puede_asignar → dentro de la app, puede asignar bultos por QR
--
-- CÓMO ARRANCAN
-- -------------
--   · admin        → panel SÍ · app SÍ · asignar SÍ
--   · repartidor   → panel NO · app SÍ · asignar NO
--   · cliente      → su portal SÍ (no lo toca esto) · app NO
--
-- Es decir: tus repartidores dejan de poder entrar al panel web, y todo lo
-- demás sigue igual. Si querés que alguno entre, se lo prendés vos.
--
-- HASTA DÓNDE LLEGA
-- -----------------
-- Estos interruptores son la PUERTA: deciden a qué pantalla entra cada uno.
-- Lo que cada cuenta puede LEER y ESCRIBIR ya está cerrado aparte, en las
-- políticas de la base (RLS): un repartidor solo ve sus propios pedidos aunque
-- se meta por donde se meta. Esto no reemplaza aquello, lo ordena.
-- ============================================================


-- ============================================================
-- 1. LOS DOS INTERRUPTORES NUEVOS
-- ============================================================
alter table public.perfiles
  add column if not exists puede_panel boolean not null default false;
alter table public.perfiles
  add column if not exists puede_app   boolean not null default true;

comment on column public.perfiles.puede_panel is
  'Deja entrar al panel web con esta cuenta. Los repartidores arrancan en false: solo la app.';
comment on column public.perfiles.puede_app is
  'Deja entrar a la APK de reparto con esta cuenta.';


-- ============================================================
-- 2. VALORES DE ARRANQUE
--
-- Solo se tocan las cuentas que todavía están en el valor de fábrica, así
-- que correr esto de nuevo NO pisa lo que vos hayas configurado a mano.
-- El control es la columna permisos_puestos: se marca la primera vez.
-- ============================================================
alter table public.perfiles
  add column if not exists permisos_puestos boolean not null default false;

update public.perfiles
   set puede_panel = (rol in ('admin','empresa')),
       puede_app   = (rol in ('admin','repartidor')),
       permisos_puestos = true
 where permisos_puestos = false;


-- ============================================================
-- 3. NADIE SE PUEDE AUTOASCENDER
--
-- La primera cerradura ya la pusieron las políticas de la base: un
-- repartidor solo puede LEER su ficha, no escribirla, así que aunque se
-- meta por la consola del navegador no se puede prender nada.
--
-- Esta es la segunda cerradura, por si alguna vez alguien afloja aquella:
-- tocar rol, superadmin o cualquiera de los tres permisos solo lo puede
-- hacer un administrador. Está escrita para permitir exactamente lo mismo
-- que las políticas —ni un poco menos— así que no puede trabar nada que
-- hoy funcione.
-- ============================================================
create or replace function public.fn_frenar_permisos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  yo record;
begin
  if auth.uid() is null then return new; end if;   -- backend / migraciones

  if new.puede_panel      is not distinct from old.puede_panel
     and new.puede_app    is not distinct from old.puede_app
     and new.puede_asignar is not distinct from old.puede_asignar
     and new.rol          is not distinct from old.rol
     and new.superadmin   is not distinct from old.superadmin
  then
    return new;                                    -- no se tocó nada sensible
  end if;

  select pf.rol, pf.superadmin, pf.empresa_reparto_id into yo
    from public.perfiles pf where pf.id = auth.uid() and pf.activo;

  if yo.superadmin then return new; end if;        -- el dueño de la red puede todo

  if yo.rol is distinct from 'admin' then
    raise exception 'Solo un administrador puede cambiar los permisos de una cuenta.';
  end if;

  -- un admin manda sobre su propia empresa (y sobre las cuentas sueltas,
  -- que es como nacen antes de quedar asignadas)
  if old.empresa_reparto_id is not null
     and old.empresa_reparto_id is distinct from yo.empresa_reparto_id then
    raise exception 'Esa cuenta es de otra empresa.';
  end if;

  if new.superadmin is distinct from old.superadmin then
    raise exception 'Solo el administrador de la red puede tocar el superadmin.';
  end if;

  return new;
end $$;

drop trigger if exists tr_frenar_permisos on public.perfiles;
create trigger tr_frenar_permisos
  before update on public.perfiles
  for each row execute function public.fn_frenar_permisos();


-- ============================================================
-- COMPROBACIÓN — mirá esta tabla al terminar
-- ============================================================
select rol,
       count(*)                                as cuentas,
       count(*) filter (where puede_panel)     as entran_al_panel,
       count(*) filter (where puede_app)       as entran_a_la_app,
       count(*) filter (where puede_asignar)   as pueden_asignar
  from public.perfiles
 where activo
 group by rol
 order by rol;
-- Lo esperable:
--   admin       → entran al panel = todos · a la app = todos · asignan = todos
--   repartidor  → entran al panel = 0     · a la app = todos · asignan = 0
--   empresa     → entran al panel = todos (es su portal de cliente) · app = 0
