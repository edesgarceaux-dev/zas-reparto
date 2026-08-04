-- ============================================================
-- PROBAR EL REPARTO POR REGLAS
--
-- ✅ NO HAY QUE EDITAR NADA. Pegalo entero y apretá Run.
--
-- Mete 3 pedidos de prueba entrando COMO SI VINIERAN DE JUMPSELLER
-- (sin usuario), que es la única forma de probar las reglas: un pedido
-- que cargás vos desde el panel se lo queda tu empresa y listo.
--
--   · uno en la primera comuna de la empresa A
--   · uno en la primera comuna de la empresa B
--   · uno en una comuna que no le diste a nadie  → tiene que ir al pool
--
-- Al final te muestra dónde cayó cada uno y por qué.
-- Los pedidos quedan con el código ZAS-… y el nombre "PRUEBA RED".
-- Abajo de todo está la línea para borrarlos cuando termines.
--
-- ANTES DE CORRERLO: entrá al portal del cliente → Mis empresas de
-- reparto → poné las comunas de cada empresa y apretá "Guardar reglas".
-- ============================================================

do $$
declare
  v_cli     bigint;
  v_nom     text;
  v_n       int;
  v_lista   text;
  v_comunas text[];
  v_c       text;
begin
  -- ---------- el cliente que tiene 2 o más empresas activas ----------
  select count(*), string_agg(x.nombre, ', ')
    into v_n, v_lista
    from (select c.id, c.nombre
            from public.clientes c
           where (select count(*) from public.cliente_empresas ce
                   where ce.cliente_id = c.id and ce.estado='activa' and ce.activo) >= 2) x;

  if v_n = 0 then
    raise exception 'Ningún cliente tiene 2 o más empresas activas todavía. Aceptá primero la invitación.';
  elsif v_n > 1 then
    raise exception 'Hay % clientes con varias empresas (%). Esta prueba sirve para uno solo.', v_n, v_lista;
  end if;

  select c.id, c.nombre into v_cli, v_nom
    from public.clientes c
   where (select count(*) from public.cliente_empresas ce
           where ce.cliente_id = c.id and ce.estado='activa' and ce.activo) >= 2;

  -- ---------- una comuna de cada empresa ----------
  select array_agg(x.comuna) into v_comunas from (
    select (ce.comunas)[1] as comuna
      from public.cliente_empresas ce
     where ce.cliente_id = v_cli and ce.estado='activa' and ce.activo
       and coalesce(array_length(ce.comunas,1),0) > 0
     order by ce.empresa_reparto_id) x;

  if coalesce(array_length(v_comunas,1),0) = 0 then
    raise exception 'El cliente % no tiene ninguna comuna asignada. Entrá a su portal, poné las comunas de cada empresa y apretá "Guardar reglas".', v_nom;
  end if;

  -- ---------- los pedidos de prueba ----------
  foreach v_c in array v_comunas loop
    insert into public.pedidos (cliente_nombre, direccion, comuna, cliente_id, origen, detalle)
    values ('PRUEBA RED', 'Calle de Prueba 123', v_c, v_cli, 'integracion', 'pedido de prueba del reparto');
  end loop;

  -- uno que no cubre nadie
  insert into public.pedidos (cliente_nombre, direccion, comuna, cliente_id, origen, detalle)
  values ('PRUEBA RED', 'Calle de Prueba 456', 'Comuna Que Nadie Cubre', v_cli, 'integracion', 'pedido de prueba del reparto');

  raise notice 'Listo: % pedidos de prueba para %.', array_length(v_comunas,1) + 1, v_nom;
end $$;


-- ---------- resultado ----------
select p.codigo,
       p.comuna,
       coalesce(e.nombre, '📥 POOL (libre para quien lo tome)') as le_toco_a,
       p.asignacion_motivo,
       case
         when p.empresa_reparto_id is not null
           then '✅ se asignó sola por la regla del cliente'
         else '✅ nadie la cubre: quedó en el pool, como corresponde'
       end                                                     as resultado
  from public.pedidos p
  left join public.empresas_reparto e on e.id = p.empresa_reparto_id
 where p.cliente_nombre = 'PRUEBA RED'
 order by p.id;


-- ---------- las reglas que se usaron, por si algo no calzó ----------
select e.nombre                                   as empresa,
       coalesce(array_to_string(ce.comunas, ', '), '') as comunas,
       ce.cuota_diaria,
       ce.porcentaje,
       ce.prioridad
  from public.cliente_empresas ce
  join public.empresas_reparto e on e.id = ce.empresa_reparto_id
 where ce.estado = 'activa' and ce.activo
   and ce.cliente_id = (select c.id from public.clientes c
                         where (select count(*) from public.cliente_empresas x
                                 where x.cliente_id = c.id and x.estado='activa' and x.activo) >= 2
                         limit 1)
 order by ce.prioridad, e.nombre;


-- ============================================================
-- PARA BORRAR LOS PEDIDOS DE PRUEBA cuando termines,
-- corré solo esta línea (sacale los dos guiones del principio):
--
-- delete from public.pedidos where cliente_nombre = 'PRUEBA RED';
-- ============================================================
