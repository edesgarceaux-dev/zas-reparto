-- ============================================================
--  MIGRACIÓN — Fotos de entrega PRIVADAS (Tanda B)
--
--  Problema: el bucket 'entregas' es PÚBLICO. Las fotos son prueba de
--  entrega (caras, fachadas, RUT): cualquiera con el link las ve.
--
--  Solución: bucket privado + URLs FIRMADAS (temporales). Quién puede
--  firmar (=ver) una foto se decide con UNA sola regla, sin duplicar
--  lógica: podés firmar la foto de un pedido SOLO si podés VER ese pedido.
--  El EXISTS a public.pedidos hereda el RLS de pedidos por usuario
--  (admin ve todo, empresa ve lo suyo, repartidor lo asignado). Probado
--  en PG16: el RLS de la tabla referida se aplica dentro de la policy.
--
--  Rutas de las fotos: SIEMPRE '<pedido_id>/<slot>_<algo>.jpg' (así en
--  todas las versiones de la app desde la v2.1), por eso el primer tramo
--  del nombre es el id del pedido.
--
--  La app NO cambia: sigue subiendo igual (la policy de INSERT no depende
--  de que el bucket sea público) y guarda la misma URL; el panel saca la
--  ruta de esa URL y pide una URL firmada. Los datos viejos siguen
--  sirviendo sin tocar ni una fila.
--
--  Idempotente. Requiere: public.pedidos y public.es_admin() ya existentes.
--  ORDEN: correr esta migración es lo ÚLTIMO; ANTES publicar el panel nuevo
--  (que ya sabe firmar). Mientras el panel viejo siga arriba, ver más abajo.
-- ============================================================

begin;

-- 1) Bucket privado. (No-op si el bucket todavía no existe.)
update storage.buckets set public = false where id = 'entregas';

-- 2) Policy de LECTURA/FIRMA: firmar una foto de 'entregas' solo si el
--    usuario autenticado puede ver el pedido dueño de la foto.
--    El EXISTS corre con el RLS de pedidos del propio usuario.
drop policy if exists entregas_ver_firmar on storage.objects;
create policy entregas_ver_firmar
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'entregas'
    and exists (
      select 1
      from public.pedidos pe
      -- primer tramo del nombre = id del pedido; limpio no-dígitos por las
      -- dudas y uso nullif para no reventar el cast si viniera vacío.
      where pe.id = nullif(regexp_replace(split_part(name, '/', 1), '\D', '', 'g'), '')::bigint
    )
  );

commit;

-- ------------------------------------------------------------
-- 3) REVISIÓN MANUAL (no borra nada): lista las policies de storage.objects.
--    Si aparece alguna de SELECT para el rol 'anon' o 'public' que deje leer
--    'entregas', HAY QUE BORRARLA (si no, el bucket privado no sirve de nada
--    porque esa policy seguiría dando lectura pública). NO borres la de
--    INSERT (la usa la app para subir) ni la de DELETE (es_admin, respaldo).
-- ------------------------------------------------------------
do $$
declare r record;
begin
  raise notice '--- Policies actuales en storage.objects ---';
  for r in
    select polname,
           case polcmd when 'r' then 'SELECT' when 'a' then 'INSERT'
                       when 'w' then 'UPDATE' when 'd' then 'DELETE'
                       else polcmd::text end as cmd,
           coalesce((select string_agg(rolname, ',')
                     from pg_roles where oid = any(polroles)), 'PUBLIC') as roles
    from pg_policy
    where polrelid = 'storage.objects'::regclass
    order by 2, 1
  loop
    raise notice '  [%] % → roles: %', r.cmd, r.polname, r.roles;
  end loop;
  raise notice '--- Si ves una policy SELECT con rol anon/PUBLIC que toque entregas, borrala a mano. ---';
end $$;

-- ------------------------------------------------------------
-- Verificación rápida:
--   select id, public from storage.buckets where id='entregas';           -- public = false
--   select polname from pg_policy where polrelid='storage.objects'::regclass
--     and polname='entregas_ver_firmar';                                   -- existe
-- ------------------------------------------------------------
