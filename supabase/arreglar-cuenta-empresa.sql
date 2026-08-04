-- ============================================================
-- ARREGLAR UNA CUENTA QUE QUEDÓ SIN EMPRESA
--
-- Úsalo SOLO si en revisar-red.sql (consulta 2) el admin de la empresa
-- nueva aparece con empresa_reparto_id = NULL. Esa cuenta entra al panel
-- pero no ve nada: ni clientes, ni pedidos, ni las invitaciones.
--
-- Supabase → SQL Editor → New query → pegar → cambiar las DOS líneas
-- marcadas → Run.
-- ============================================================

-- ---------- 1. mirá los números que vas a usar ----------
select id, nombre from public.empresas_reparto order by id;
--   anotá el id de la empresa nueva

select p.id, u.email, p.nombre, p.rol, p.empresa_reparto_id, p.superadmin
  from public.perfiles p join auth.users u on u.id = p.id
 order by p.creado_en;
--   confirmá el correo de la cuenta que quedó suelta


-- ---------- 2. el arreglo ----------
-- ⬇️ CAMBIÁ ESTAS DOS LÍNEAS
--    · el correo con el que creaste el acceso de la empresa
--    · el nombre EXACTO de la empresa, tal cual aparece arriba
do $$
declare
  v_correo  text := 'admin@empresanueva.cl';     -- ⬅️ CAMBIAR
  v_empresa text := 'Nombre de la empresa';      -- ⬅️ CAMBIAR
  v_emp_id  bigint;
  v_n       int;
begin
  select id into v_emp_id from public.empresas_reparto where nombre = v_empresa;
  if v_emp_id is null then
    raise exception 'No existe ninguna empresa que se llame "%". Copiá el nombre tal cual sale en la lista de arriba.', v_empresa;
  end if;

  update public.perfiles p
     set rol                = 'admin',
         empresa_reparto_id = v_emp_id,
         superadmin         = false,
         cliente_id         = null,
         activo             = true,
         correo             = u.email,
         nombre             = coalesce(nullif(p.nombre,''), 'Admin ' || v_empresa)
    from auth.users u
   where u.id = p.id and lower(u.email) = lower(v_correo);

  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'No hay ninguna cuenta con el correo "%". Revisá cómo está escrito.', v_correo;
  end if;
  raise notice 'Listo: la cuenta % quedó como administradora de % (id %).', v_correo, v_empresa, v_emp_id;
end $$;


-- ---------- 3. comprobar que quedó bien ----------
select u.email, p.nombre, p.rol, p.superadmin, e.nombre as empresa
  from public.perfiles p
  join auth.users u on u.id = p.id
  left join public.empresas_reparto e on e.id = p.empresa_reparto_id
 order by p.creado_en;
--   la cuenta de la empresa nueva tiene que mostrar su empresa en la última
--   columna, rol = admin y superadmin = false.
--   Después de esto, que salga del panel y vuelva a entrar.
