-- ============================================================
-- APLICACION ZAS — RED DE EMPRESAS DE REPARTO
-- (reemplaza a migracion-pool-empresas.sql, que NO hay que correr)
--
-- CÓMO USARLA:
--   Supabase → SQL Editor → New query → pegar TODO esto → Run
--
-- Es SEGURA de correr más de una vez. No borra datos.
--
-- QUÉ HACE
-- --------
-- Convierte la app de "una sola empresa de reparto" en una RED que se
-- puede arrendar a muchas:
--
--   · Cada EMPRESA DE REPARTO ve solo lo suyo: sus pedidos, su gente,
--     sus clientes. Nadie ve los datos de otra.
--   · Cada CLIENTE decide qué empresas le reparten y CÓMO se reparten:
--     por comuna, por cuota diaria o por porcentaje.
--   · Lo que las reglas no resuelven cae al POOL: queda a la vista de
--     las empresas habilitadas y se lo lleva la primera que lo tome,
--     en exclusiva.
--   · Para que nadie ACAPARE pedidos que no va a repartir hay dos frenos:
--     un TOPE de pedidos tomados sin repartidor asignado, y un PLAZO
--     para asignarlo — vencido el plazo, el pedido vuelve solo al pool.
--   · Una empresa puede sumar a un cliente que ya está en la red, pero
--     el cliente tiene que ACEPTAR. Y al revés también.
--
-- Un cliente con UNA sola empresa habilitada funciona exactamente como
-- hoy: sus pedidos se asignan solos y no hay pool que mirar.
-- ============================================================


-- ============================================================
-- 0. AYUDANTES DE TEXTO
--    Comparar comunas escritas de cualquier forma: "Ñuñoa", "nunoa",
--    " NUNOA " son la misma. Lo mismo con los RUT: 76.123.456-7 y
--    761234567 son el mismo.
-- ============================================================
create or replace function public.norm_txt(t text)
returns text language sql immutable as $$
  select trim(lower(translate(coalesce(t,''),
    'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû',
    'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou')));
$$;

create or replace function public.norm_rut(t text)
returns text language sql immutable as $$
  select nullif(lower(regexp_replace(coalesce(t,''), '[^0-9kK]', '', 'g')), '');
$$;


