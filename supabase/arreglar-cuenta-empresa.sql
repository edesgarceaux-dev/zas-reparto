-- ============================================================
-- ARREGLAR LA CUENTA QUE QUEDÓ SIN EMPRESA
--
-- ✅ NO HAY QUE EDITAR NADA. Pegalo entero y apretá Run.
--
-- Busca solo la cuenta que quedó suelta (un administrador sin empresa)
-- y la empresa que quedó sin nadie que la maneje, y las une.
-- Si hay más de una de cada, no adivina: te dice exactamente qué poner.
--
-- Supabase → SQL Editor → New query → pegar → Run
-- ============================================================

-- Si alguna vez hay varias sueltas, escribí acá los datos a mano.
-- Si los dejás vacíos, los busca solo. (Es lo normal.)
do $$
declare
  v_correo  text := '';     -- ej: 'admin@empresanueva.cl'   (vacío = detectar)
  v_empresa text := '';     -- ej: 'Rápido Ltda'             (vacío = detectar)

  v_emp_id  bigint;
  v_n       int;
  v_lista   text;
begin
  -- ---------- 1. la cuenta suelta ----------
  if v_correo = '' then
    select count(*), string_agg(coalesce(u.email,'(sin correo)'), ', ')
      into v_n, v_lista
      from public.perfiles p
      left join auth.users u on u.id = p.id
     where p.empresa_reparto_id is null
       and p.cliente_id is null
       and not p.superadmin
       and p.rol in ('admin','repartidor');

    if v_n = 0 then
      raise exception 'No encontré ninguna cuenta suelta. Todas las cuentas ya tienen empresa, así que el problema es otro: mandame el resultado de revisar-red.sql.';
    elsif v_n > 1 then
      raise exception 'Hay % cuentas sueltas (%). Escribí una en v_correo, arriba, y volvé a correr esto.', v_n, v_lista;
    end if;

    select u.email into v_correo
      from public.perfiles p
      join auth.users u on u.id = p.id
     where p.empresa_reparto_id is null
       and p.cliente_id is null
       and not p.superadmin
       and p.rol in ('admin','repartidor');
  end if;

  -- ---------- 2. la empresa sin administrador ----------
  if v_empresa = '' then
    select count(*), string_agg(e.nombre, ', ')
      into v_n, v_lista
      from public.empresas_reparto e
     where not exists (select 1 from public.perfiles p
                        where p.empresa_reparto_id = e.id and p.rol = 'admin');

    if v_n = 0 then
      raise exception 'Todas las empresas ya tienen administrador. Escribí a mano en v_empresa a cuál querés mandar la cuenta %.', v_correo;
    elsif v_n > 1 then
      raise exception 'Hay % empresas sin administrador (%). Escribí una en v_empresa, arriba, y volvé a correr esto.', v_n, v_lista;
    end if;

    select e.nombre into v_empresa
      from public.empresas_reparto e
     where not exists (select 1 from public.perfiles p
                        where p.empresa_reparto_id = e.id and p.rol = 'admin');
  end if;

  select id into v_emp_id from public.empresas_reparto where nombre = v_empresa;
  if v_emp_id is null then
    raise exception 'No existe ninguna empresa que se llame "%". Copiá el nombre tal cual sale en la consulta 3 de revisar-red.sql.', v_empresa;
  end if;

  -- ---------- 3. unirlas ----------
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
    raise exception 'No hay ninguna cuenta con el correo "%".', v_correo;
  end if;

  raise notice 'LISTO: % quedó como administradora de % (id %).', v_correo, v_empresa, v_emp_id;
end $$;


-- ---------- comprobación ----------
select coalesce(u.email,'(sin correo)')            as cuenta,
       p.nombre,
       p.rol,
       coalesce(e.nombre, '— NINGUNA —')           as empresa_de_reparto,
       case
         when p.superadmin then 'OK · dueño del sistema'
         when p.rol in ('admin','repartidor') and p.empresa_reparto_id is null
           then '⚠️ TODAVÍA SUELTA'
         else 'OK'
       end                                         as diagnostico
  from public.perfiles p
  left join auth.users              u on u.id = p.id
  left join public.empresas_reparto e on e.id = p.empresa_reparto_id
 order by p.superadmin desc, p.creado_en;

-- Si en la última columna ya no queda ningún ⚠️, andá al panel con esa
-- cuenta: salí y volvé a entrar, y la invitación tiene que aparecer en la
-- pestaña Clientes.
