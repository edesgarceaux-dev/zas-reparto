-- ============================================================
-- PLANIFICAR EN PARALELO, CONFIRMAR AL CARGAR
--
-- Correr una sola vez en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-escaneo-reclama.sql.
--
-- EL MODELO
-- ---------
-- Se termina el «pool» como pestaña aparte. Los pedidos que todavía no
-- son de nadie aparecen en PEDIDOS de todas las empresas habilitadas por
-- ese cliente. Cada una puede armarles ruta y asignarles repartidor.
-- Cuando un repartidor escanea la etiqueta, el pedido pasa a ser de SU
-- empresa, se va a la pestaña MI CARGA, y desaparece para las demás.
--
-- EL PROBLEMA QUE RESUELVE ESTA MIGRACIÓN
-- ---------------------------------------
-- Si dos empresas pueden planificar el mismo pedido, la asignación del
-- repartidor NO puede vivir en el pedido: la segunda le pisaría el
-- repartidor a la primera. Por eso los planes sobre pedidos compartidos
-- van en una tabla aparte, una fila por empresa. Recién cuando el pedido
-- se carga (se escanea) el plan ganador se copia al pedido y los demás
-- se descartan, avisándole a quien lo perdió.
-- ============================================================


-- ============================================================
-- 1. CADA CLIENTE ELIGE CÓMO REPARTIR
--    'reglas'  → sus comunas/cuotas/porcentajes asignan, y solo lo que
--                no calza con ninguna regla queda compartido
--    'abierto' → todos sus pedidos quedan a la vista de todas sus
--                empresas y se los queda el que los cargue
-- ============================================================
alter table public.clientes drop constraint if exists clientes_modo_reparto_check;
update public.clientes set modo_reparto = 'abierto' where modo_reparto = 'pool';
alter table public.clientes add constraint clientes_modo_reparto_check
  check (modo_reparto in ('reglas','abierto'));


-- ============================================================
-- 2. EL PLAN DE CADA EMPRESA SOBRE LOS PEDIDOS COMPARTIDOS
--    Una fila por (pedido, empresa): así dos empresas pueden armar su
--    ruta sobre el mismo bulto sin pisarse.
-- ============================================================
create table if not exists public.plan_reparto (
  pedido_id          bigint not null references public.pedidos(id) on delete cascade,
  empresa_reparto_id bigint not null references public.empresas_reparto(id) on delete cascade,
  repartidor_id      uuid   references public.perfiles(id) on delete set null,
  orden              int,
  nota               text,
  creado_por         uuid   references public.perfiles(id) on delete set null,
  creado_en          timestamptz not null default now(),
  primary key (pedido_id, empresa_reparto_id)
);
create index if not exists idx_plan_empresa on public.plan_reparto (empresa_reparto_id);
create index if not exists idx_plan_repartidor on public.plan_reparto (repartidor_id);


-- ============================================================
-- 2b. CUÁNDO SE CARGÓ (lo que separa «Pedidos» de «Mi carga»)
--     Se llena solo cuando un repartidor escanea la etiqueta.
-- ============================================================
alter table public.pedidos add column if not exists cargado_en timestamptz;
create index if not exists idx_pedidos_cargado
  on public.pedidos (empresa_reparto_id, cargado_en);


-- ============================================================
-- 3. AVISOS: a quién se le escapó un pedido que tenía planificado
-- ============================================================
create table if not exists public.avisos_red (
  id bigint generated always as identity primary key,
  empresa_reparto_id bigint references public.empresas_reparto(id) on delete cascade,
  repartidor_id uuid references public.perfiles(id) on delete cascade,
  pedido_id bigint references public.pedidos(id) on delete set null,
  codigo text,
  tipo text not null default 'perdido',
  texto text not null,
  visto boolean not null default false,
  creado_en timestamptz not null default now()
);
create index if not exists idx_avisos_empresa on public.avisos_red (empresa_reparto_id, visto, creado_en desc);
create index if not exists idx_avisos_repartidor on public.avisos_red (repartidor_id, visto, creado_en desc);


-- ============================================================
-- 4. LOS PEDIDOS COMPARTIDOS DE MI EMPRESA
--    Lo que puedo repartir hoy sin que sea todavía mío.
-- ============================================================
create or replace function public.puedo_planificar(p_pedido_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.pedidos p
     where p.id = p_pedido_id
       and p.empresa_reparto_id is null
       and p.zona = 'ok'
       and p.estado not in ('entregado','cancelado')
       and public.puedo_ver_cliente(p.cliente_id));
$$;
grant execute on function public.puedo_planificar(bigint) to authenticated;