-- ============================================================
-- 1. LAS EMPRESAS DE REPARTO (las que arriendan la app)
-- ============================================================
create table if not exists public.empresas_reparto (
  id bigint generated always as identity primary key,
  nombre text not null,
  rut text,
  telefono text,
  email text,
  color text default '#2563eb',          -- para distinguirlas de un vistazo
  plan text not null default 'prueba',   -- prueba | basico | pro  (informativo)
  tope_pedidos_mes int,                  -- NULL = sin tope
  notas text,
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

alter table public.empresas_reparto add column if not exists plan text not null default 'prueba';
alter table public.empresas_reparto add column if not exists tope_pedidos_mes int;
alter table public.empresas_reparto add column if not exists notas text;

-- La primera empresa es la tuya. Si ya existe, no la duplica.
insert into public.empresas_reparto (nombre, plan)
select 'Envíos ZAS', 'pro'
where not exists (select 1 from public.empresas_reparto);


-- ============================================================
-- 2. QUIÉN TRABAJA EN QUÉ EMPRESA
-- ============================================================
alter table public.perfiles add column if not exists empresa_reparto_id bigint
  references public.empresas_reparto(id);

-- El super-admin (vos, dueño del sistema) ve y administra TODO.
-- Los admin de una empresa arrendataria solo ven lo de su empresa.
alter table public.perfiles add column if not exists superadmin boolean not null default false;

-- Los usuarios que ya existen son de la primera empresa (Envíos ZAS)
update public.perfiles
   set empresa_reparto_id = (select min(id) from public.empresas_reparto)
 where empresa_reparto_id is null
   and rol in ('admin','repartidor');

-- ...y el admin más antiguo sos vos: queda como super-admin.
-- (solo uno, para que no queden varios dueños del sistema por accidente)
update public.perfiles set superadmin = true
 where id = (select id from public.perfiles
              where rol = 'admin' order by creado_en, id limit 1)
   and not exists (select 1 from public.perfiles where superadmin);


-- ============================================================
-- 3. CONFIGURACIÓN DE LA RED (el piso que pones vos)
--    El cliente puede APRETAR más estos números en su ficha, pero
--    nunca aflojarlos: siempre gana el más estricto de los dos.
-- ============================================================
create table if not exists public.config_red (
  id int primary key default 1 check (id = 1),
  plazo_asignar_min int not null default 120,   -- minutos para asignar repartidor
  tope_sin_asignar  int not null default 30,    -- pedidos tomados sin repartidor
  actualizado_en timestamptz not null default now()
);
insert into public.config_red (id) values (1) on conflict (id) do nothing;


-- ============================================================
-- 4. EL CLIENTE Y CÓMO QUIERE QUE LE REPARTAN
-- ============================================================
alter table public.clientes add column if not exists modo_reparto text not null default 'reglas';
alter table public.clientes drop constraint if exists clientes_modo_reparto_check;
alter table public.clientes add constraint clientes_modo_reparto_check
  check (modo_reparto in ('reglas','pool'));
--   'reglas' = se reparte por comuna/cuota/porcentaje y lo que sobra va al pool
--   'pool'   = todo al pool, gana quien lo tome primero

alter table public.clientes add column if not exists plazo_asignar_min int;  -- NULL = usa el de la red
alter table public.clientes add column if not exists tope_sin_asignar  int;  -- NULL = usa el de la red

-- Identidad del cliente en la red: el RUT. Es lo que permite que dos
-- empresas distintas reconozcan al MISMO cliente en vez de duplicarlo.
do $$
declare v_dup int;
begin
  select count(*) into v_dup from (
    select public.norm_rut(rut) r, count(*) c
      from public.clientes where public.norm_rut(rut) is not null
     group by 1 having count(*) > 1) x;
  if v_dup = 0 then
    create unique index if not exists idx_clientes_rut_unico
      on public.clientes (public.norm_rut(rut))
      where public.norm_rut(rut) is not null;
  else
    raise notice 'OJO: hay % RUT repetidos en clientes. No se creó el índice único; revisalos y volvé a correr esto.', v_dup;
  end if;
end $$;

create index if not exists idx_clientes_rut on public.clientes (public.norm_rut(rut));


-- ============================================================
-- 5. QUÉ EMPRESAS PUEDE USAR CADA CLIENTE, Y CON QUÉ REGLAS
--    Sin una fila ACTIVA acá, la empresa NO ve nada de ese cliente.
-- ============================================================
create table if not exists public.cliente_empresas (
  cliente_id bigint not null references public.clientes(id) on delete cascade,
  empresa_reparto_id bigint not null references public.empresas_reparto(id) on delete cascade,
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  primary key (cliente_id, empresa_reparto_id)
);

-- --- el vínculo: pendiente hasta que la otra parte acepta ---
alter table public.cliente_empresas add column if not exists estado text not null default 'activa';
alter table public.cliente_empresas drop constraint if exists cliente_empresas_estado_check;
alter table public.cliente_empresas add constraint cliente_empresas_estado_check
  check (estado in ('pendiente','activa','rechazada'));
alter table public.cliente_empresas add column if not exists solicitado_por text not null default 'sistema';
alter table public.cliente_empresas drop constraint if exists cliente_empresas_solicitado_check;
alter table public.cliente_empresas add constraint cliente_empresas_solicitado_check
  check (solicitado_por in ('sistema','empresa','cliente'));
alter table public.cliente_empresas add column if not exists solicitado_en timestamptz default now();
alter table public.cliente_empresas add column if not exists respondido_en timestamptz;
alter table public.cliente_empresas add column if not exists solicitado_por_usuario uuid references public.perfiles(id);

-- --- las reglas de reparto que pone el CLIENTE ---
-- comunas vacío = "le sirve cualquier comuna" (comodín).
-- Si alguna empresa nombra la comuna del pedido, esa gana: lo específico
-- le gana al comodín.
alter table public.cliente_empresas add column if not exists comunas text[] not null default '{}';
alter table public.cliente_empresas add column if not exists cuota_diaria int;   -- NULL = sin tope
alter table public.cliente_empresas add column if not exists porcentaje int;     -- NULL = sin objetivo
alter table public.cliente_empresas drop constraint if exists cliente_empresas_pct_check;
alter table public.cliente_empresas add constraint cliente_empresas_pct_check
  check (porcentaje is null or porcentaje between 0 and 100);
alter table public.cliente_empresas add column if not exists prioridad int not null default 100;
alter table public.cliente_empresas add column if not exists nota text;

create index if not exists idx_cliente_empresas_emp
  on public.cliente_empresas (empresa_reparto_id, estado);

-- Los clientes que ya existen quedan habilitados y activos con la primera empresa
insert into public.cliente_empresas (cliente_id, empresa_reparto_id, estado, solicitado_por)
select c.id, (select min(id) from public.empresas_reparto), 'activa', 'sistema'
from public.clientes c
on conflict do nothing;


-- ============================================================
-- 6. EL PEDIDO Y SU DUEÑO
--    empresa_reparto_id NULL = está en el pool, libre para tomar
-- ============================================================
alter table public.pedidos add column if not exists empresa_reparto_id bigint
  references public.empresas_reparto(id);
alter table public.pedidos add column if not exists tomado_en timestamptz;
alter table public.pedidos add column if not exists tomado_por uuid
  references public.perfiles(id);
-- por qué cayó donde cayó (para que no sea una caja negra si alguien reclama)
alter table public.pedidos add column if not exists asignacion_motivo text;
-- hasta cuándo tiene la empresa para asignarle un repartidor
alter table public.pedidos add column if not exists vence_asignacion_en timestamptz;
alter table public.pedidos add column if not exists veces_devuelto int not null default 0;

-- Todo lo que ya está cargado es tuyo: NO se va al pool.
update public.pedidos
   set empresa_reparto_id = (select min(id) from public.empresas_reparto),
       tomado_en = coalesce(tomado_en, asignado_en, creado_en),
       asignacion_motivo = coalesce(asignacion_motivo, 'ya existía antes de la red')
 where empresa_reparto_id is null;

create index if not exists idx_pedidos_empresa
  on public.pedidos (empresa_reparto_id, fecha_pedido);
-- el índice del pool: pedidos sin dueño, que es lo que más se consulta
create index if not exists idx_pedidos_pool
  on public.pedidos (cliente_id, estado) where empresa_reparto_id is null;
-- el índice de los vencidos
create index if not exists idx_pedidos_vence
  on public.pedidos (vence_asignacion_en) where vence_asignacion_en is not null;


-- ============================================================
-- 7. BITÁCORA DEL POOL (quién tomó qué, quién lo soltó y qué venció)
-- ============================================================
create table if not exists public.pool_movimientos (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references public.pedidos(id) on delete cascade,
  empresa_reparto_id bigint references public.empresas_reparto(id),
  accion text not null,
  usuario_id uuid references public.perfiles(id),
  nota text,
  creado_en timestamptz not null default now()
);
alter table public.pool_movimientos drop constraint if exists pool_movimientos_accion_check;
alter table public.pool_movimientos add constraint pool_movimientos_accion_check
  check (accion in ('tomado','devuelto','vencido','asignado','movido'));
create index if not exists idx_pool_mov_pedido on public.pool_movimientos (pedido_id);
-- Borrar a un usuario no tiene por qué trabarse con la bitácora vieja:
-- el registro queda, sin el nombre.
alter table public.pool_movimientos drop constraint if exists pool_movimientos_usuario_id_fkey;
alter table public.pool_movimientos add constraint pool_movimientos_usuario_id_fkey
  foreign key (usuario_id) references public.perfiles(id) on delete set null;
alter table public.pedidos drop constraint if exists pedidos_tomado_por_fkey;
alter table public.pedidos add constraint pedidos_tomado_por_fkey
  foreign key (tomado_por) references public.perfiles(id) on delete set null;
alter table public.cliente_empresas drop constraint if exists cliente_empresas_solicitado_por_usuario_fkey;
alter table public.cliente_empresas add constraint cliente_empresas_solicitado_por_usuario_fkey
  foreign key (solicitado_por_usuario) references public.perfiles(id) on delete set null;


create index if not exists idx_pool_mov_emp on public.pool_movimientos (empresa_reparto_id, creado_en);


-- ============================================================
-- 8. FUNCIONES DE APOYO
--    (security definer = pueden mirar las tablas sin chocar con las
--     reglas de seguridad, y así evitan bucles infinitos)
-- ============================================================

-- ¿A qué empresa de reparto pertenece el usuario conectado?
create or replace function public.mi_empresa_reparto()
returns bigint language sql stable security definer set search_path = public as $$
  select empresa_reparto_id from public.perfiles
   where id = auth.uid() and activo;
$$;

-- ¿Es el dueño del sistema? (ve absolutamente todo)
create or replace function public.es_superadmin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles
                  where id = auth.uid() and superadmin and activo);
$$;

-- ¿Mi empresa está habilitada (y aceptada) para este cliente?
create or replace function public.puedo_ver_cliente(p_cliente_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select p_cliente_id is not null and exists (
    select 1 from public.cliente_empresas ce
     where ce.cliente_id = p_cliente_id
       and ce.empresa_reparto_id = public.mi_empresa_reparto()
       and ce.activo and ce.estado = 'activa');
$$;

-- ¿Puedo ver este pedido? (para el historial y las pruebas de entrega)
create or replace function public.puedo_ver_pedido(p_pedido_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.pedidos p
     where p.id = p_pedido_id
       and ( public.es_superadmin()
          or (public.es_admin() and p.empresa_reparto_id is not null
              and p.empresa_reparto_id = public.mi_empresa_reparto())
          or p.repartidor_id = auth.uid()
          or (p.cliente_id is not null and p.cliente_id = public.cliente_de_usuario())
       ));
$$;

-- Los dos frenos anti-acaparamiento que le corresponden a este cliente.
-- Siempre gana el más estricto entre lo que puso el cliente y el piso de la red.
create or replace function public.limites_cliente(p_cliente_id bigint)
returns table(plazo_min int, tope int)
language sql stable security definer set search_path = public as $$
  select least(coalesce(c.plazo_asignar_min, r.plazo_asignar_min), r.plazo_asignar_min),
         least(coalesce(c.tope_sin_asignar,  r.tope_sin_asignar),  r.tope_sin_asignar)
    from public.config_red r
    left join public.clientes c on c.id = p_cliente_id;
$$;


-- ============================================================
-- 9. ¿A QUÉ EMPRESA LE TOCA ESTE PEDIDO?
--
--    Devuelve las empresas que CALZAN con las reglas del cliente para
--    esa comuna y ese día. El panel también la usa para mostrarle al
--    cliente a quién le tocaría antes de guardar sus reglas.
--
--    Cómo elige:
--      1. Si alguna empresa nombró esa comuna, solo compiten esas
--         (lo específico le gana al comodín).
--      2. Si ninguna la nombró, compiten las que no pusieron comunas.
--      3. Se saca a las que ya llegaron a su cuota del día.
--    "atraso" = cuánto le falta para llegar a su porcentaje objetivo.
-- ============================================================
create or replace function public.candidatas_reparto(
  p_cliente_id bigint, p_comuna text, p_fecha date)
returns table(empresa_reparto_id bigint, prioridad int, porcentaje int,
              hoy int, atraso numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_c text;
  v_hay_especifica boolean;
  v_total numeric;
begin
  v_c := public.norm_txt(p_comuna);

  select exists (
    select 1 from public.cliente_empresas ce
     where ce.cliente_id = p_cliente_id and ce.activo and ce.estado = 'activa'
       and coalesce(array_length(ce.comunas,1),0) > 0
       and v_c <> ''
       and exists (select 1 from unnest(ce.comunas) x where public.norm_txt(x) = v_c))
  into v_hay_especifica;

  select greatest(count(*),1)::numeric into v_total
    from public.pedidos q
   where q.cliente_id = p_cliente_id and q.fecha_pedido = p_fecha
     and q.empresa_reparto_id is not null;

  return query
  select ce.empresa_reparto_id, ce.prioridad, ce.porcentaje, h.n::int,
         (coalesce(ce.porcentaje,0)/100.0) - (h.n::numeric / v_total)
    from public.cliente_empresas ce
    cross join lateral (
      select count(*) n from public.pedidos q
       where q.cliente_id = p_cliente_id
         and q.empresa_reparto_id = ce.empresa_reparto_id
         and q.fecha_pedido = p_fecha) h
   where ce.cliente_id = p_cliente_id and ce.activo and ce.estado = 'activa'
     and (case when v_hay_especifica
               then coalesce(array_length(ce.comunas,1),0) > 0
                    and exists (select 1 from unnest(ce.comunas) x where public.norm_txt(x) = v_c)
               else coalesce(array_length(ce.comunas,1),0) = 0
          end)
     and (ce.cuota_diaria is null or h.n < ce.cuota_diaria)
   order by ce.prioridad, ce.empresa_reparto_id;
end $$;


-- ============================================================
-- 10. PEDIDO NUEVO: ¿directo a una empresa, o al pool?
-- ============================================================
create or replace function public.fn_asignar_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_mia      bigint;
  v_n        int;
  v_activas  int;
  v_todas_pct boolean;
  v_elegida  bigint;
  v_motivo   text;
  v_empates  int;
  v_prio     int;
  v_plazo    int;
begin
  -- ¿cuántas empresas tiene habilitadas y aceptadas este cliente?
  select count(*) into v_activas from public.cliente_empresas ce
   where ce.cliente_id = new.cliente_id and ce.activo and ce.estado = 'activa';

  -- (a) ya viene con dueño puesto a mano
  if new.empresa_reparto_id is not null then
    new.tomado_en := coalesce(new.tomado_en, now());
    new.asignacion_motivo := coalesce(new.asignacion_motivo, 'asignada al cargar el pedido');
    if v_activas >= 2 and new.repartidor_id is null then
      select plazo_min into v_plazo from public.limites_cliente(new.cliente_id);
      new.vence_asignacion_en := now() + make_interval(mins => v_plazo);
    end if;
    return new;
  end if;

  v_mia := public.mi_empresa_reparto();

  -- (b) pedido manual sin cliente: es de la empresa de quien lo carga
  if new.cliente_id is null then
    new.empresa_reparto_id := v_mia;
    if v_mia is not null then
      new.tomado_en := now();
      new.asignacion_motivo := 'pedido cargado a mano';
    end if;
    return new;
  end if;

  -- (c) lo carga una empresa habilitada para ese cliente → es suyo
  if v_mia is not null and public.puedo_ver_cliente(new.cliente_id) then
    new.empresa_reparto_id := v_mia;
    new.tomado_en := now();
    new.asignacion_motivo := 'lo cargó tu empresa';
    return new;
  end if;

  -- (d) el cliente no tiene a nadie habilitado
  if v_activas = 0 then
    new.asignacion_motivo := 'el cliente todavía no habilitó ninguna empresa';
    return new;                       -- queda NULL: nadie lo ve hasta que habilite
  end if;

  -- (e) una sola empresa: se la asignamos, todo sigue como siempre
  if v_activas = 1 then
    select ce.empresa_reparto_id into v_elegida from public.cliente_empresas ce
     where ce.cliente_id = new.cliente_id and ce.activo and ce.estado = 'activa';
    new.empresa_reparto_id := v_elegida;
    new.tomado_en := now();
    new.asignacion_motivo := 'única empresa habilitada por el cliente';
    return new;
  end if;

  -- (f) el cliente eligió pool libre
  if coalesce((select modo_reparto from public.clientes where id = new.cliente_id), 'reglas') = 'pool' then
    new.asignacion_motivo := 'el cliente eligió pool libre';
    return new;
  end if;

  -- (g) reglas del cliente
  select count(*), coalesce(bool_and(porcentaje is not null), false)
    into v_n, v_todas_pct
    from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido);

  if v_n = 0 then
    new.asignacion_motivo := 'ninguna empresa cubre ' ||
      coalesce(nullif(new.comuna,''), 'esa comuna') || ' o todas llegaron a su cuota del día';

  elsif v_n = 1 then
    select c.empresa_reparto_id into v_elegida
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c;
    new.empresa_reparto_id := v_elegida;
    new.asignacion_motivo := 'regla del cliente para ' || coalesce(nullif(new.comuna,''), 'esa comuna');

  elsif v_todas_pct then
    -- todas tienen porcentaje: le toca a la que va más atrasada respecto a su objetivo
    select c.empresa_reparto_id into v_elegida
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c
     order by c.atraso desc, c.prioridad, c.empresa_reparto_id limit 1;
    new.empresa_reparto_id := v_elegida;
    new.asignacion_motivo := 'reparto por porcentaje';

  else
    -- desempata la prioridad; si están parejas, decide el pool
    select min(c.prioridad) into v_prio
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c;
    select count(*) into v_empates
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c
     where c.prioridad = v_prio;

    if v_empates = 1 then
      select c.empresa_reparto_id into v_elegida
        from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c
       where c.prioridad = v_prio;
      new.empresa_reparto_id := v_elegida;
      new.asignacion_motivo := 'prioridad que puso el cliente';
    else
      new.asignacion_motivo := v_empates || ' empresas calzan parejo: lo decide el pool';
    end if;
  end if;

  if new.empresa_reparto_id is not null then
    new.tomado_en := now();
    select plazo_min into v_plazo from public.limites_cliente(new.cliente_id);
    new.vence_asignacion_en := now() + make_interval(mins => v_plazo);
  end if;

  return new;
end $$;

drop trigger if exists trg_pedidos_pool on public.pedidos;
drop trigger if exists trg_asignar_pedido on public.pedidos;
create trigger trg_asignar_pedido
before insert on public.pedidos
for each row execute function public.fn_asignar_pedido();


-- Apenas el pedido tiene repartidor, se apaga el reloj del plazo.
create or replace function public.fn_pedidos_reloj()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.repartidor_id is not null or new.estado not in ('pendiente') then
    new.vence_asignacion_en := null;
  end if;
  return new;
end $$;

drop trigger if exists trg_pedidos_reloj on public.pedidos;
create trigger trg_pedidos_reloj
before update on public.pedidos
for each row execute function public.fn_pedidos_reloj();


-- Cliente nuevo creado por una empresa → queda habilitado y activo para
-- ella (si no, no vería ni a sus propios clientes).
create or replace function public.fn_clientes_habilitar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_mia bigint;
begin
  v_mia := public.mi_empresa_reparto();
  if v_mia is not null then
    insert into public.cliente_empresas
      (cliente_id, empresa_reparto_id, estado, solicitado_por, solicitado_por_usuario, respondido_en)
    values (new.id, v_mia, 'activa', 'empresa', auth.uid(), now())
    on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists trg_clientes_habilitar on public.clientes;
create trigger trg_clientes_habilitar
after insert on public.clientes
for each row execute function public.fn_clientes_habilitar();


-- ============================================================
-- 11. LIBERAR LOS VENCIDOS
--     El que tomó un pedido y no le asignó repartidor dentro del plazo
--     lo pierde: vuelve al pool y queda registrado quién lo tenía.
--     Se llama sola cada vez que alguien mira o toma del pool, así que
--     no hace falta ningún proceso programado.
-- ============================================================
create or replace function public.liberar_vencidos()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  with vencidos as (
    select p.id, p.empresa_reparto_id
      from public.pedidos p
     where p.vence_asignacion_en is not null
       and p.vence_asignacion_en < now()
       and p.empresa_reparto_id is not null
       and p.repartidor_id is null
       and p.estado = 'pendiente'
       and p.cliente_id is not null
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
-- 12. TOMAR DEL POOL  ← el corazón de todo esto
--
--     Es una sola instrucción UPDATE con "empresa_reparto_id is null".
--     Si dos empresas aprietan "Tomar" en el mismo instante, la base de
--     datos deja pasar a UNA sola: la segunda vuelve a mirar la fila,
--     la ve ya tomada, y no hace nada. Es imposible que dos empresas se
--     queden con el mismo pedido.
--
--     Además respeta el TOPE del cliente: no podés llevarte más pedidos
--     de los que ya tenés tomados sin repartidor asignado. Es el freno
--     al que agarra todo para que no lo agarre otro.
-- ============================================================
create or replace function public.tomar_pedidos(p_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_emp     bigint;
  v_tomados bigint[];
  v_rechaza jsonb;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null then
    raise exception 'Tu cuenta no pertenece a ninguna empresa de reparto';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    return jsonb_build_object('tomados', 0, 'ids', '[]'::jsonb, 'no_pudo', '[]'::jsonb);
  end if;

  -- primero devolvemos al pool lo que se venció, así el cupo está al día
  perform public.liberar_vencidos();

  with pedir as (
    select p.id, p.cliente_id,
           row_number() over (partition by p.cliente_id order by p.id) as rn
      from public.pedidos p
     where p.id = any(p_ids)
       and p.empresa_reparto_id is null
       and p.estado not in ('entregado','cancelado')
       and exists (select 1 from public.cliente_empresas ce
                    where ce.cliente_id = p.cliente_id
                      and ce.empresa_reparto_id = v_emp
                      and ce.activo and ce.estado = 'activa')
  ), cupo as (
    select d.cliente_id,
           greatest(0, (select tope from public.limites_cliente(d.cliente_id))
                     - (select count(*) from public.pedidos q
                         where q.empresa_reparto_id = v_emp
                           and q.cliente_id = d.cliente_id
                           and q.repartidor_id is null
                           and q.estado = 'pendiente')) as libre
      from (select distinct cliente_id from pedir) d
  ), elegibles as (
    select pd.id from pedir pd
      join cupo c on c.cliente_id is not distinct from pd.cliente_id
     where pd.rn <= c.libre
  ), upd as (
    update public.pedidos p
       set empresa_reparto_id = v_emp,
           tomado_en          = now(),
           tomado_por         = auth.uid(),
           asignacion_motivo  = 'tomado del pool',
           vence_asignacion_en = now() + make_interval(
             mins => (select plazo_min from public.limites_cliente(p.cliente_id)))
     where p.id in (select id from elegibles)
       and p.empresa_reparto_id is null                       -- ← la exclusividad
    returning p.id
  )
  select coalesce(array_agg(id), '{}') into v_tomados from upd;

  insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id)
  select unnest(v_tomados), v_emp, 'tomado', auth.uid();

  -- para los que no se pudieron, explicar por qué (en castellano)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'motivo', case
             when p.id is null then 'ya no existe'
             when p.empresa_reparto_id is not null then
               'se adelantó ' || coalesce((select e.nombre from public.empresas_reparto e
                                            where e.id = p.empresa_reparto_id), 'otra empresa')
             when p.estado in ('entregado','cancelado') then 'ya está ' || p.estado
             when not exists (select 1 from public.cliente_empresas ce
                               where ce.cliente_id = p.cliente_id
                                 and ce.empresa_reparto_id = v_emp
                                 and ce.activo and ce.estado = 'activa')
               then 'ese cliente no habilitó a tu empresa'
             else 'llegaste al tope de ' ||
                  (select tope from public.limites_cliente(p.cliente_id)) ||
                  ' pedidos tomados sin repartidor: asigná los que tenés y volvé'
           end)), '[]'::jsonb)
    into v_rechaza
    from unnest(p_ids) as x(id)
    left join public.pedidos p on p.id = x.id
   where not (x.id = any(v_tomados));

  return jsonb_build_object(
    'tomados', coalesce(array_length(v_tomados,1), 0),
    'ids',     to_jsonb(v_tomados),
    'no_pudo', v_rechaza);