-- ============================================================
-- 5. ASIGNAR UN REPARTIDOR A UN PEDIDO COMPARTIDO
--    No toca el pedido: escribe el plan de MI empresa.
-- ============================================================
create or replace function public.planificar_pedidos(
  p_ids bigint[], p_repartidor uuid, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_emp bigint;
  v_n   int := 0;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null or not public.es_admin() then
    raise exception 'Solo un administrador de una empresa de reparto puede planificar';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    return jsonb_build_object('planificados', 0);
  end if;

  -- el repartidor tiene que ser de mi empresa
  if p_repartidor is not null and not exists (
        select 1 from public.perfiles pf
         where pf.id = p_repartidor and pf.empresa_reparto_id = v_emp and pf.activo) then
    raise exception 'Ese repartidor no es de tu empresa';
  end if;

  insert into public.plan_reparto (pedido_id, empresa_reparto_id, repartidor_id, nota, creado_por)
  select x.id, v_emp, p_repartidor, p_nota, auth.uid()
    from unnest(p_ids) as x(id)
   where public.puedo_planificar(x.id)
  on conflict (pedido_id, empresa_reparto_id) do update
     set repartidor_id = excluded.repartidor_id,
         nota = excluded.nota,
         creado_por = excluded.creado_por,
         creado_en = now();

  get diagnostics v_n = row_count;
  return jsonb_build_object('planificados', v_n);
end $$;
grant execute on function public.planificar_pedidos(bigint[], uuid, text) to authenticated;


create or replace function public.desplanificar_pedidos(p_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp bigint; v_n int := 0;
begin
  v_emp := public.mi_empresa_reparto();
  if v_emp is null then raise exception 'Tu cuenta no pertenece a ninguna empresa'; end if;
  delete from public.plan_reparto
   where empresa_reparto_id = v_emp and pedido_id = any(p_ids);
  get diagnostics v_n = row_count;
  return jsonb_build_object('sacados', v_n);
end $$;
grant execute on function public.desplanificar_pedidos(bigint[]) to authenticated;


-- ============================================================
-- 6. EL ESCANEO CONFIRMA: el plan ganador se copia al pedido y los
--    demás se descartan, avisándole a quien lo perdió.
-- ============================================================
create or replace function public.reclamar_pedido(
  p_codigo     text default null,
  p_envio_id   text default null,
  p_externo_id text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_emp    bigint;
  v_uid    uuid;
  v_nombre text;
  v_miemp  text;
  v_n      int;
  p        record;
  v_upd    int;
  v_dueno  text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('ok', false, 'motivo', 'Tu sesión se cerró. Volvé a entrar.');
  end if;

  select pf.empresa_reparto_id, pf.nombre into v_emp, v_nombre
    from public.perfiles pf where pf.id = v_uid and pf.activo;

  if v_emp is null then
    return jsonb_build_object('ok', false,
      'motivo', 'Tu cuenta no está asignada a ninguna empresa de reparto. Avisale a tu administrador.');
  end if;
  select nombre into v_miemp from public.empresas_reparto where id = v_emp;

  -- ---------- buscar el pedido ----------
  select count(*) into v_n
    from public.pedidos q
   where (p_codigo     is not null and q.codigo     = p_codigo)
      or (p_envio_id   is not null and q.envio_id   = p_envio_id)
      or (p_externo_id is not null and q.externo_id = p_externo_id
          and (q.empresa_reparto_id is null or q.empresa_reparto_id = v_emp));

  if v_n = 0 then
    return jsonb_build_object('ok', false,
      'motivo', 'No encontramos ese pedido. Puede ser de otro día o de otra empresa.');
  elsif v_n > 1 then
    return jsonb_build_object('ok', false,
      'motivo', 'Ese código coincide con más de un pedido. Escaneá el código ZAS de la etiqueta.');
  end if;

  select * into p
    from public.pedidos q
   where (p_codigo     is not null and q.codigo     = p_codigo)
      or (p_envio_id   is not null and q.envio_id   = p_envio_id)
      or (p_externo_id is not null and q.externo_id = p_externo_id
          and (q.empresa_reparto_id is null or q.empresa_reparto_id = v_emp));

  -- ---------- ya tiene dueño ----------
  if p.empresa_reparto_id is not null then
    if p.empresa_reparto_id = v_emp then
      -- ya era mío (me lo asignó una regla del cliente): el escaneo lo
      -- confirma igual y lo manda a «Mi carga»
      update public.pedidos q
         set cargado_en    = coalesce(q.cargado_en, now()),
             repartidor_id = coalesce(q.repartidor_id, v_uid),
             estado        = case when q.estado = 'pendiente' then 'asignado' else q.estado end
       where q.id = p.id;
      return jsonb_build_object('ok', true, 'ya_era_mio', true,
        'pedido_id', p.id, 'codigo', p.codigo, 'comuna', p.comuna,
        'direccion', p.direccion, 'cliente_final', p.cliente_nombre,
        'mensaje', 'Bulto cargado');
    end if;
    select e.nombre into v_dueno from public.empresas_reparto e where e.id = p.empresa_reparto_id;
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Este pedido es de ' || coalesce(v_dueno,'otra empresa') || '. No lo cargues.');
  end if;

  -- ---------- compartido: ¿lo puedo cargar? ----------
  if p.estado in ('entregado','cancelado') then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Ese pedido ya está ' || p.estado || '.');
  end if;

  if p.zona = 'fuera' then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Va a ' || coalesce(nullif(p.comuna,''),'una comuna') ||
                ', fuera de la zona de reparto. Devolvelo al mesón.');
  elsif p.zona = 'revisar' then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Este pedido no trae comuna. Que la completen antes de cargarlo.');
  end if;

  if not exists (select 1 from public.cliente_empresas ce
                  where ce.cliente_id = p.cliente_id
                    and ce.empresa_reparto_id = v_emp
                    and ce.activo and ce.estado = 'activa') then
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Ese cliente no trabaja con tu empresa.');
  end if;

  -- ---------- cargarlo: un solo UPDATE, gana el primero ----------
  update public.pedidos q
     set empresa_reparto_id  = v_emp,
         repartidor_id       = v_uid,
         tomado_por          = v_uid,
         tomado_en           = now(),
         estado              = case when q.estado = 'pendiente' then 'asignado' else q.estado end,
         vence_asignacion_en = null,
         cargado_en          = now(),
         asignacion_motivo   = 'lo cargó ' || coalesce(v_nombre,'un repartidor') || ' al escanearlo'
   where q.id = p.id
     and q.empresa_reparto_id is null;

  get diagnostics v_upd = row_count;

  if v_upd = 0 then
    select e.nombre into v_dueno
      from public.pedidos q join public.empresas_reparto e on e.id = q.empresa_reparto_id
     where q.id = p.id;
    return jsonb_build_object('ok', false, 'pedido_id', p.id, 'codigo', p.codigo,
      'motivo', 'Se adelantó ' || coalesce(v_dueno,'otra empresa') || '. No lo cargues.');
  end if;

  -- ---------- avisarle a las empresas que lo tenían planificado ----------
  insert into public.avisos_red (empresa_reparto_id, repartidor_id, pedido_id, codigo, tipo, texto)
  select pr.empresa_reparto_id, pr.repartidor_id, p.id, p.codigo, 'perdido',
         'El pedido ' || coalesce(p.codigo,'#'||p.id) ||
         ' (' || coalesce(nullif(p.comuna,''),'sin comuna') || ') lo cargó ' ||
         coalesce(v_miemp,'otra empresa') || ': salió de tu ruta.'
    from public.plan_reparto pr
   where pr.pedido_id = p.id and pr.empresa_reparto_id <> v_emp;

  -- los planes sobre este pedido ya no valen
  delete from public.plan_reparto where pedido_id = p.id;

  insert into public.pool_movimientos (pedido_id, empresa_reparto_id, accion, usuario_id, nota)
  values (p.id, v_emp, 'tomado', v_uid, 'cargado al escanear la etiqueta');

  return jsonb_build_object('ok', true, 'ya_era_mio', false,
    'pedido_id', p.id, 'codigo', p.codigo, 'comuna', p.comuna,
    'direccion', p.direccion, 'cliente_final', p.cliente_nombre,
    'mensaje', 'Lo cargaste: ya es tuyo');
end $$;
grant execute on function public.reclamar_pedido(text, text, text) to authenticated;


-- ============================================================
-- 7. SEGURIDAD
-- ============================================================
alter table public.plan_reparto enable row level security;
alter table public.avisos_red   enable row level security;

drop policy if exists plan_super on public.plan_reparto;
create policy plan_super on public.plan_reparto for all
  using (public.es_superadmin()) with check (public.es_superadmin());

-- el administrador arma el plan de SU empresa
drop policy if exists plan_empresa on public.plan_reparto;
create policy plan_empresa on public.plan_reparto for all
  using (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto())
  with check (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto());

-- el repartidor ve lo que le planificaron (para saber qué ir a buscar)
drop policy if exists plan_repartidor on public.plan_reparto;
create policy plan_repartidor on public.plan_reparto for select
  using (repartidor_id = auth.uid());

drop policy if exists avisos_select on public.avisos_red;
create policy avisos_select on public.avisos_red for select
  using (public.es_superadmin()
      or repartidor_id = auth.uid()
      or (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto()));

drop policy if exists avisos_update on public.avisos_red;
create policy avisos_update on public.avisos_red for update
  using (repartidor_id = auth.uid()
      or (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto()))
  with check (true);

grant select, insert, update, delete on public.plan_reparto to authenticated;
grant select, update                 on public.avisos_red   to authenticated;


-- ============================================================
-- 8. EL MOTIVO YA NO HABLA DE «POOL»
-- ============================================================
create or replace function public.fn_asignar_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_mia bigint; v_n int; v_activas int; v_todas_pct boolean;
  v_elegida bigint; v_empates int; v_prio int;
begin
  new.zona := public.zona_de(new.comuna);

  select count(*) into v_activas from public.cliente_empresas ce
   where ce.cliente_id = new.cliente_id and ce.activo and ce.estado = 'activa';

  if new.empresa_reparto_id is not null then
    new.tomado_en := coalesce(new.tomado_en, now());
    new.asignacion_motivo := coalesce(new.asignacion_motivo, 'asignada al cargar el pedido');
    new.vence_asignacion_en := null;
    return new;
  end if;

  v_mia := public.mi_empresa_reparto();

  if new.cliente_id is null then
    new.empresa_reparto_id := v_mia;
    if v_mia is not null then
      new.tomado_en := now();
      new.asignacion_motivo := 'pedido cargado a mano';
    end if;
    return new;
  end if;

  if v_mia is not null and public.puedo_ver_cliente(new.cliente_id) then
    new.empresa_reparto_id := v_mia;
    new.tomado_en := now();
    new.asignacion_motivo := 'lo cargó tu empresa'
      || case when new.zona = 'fuera' then ' (ojo: fuera de la zona de cobertura)' else '' end;
    return new;
  end if;

  if new.zona = 'fuera' then
    new.asignacion_motivo := 'fuera de la zona de cobertura ('
      || coalesce(nullif(new.comuna,''), 'sin comuna') || '): ninguna empresa reparte ahí';
    return new;
  elsif new.zona = 'revisar' then
    new.asignacion_motivo := 'llegó sin comuna: hay que completarla para poder repartirlo';
    return new;
  end if;

  if v_activas = 0 then
    new.asignacion_motivo := 'el cliente todavía no habilitó ninguna empresa';
    return new;
  end if;

  if v_activas = 1 then
    select ce.empresa_reparto_id into v_elegida from public.cliente_empresas ce
     where ce.cliente_id = new.cliente_id and ce.activo and ce.estado = 'activa';
    new.empresa_reparto_id := v_elegida;
    new.tomado_en := now();
    new.asignacion_motivo := 'única empresa habilitada por el cliente';
    return new;
  end if;

  -- el cliente eligió que se lo lleve el que lo cargue
  if coalesce((select modo_reparto from public.clientes where id = new.cliente_id), 'reglas') = 'abierto' then
    new.asignacion_motivo := 'el cliente lo dejó abierto: se lo lleva quien lo cargue';
    return new;
  end if;

  select count(*), coalesce(bool_and(porcentaje is not null), false)
    into v_n, v_todas_pct
    from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido);

  if v_n = 0 then
    new.asignacion_motivo := 'ninguna empresa cubre ' ||
      coalesce(nullif(new.comuna,''), 'esa comuna') || ': se lo lleva quien lo cargue';
  elsif v_n = 1 then
    select c.empresa_reparto_id into v_elegida
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c;
    new.empresa_reparto_id := v_elegida;
    new.asignacion_motivo := 'regla del cliente para ' || coalesce(nullif(new.comuna,''), 'esa comuna');
  elsif v_todas_pct then
    select c.empresa_reparto_id into v_elegida
      from public.candidatas_reparto(new.cliente_id, new.comuna, new.fecha_pedido) c
     order by c.atraso desc, c.prioridad, c.empresa_reparto_id limit 1;
    new.empresa_reparto_id := v_elegida;
    new.asignacion_motivo := 'reparto por porcentaje';
  else
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
      new.asignacion_motivo := v_empates || ' empresas calzan parejo: se lo lleva quien lo cargue';
    end if;
  end if;

  if new.empresa_reparto_id is not null then
    new.tomado_en := now();
    new.vence_asignacion_en := null;
  end if;
  return new;
end $$;


-- ============================================================
-- COMPROBACIÓN
-- ============================================================
select
  (select count(*) from public.clientes where modo_reparto='abierto')     as clientes_modo_abierto,
  (select count(*) from public.clientes where modo_reparto='reglas')      as clientes_por_reglas,
  (select count(*) from public.pedidos
    where empresa_reparto_id is null and zona='ok')                       as pedidos_compartidos,
  (select count(*) from public.plan_reparto)                              as planes_armados,
  (select count(*) from public.avisos_red where not visto)                as avisos_sin_ver,
  (select count(*) from public.pedidos where cargado_en is not null)      as ya_cargados;