end $$;


-- ============================================================
-- 13. DEVOLVER AL POOL
--     La empresa solo puede soltarlo mientras NO vaya en ruta: si el
--     repartidor ya lo aceptó o va en camino, no se puede.
--     El super-admin SIEMPRE puede forzarlo. Queda en la bitácora.
-- ============================================================
create or replace function public.devolver_pedidos(p_ids bigint[], p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_emp       bigint;
  v_devueltos bigint[];
  v_rechaza   jsonb;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null and not public.es_superadmin() then
    raise exception 'Tu cuenta no pertenece a ninguna empresa de reparto';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    return jsonb_build_object('devueltos', 0, 'ids', '[]'::jsonb, 'no_pudo', '[]'::jsonb);
  end if;

  with upd as (
    update public.pedidos p
       set empresa_reparto_id = null,
           repartidor_id      = null,
           tomado_en          = null,
           tomado_por         = null,
           vence_asignacion_en = null,
           veces_devuelto     = p.veces_devuelto + 1,
           asignacion_motivo  = 'devuelto al pool',
           estado             = 'pendiente'
     where p.id = any(p_ids)
       and p.empresa_reparto_id is not null
       and (public.es_superadmin() or p.empresa_reparto_id = v_emp)
       -- la empresa solo si no va en ruta; el super-admin siempre
       and (public.es_superadmin() or p.estado in ('pendiente','asignado'))
       -- y solo tiene sentido si hay otra empresa que lo pueda tomar
       and (public.es_superadmin() or
            (select count(*) from public.cliente_empresas ce
              where ce.cliente_id = p.cliente_id and ce.activo and ce.estado='activa') >= 2)
    returning p.id
  )
  select coalesce(array_agg(id), '{}') into v_devueltos from upd;

  insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id, nota)
  select unnest(v_devueltos), v_emp, 'devuelto', auth.uid(), p_nota;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'motivo', case
             when p.id is null then 'ya no existe'
             when p.empresa_reparto_id is null then 'ya estaba en el pool'
             when p.empresa_reparto_id <> v_emp and not public.es_superadmin() then 'no es de tu empresa'
             when p.estado not in ('pendiente','asignado') then 'ya va en ruta (' || p.estado || '), no se puede soltar'
             else 'ese cliente solo trabaja con tu empresa: no hay pool donde devolverlo'
           end)), '[]'::jsonb)
    into v_rechaza
    from unnest(p_ids) as x(id)
    left join public.pedidos p on p.id = x.id
   where not (x.id = any(v_devueltos));

  return jsonb_build_object(
    'devueltos', coalesce(array_length(v_devueltos,1), 0),
    'ids',       to_jsonb(v_devueltos),
    'no_pudo',   v_rechaza);
end $$;


-- ============================================================
-- 14. LA RED: sumar clientes que ya existen, con permiso
--
--     Una empresa busca al cliente por RUT. Si ya está en la red, le
--     manda una SOLICITUD; el cliente la acepta desde su panel. Y al
--     revés: el cliente puede sumar una empresa y la empresa acepta.
--     Nadie entra a los datos de nadie sin que la otra parte diga que sí.
-- ============================================================
create or replace function public.buscar_cliente_red(p_rut text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_r text; v_c record; v_emp bigint; v_v record;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null then raise exception 'Tu cuenta no pertenece a ninguna empresa de reparto'; end if;
  v_r := public.norm_rut(p_rut);
  if v_r is null then return jsonb_build_object('existe', false); end if;

  select id, nombre, comuna into v_c from public.clientes where public.norm_rut(rut) = v_r limit 1;
  if v_c.id is null then return jsonb_build_object('existe', false); end if;

  select estado, activo into v_v from public.cliente_empresas
   where cliente_id = v_c.id and empresa_reparto_id = v_emp;

  return jsonb_build_object(
    'existe', true, 'id', v_c.id, 'nombre', v_c.nombre, 'comuna', v_c.comuna,
    'vinculo', coalesce(v_v.estado, 'sin_vinculo'));
end $$;

-- La empresa pide trabajar con un cliente que ya está en la red
create or replace function public.solicitar_cliente(p_cliente_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp bigint; v_estado text;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null then raise exception 'Tu cuenta no pertenece a ninguna empresa de reparto'; end if;
  if not public.es_admin() then raise exception 'Solo un administrador puede pedir clientes'; end if;

  select estado into v_estado from public.cliente_empresas
   where cliente_id = p_cliente_id and empresa_reparto_id = v_emp;

  if v_estado = 'activa' then
    return jsonb_build_object('ok', false, 'mensaje', 'Ya trabajás con ese cliente');
  end if;

  perform set_config('zas.vinculo', '1', true);
  insert into public.cliente_empresas
    (cliente_id, empresa_reparto_id, estado, solicitado_por, solicitado_por_usuario, solicitado_en, respondido_en)
  values (p_cliente_id, v_emp, 'pendiente', 'empresa', auth.uid(), now(), null)
  on conflict (cliente_id, empresa_reparto_id) do update
     set estado = 'pendiente', solicitado_por = 'empresa',
         solicitado_por_usuario = auth.uid(), solicitado_en = now(), respondido_en = null;
  perform set_config('zas.vinculo', '', true);

  return jsonb_build_object('ok', true,
    'mensaje', 'Solicitud enviada. El cliente tiene que aceptarla desde su panel.');
end $$;

-- El cliente suma una empresa (queda esperando que la empresa acepte)
create or replace function public.invitar_empresa(p_empresa_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cli bigint;
begin
  v_cli := public.cliente_de_usuario();
  if v_cli is null then raise exception 'Solo el cliente puede invitar empresas'; end if;

  perform set_config('zas.vinculo', '1', true);
  insert into public.cliente_empresas
    (cliente_id, empresa_reparto_id, estado, solicitado_por, solicitado_por_usuario, solicitado_en, respondido_en)
  values (v_cli, p_empresa_id, 'pendiente', 'cliente', auth.uid(), now(), null)
  on conflict (cliente_id, empresa_reparto_id) do update
     set estado = case when public.cliente_empresas.estado = 'activa' then 'activa' else 'pendiente' end,
         solicitado_por = 'cliente', solicitado_por_usuario = auth.uid(), solicitado_en = now();
  perform set_config('zas.vinculo', '', true);

  return jsonb_build_object('ok', true, 'mensaje', 'Invitación enviada a la empresa.');
end $$;

-- Aceptar o rechazar. Solo puede responder la parte que NO pidió.
create or replace function public.responder_vinculo(
  p_cliente_id bigint, p_empresa_id bigint, p_aceptar boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row record; v_soy_cliente boolean; v_soy_empresa boolean;
begin
  select * into v_row from public.cliente_empresas
   where cliente_id = p_cliente_id and empresa_reparto_id = p_empresa_id;
  if v_row is null then raise exception 'No hay ninguna solicitud entre esos dos'; end if;
  if v_row.estado <> 'pendiente' then
    return jsonb_build_object('ok', false, 'mensaje', 'Esa solicitud ya está ' || v_row.estado);
  end if;

  v_soy_cliente := public.cliente_de_usuario() = p_cliente_id;
  v_soy_empresa := public.mi_empresa_reparto() = p_empresa_id and public.es_admin();

  if public.es_superadmin() then
    null;                                             -- el dueño del sistema puede destrabar
  elsif v_row.solicitado_por = 'empresa' and not v_soy_cliente then
    raise exception 'Esa solicitud la tiene que responder el cliente';
  elsif v_row.solicitado_por = 'cliente' and not v_soy_empresa then
    raise exception 'Esa invitación la tiene que responder la empresa';
  end if;

  perform set_config('zas.vinculo', '1', true);
  update public.cliente_empresas
     set estado = case when p_aceptar then 'activa' else 'rechazada' end,
         respondido_en = now()
   where cliente_id = p_cliente_id and empresa_reparto_id = p_empresa_id;
  perform set_config('zas.vinculo', '', true);

  return jsonb_build_object('ok', true,
    'mensaje', case when p_aceptar then 'Vínculo activado' else 'Solicitud rechazada' end);
end $$;


-- ============================================================
-- 15. CÓMO SE PORTA CADA EMPRESA (lo mira el cliente y lo mirás vos)
-- ============================================================
drop view if exists public.v_empresa_conducta;
create view public.v_empresa_conducta with (security_invoker = true) as
select p.empresa_reparto_id,
       p.cliente_id,
       count(*)                                                            as pedidos,
       count(*) filter (where p.estado = 'entregado')                      as entregados,
       count(*) filter (where p.estado = 'no_entregado')                   as no_entregados,
       sum(p.veces_devuelto)                                               as devoluciones,
       round(avg(extract(epoch from (p.asignado_en - p.tomado_en))/60.0)
             filter (where p.asignado_en is not null and p.tomado_en is not null)) as min_promedio_asignar
  from public.pedidos p
 where p.empresa_reparto_id is not null
   and p.fecha_pedido >= (now() at time zone 'America/Santiago')::date - 30
 group by 1, 2;

drop view if exists public.v_empresa_uso_mes;
create view public.v_empresa_uso_mes with (security_invoker = true) as
select p.empresa_reparto_id,
       to_char(p.fecha_pedido, 'YYYY-MM') as mes,
       count(*)                           as pedidos,
       count(distinct p.cliente_id)       as clientes
  from public.pedidos p
 where p.empresa_reparto_id is not null
 group by 1, 2;


-- ============================================================
-- 16. SEGURIDAD — cada empresa ve SOLO lo suyo
--     (esto es lo que hace que se pueda arrendar sin que una empresa
--      vea los pedidos, los clientes ni los repartidores de la otra)
-- ============================================================
alter table public.empresas_reparto  enable row level security;
alter table public.cliente_empresas  enable row level security;
alter table public.pool_movimientos  enable row level security;
alter table public.config_red        enable row level security;

-- ---- config_red ----
drop policy if exists config_red_select on public.config_red;
create policy config_red_select on public.config_red for select
  using (auth.uid() is not null);
drop policy if exists config_red_super on public.config_red;
create policy config_red_super on public.config_red for all
  using (public.es_superadmin()) with check (public.es_superadmin());

-- ---- empresas_reparto ----
drop policy if exists empresas_super_all on public.empresas_reparto;
create policy empresas_super_all on public.empresas_reparto for all
  using (public.es_superadmin()) with check (public.es_superadmin());

-- Todo usuario conectado puede LEER el listado de empresas: el cliente
-- necesita poder elegir a quién sumar. Son solo nombre y contacto.
drop policy if exists empresas_select on public.empresas_reparto;
create policy empresas_select on public.empresas_reparto for select
  using (auth.uid() is not null);

-- ---- cliente_empresas ----
drop policy if exists cliente_empresas_super_all on public.cliente_empresas;
create policy cliente_empresas_super_all on public.cliente_empresas for all
  using (public.es_superadmin()) with check (public.es_superadmin());

drop policy if exists cliente_empresas_select on public.cliente_empresas;
create policy cliente_empresas_select on public.cliente_empresas for select
  using (empresa_reparto_id = public.mi_empresa_reparto()
      or cliente_id = public.cliente_de_usuario());

-- El CLIENTE manda sobre sus propias reglas: a quién habilita, qué
-- comunas le da a cada una, cuota, porcentaje y prioridad.
drop policy if exists cliente_empresas_cliente_ins on public.cliente_empresas;
create policy cliente_empresas_cliente_ins on public.cliente_empresas for insert
  with check (cliente_id = public.cliente_de_usuario());

drop policy if exists cliente_empresas_cliente_upd on public.cliente_empresas;
create policy cliente_empresas_cliente_upd on public.cliente_empresas for update
  using (cliente_id = public.cliente_de_usuario())
  with check (cliente_id = public.cliente_de_usuario());

drop policy if exists cliente_empresas_cliente_del on public.cliente_empresas;
create policy cliente_empresas_cliente_del on public.cliente_empresas for delete
  using (cliente_id = public.cliente_de_usuario());

-- La empresa puede pausar/soltar su propio vínculo, pero NO tocar las
-- reglas del cliente ni activarse sola: eso lo hacen las funciones.
drop policy if exists cliente_empresas_emp_del on public.cliente_empresas;
create policy cliente_empresas_emp_del on public.cliente_empresas for delete
  using (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto());

-- Guardia: una empresa NO puede activarse sola ni cambiar las reglas
-- del cliente aunque llegue por otra vía.
create or replace function public.fn_cliente_empresas_guardia()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_soy_cliente boolean;
begin
  -- sin usuario conectado = lo está haciendo el backend (webhooks, migraciones,
  -- llave de servicio). Ahí no hay a quién restringir.
  if auth.uid() is null then return new; end if;
  -- las funciones solicitar_cliente / invitar_empresa / responder_vinculo
  -- levantan esta bandera: ellas ya comprobaron quién puede hacer qué
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
    -- el cliente no puede activar una fila que pidió él mismo: la
    -- empresa tiene que aceptar (para eso está responder_vinculo)
    if old.estado = 'pendiente' and new.estado = 'activa'
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

-- ---- pool_movimientos ----
drop policy if exists pool_mov_select on public.pool_movimientos;
create policy pool_mov_select on public.pool_movimientos for select
  using (public.es_superadmin() or public.puedo_ver_pedido(pedido_id));

-- ---- PEDIDOS ----
-- Antes: "admin ve todo". Ahora el admin de una empresa arrendataria
-- solo ve lo de su empresa, y el super-admin sigue viendo todo.
drop policy if exists pedidos_admin_all on public.pedidos;

drop policy if exists pedidos_super_all on public.pedidos;
create policy pedidos_super_all on public.pedidos for all
  using (public.es_superadmin()) with check (public.es_superadmin());

-- lo que ya tomó mi empresa. Ojo: solo para ADMINISTRADORES. El
-- repartidor sigue viendo únicamente los pedidos que le tocan a él
-- (política pedidos_repartidor_select, del esquema original), así que
-- no puede leerse la agenda completa de la empresa desde el teléfono.
drop policy if exists pedidos_empresa_rep_select on public.pedidos;
create policy pedidos_empresa_rep_select on public.pedidos for select
  using (public.es_admin()
     and empresa_reparto_id is not null
     and empresa_reparto_id = public.mi_empresa_reparto());

drop policy if exists pedidos_empresa_rep_insert on public.pedidos;
create policy pedidos_empresa_rep_insert on public.pedidos for insert
  with check (public.es_admin()
          and empresa_reparto_id is not distinct from public.mi_empresa_reparto());

drop policy if exists pedidos_empresa_rep_update on public.pedidos;
create policy pedidos_empresa_rep_update on public.pedidos for update
  using (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto())
  with check (empresa_reparto_id = public.mi_empresa_reparto());

drop policy if exists pedidos_empresa_rep_delete on public.pedidos;
create policy pedidos_empresa_rep_delete on public.pedidos for delete
  using (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto());

-- EL POOL: se puede MIRAR, pero no tocar directamente.
-- La única forma de tomarlo es la función tomar_pedidos(), que es la que
-- garantiza que quede uno solo y respeta el tope.
drop policy if exists pedidos_pool_select on public.pedidos;
create policy pedidos_pool_select on public.pedidos for select
  using (public.es_admin()
     and empresa_reparto_id is null
     and public.puedo_ver_cliente(cliente_id));

-- ---- PERFILES ----
drop policy if exists perfiles_admin_all on public.perfiles;
drop policy if exists perfiles_select on public.perfiles;

drop policy if exists perfiles_super_all on public.perfiles;
create policy perfiles_super_all on public.perfiles for all
  using (public.es_superadmin()) with check (public.es_superadmin());

create policy perfiles_select on public.perfiles for select
  using (id = auth.uid()
      or public.es_superadmin()
      or (public.es_admin()
          and empresa_reparto_id is not null
          and empresa_reparto_id = public.mi_empresa_reparto()));

-- El admin de una empresa administra a SU gente. Puede tomar una cuenta
-- recién creada (que todavía no tiene empresa) para sumarla a la suya,
-- pero NO puede nombrarse super-admin ni pasarle gente a otra empresa.
drop policy if exists perfiles_empresa_rep_all on public.perfiles;
create policy perfiles_empresa_rep_all on public.perfiles for all
  using (public.es_admin()
     and not superadmin
     and (empresa_reparto_id = public.mi_empresa_reparto()
          or empresa_reparto_id is null))
  with check (public.es_admin()
     and not superadmin
     and (empresa_reparto_id = public.mi_empresa_reparto()
          or (empresa_reparto_id is null and rol = 'empresa')));

-- ---- CLIENTES ----
drop policy if exists clientes_admin_all on public.clientes;
drop policy if exists clientes_select on public.clientes;

drop policy if exists clientes_super_all on public.clientes;
create policy clientes_super_all on public.clientes for all
  using (public.es_superadmin()) with check (public.es_superadmin());

create policy clientes_select on public.clientes for select
  using (public.es_superadmin()
      or id = public.cliente_de_usuario()
      or public.puedo_ver_cliente(id));

drop policy if exists clientes_empresa_rep_insert on public.clientes;
create policy clientes_empresa_rep_insert on public.clientes for insert
  with check (public.es_admin());

drop policy if exists clientes_empresa_rep_update on public.clientes;
create policy clientes_empresa_rep_update on public.clientes for update
  using (public.es_admin() and public.puedo_ver_cliente(id))
  with check (public.es_admin() and public.puedo_ver_cliente(id));

-- El cliente edita SU propia ficha (modo de reparto, plazo y tope).
-- Si intenta aflojar los frenos por debajo del piso de la red, no pasa
-- nada: limites_cliente() siempre se queda con el más estricto.
drop policy if exists clientes_cliente_update on public.clientes;
create policy clientes_cliente_update on public.clientes for update
  using (id = public.cliente_de_usuario())
  with check (id = public.cliente_de_usuario());

-- ---- HISTORIAL / PRUEBAS / UBICACIONES ----
drop policy if exists historial_select on public.pedido_historial;
create policy historial_select on public.pedido_historial for select
  using (public.puedo_ver_pedido(pedido_id));

drop policy if exists pruebas_select on public.entregas_prueba;
create policy pruebas_select on public.entregas_prueba for select
  using (public.puedo_ver_pedido(pedido_id));

drop policy if exists ubicaciones_admin_select on public.ubicaciones;
create policy ubicaciones_admin_select on public.ubicaciones for select
  using (public.es_superadmin()
      or (public.es_admin() and exists (
            select 1 from public.perfiles pf
             where pf.id = ubicaciones.repartidor_id
               and pf.empresa_reparto_id = public.mi_empresa_reparto())));


-- ============================================================
-- 17. PERMISOS
-- ============================================================
grant select, insert, update, delete on public.empresas_reparto to authenticated;
grant select, insert, update, delete on public.cliente_empresas to authenticated;
grant select, update                 on public.config_red       to authenticated;
grant select                         on public.pool_movimientos to authenticated;
grant select                         on public.v_empresa_conducta to authenticated;
grant select                         on public.v_empresa_uso_mes  to authenticated;

grant execute on function public.tomar_pedidos(bigint[])                     to authenticated;
grant execute on function public.devolver_pedidos(bigint[], text)            to authenticated;
grant execute on function public.liberar_vencidos()                          to authenticated;
grant execute on function public.mi_empresa_reparto()                        to authenticated;
grant execute on function public.es_superadmin()                             to authenticated;
grant execute on function public.puedo_ver_cliente(bigint)                   to authenticated;
grant execute on function public.puedo_ver_pedido(bigint)                    to authenticated;
grant execute on function public.limites_cliente(bigint)                     to authenticated;
grant execute on function public.candidatas_reparto(bigint, text, date)      to authenticated;
grant execute on function public.buscar_cliente_red(text)                    to authenticated;
grant execute on function public.solicitar_cliente(bigint)                   to authenticated;
grant execute on function public.invitar_empresa(bigint)                     to authenticated;
grant execute on function public.responder_vinculo(bigint, bigint, boolean)  to authenticated;
grant execute on function public.norm_txt(text)                              to authenticated;
grant execute on function public.norm_rut(text)                              to authenticated;


-- ============================================================
-- COMPROBACIÓN — al terminar deberías ver algo así:
--
--   empresas de reparto : 1
--   super-admin         : 1   (vos)
--   pedidos en el pool  : 0   (todo lo viejo quedó como tuyo)
--   plazo / tope        : 120 min / 30 pedidos
-- ============================================================
select
  (select count(*) from public.empresas_reparto)                         as empresas_de_reparto,
  (select count(*) from public.perfiles where superadmin)                as super_admins,
  (select count(*) from public.cliente_empresas where estado='activa')   as vinculos_activos,
  (select count(*) from public.pedidos where empresa_reparto_id is null) as pedidos_en_el_pool,
  (select plazo_asignar_min from public.config_red)                      as plazo_minutos,
  (select tope_sin_asignar  from public.config_red)                      as tope_sin_asignar;
