-- ============================================================
-- QUE «SANTIAGO CENTRO» NO QUEDE FUERA DE ZONA
--
-- Correr en el SQL Editor. Es seguro repetirlo.
-- Va DESPUÉS de migracion-zona-cobertura.sql.
--
-- QUÉ PASABA
-- ----------
-- La lista de comunas que repartís dice «Santiago». MercadoLibre y las
-- tiendas mandan «Santiago Centro». La comparación era EXACTA, así que no
-- calzaban y el pedido quedaba marcado «fuera de la zona de reparto»: el
-- repartidor lo escaneaba y le salía «Devolvelo al mesón», con el bulto
-- en la mano y la dirección a diez cuadras.
--
-- Lo mismo con «Comuna de Maipú», «Ñuñoa, Región Metropolitana», «PAC»,
-- «Til Til» y una docena más de formas de escribir lo mismo.
--
-- QUÉ HACE ESTO
-- -------------
-- 1. La comparación ahora limpia el nombre antes de comparar: le saca
--    «comuna de», la región, el país, y los sinónimos conocidos.
-- 2. Recalcula la zona de TODOS los pedidos que ya estaban guardados, así
--    los que quedaron mal marcados se arreglan solos.
-- 3. Deja una consulta al final para ver si quedó alguna comuna sin
--    reconocer, y poder agregarla desde el panel maestro.
-- ============================================================


-- ============================================================
-- 1. CÓMO SE ESCRIBE DE VERDAD CADA COMUNA
--
-- A la izquierda, lo que llega de las tiendas. A la derecha, el nombre
-- oficial que está en la lista de cobertura.
-- Para agregar una nueva: sumala a esta lista y volvé a correr el archivo.
-- ============================================================
create or replace function public.comuna_canonica(p_comuna text)
returns text language plpgsql immutable set search_path = public as $$
declare
  v text;
begin
  v := public.norm_txt(p_comuna);
  if v = '' then return ''; end if;

  -- sacarle los adornos: "comuna de X", "X, region metropolitana", "X - RM"
  v := regexp_replace(v, '^(comuna|ciudad|municipio)\s+(de\s+|del\s+)?', '');
  v := regexp_replace(v, '[,\-–/]\s*(region\s+)?metropolitana.*$', '');
  v := regexp_replace(v, '[,\-–/]\s*(rm|r\.m\.?|chile|santiago|stgo\.?)\s*$', '');
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := trim(v);

  -- los sinónimos que se ven en la calle
  return case v
    when 'santiago centro'    then 'santiago'
    when 'stgo centro'        then 'santiago'
    when 'stgo'               then 'santiago'
    when 'centro'             then 'santiago'
    when 'santiago de chile'  then 'santiago'
    when 'estacion central'   then 'estacion central'
    when 'est central'        then 'estacion central'
    when 'pac'                then 'pedro aguirre cerda'
    when 'p aguirre cerda'    then 'pedro aguirre cerda'
    when 'til til'            then 'tiltil'
    when 'san jose maipo'     then 'san jose de maipo'
    when 'san jose'           then 'san jose de maipo'
    when 'penalolen'          then 'penalolen'
    when 'la florida stgo'    then 'la florida'
    when 'puente alto stgo'   then 'puente alto'
    when 'maipu stgo'         then 'maipu'
    when 'nunoa stgo'         then 'nunoa'
    when 'san bdo'            then 'san bernardo'
    when 'san bernando'       then 'san bernardo'   -- error de tipeo frecuente
    when 'quilicura stgo'     then 'quilicura'
    when 'lo barnechea stgo'  then 'lo barnechea'
    when 'padre hurtado'      then 'padre hurtado'
    when 'el monte'           then 'el monte'
    else v
  end;
end $$;
grant execute on function public.comuna_canonica(text) to authenticated, anon;


-- ============================================================
-- 2. LA COMPARACIÓN, AHORA TOLERANTE
-- ============================================================
create or replace function public.zona_de(p_comuna text)
returns text language sql stable security definer set search_path = public as $$
  select case
    when (select coalesce(array_length(comunas_cobertura,1),0) from public.config_red) = 0
      then 'ok'                                   -- sin lista cargada, no se bloquea nada
    when public.norm_txt(p_comuna) = ''
      then 'revisar'                              -- llegó sin comuna
    when exists (select 1 from public.config_red r, unnest(r.comunas_cobertura) x
                  where public.comuna_canonica(x) = public.comuna_canonica(p_comuna))
      then 'ok'
    else 'fuera'
  end;
$$;
grant execute on function public.zona_de(text) to authenticated;


-- ============================================================
-- 3. ARREGLAR LOS PEDIDOS QUE YA ESTABAN MAL MARCADOS
--
-- Solo se tocan los que CAMBIAN de zona, y solo la columna `zona`: no se
-- reasigna nada ni se mueve ningún pedido de empresa.
-- ============================================================
do $$
declare v_n int;
begin
  with recalculo as (
    select p.id, p.zona as antes, public.zona_de(p.comuna) as ahora
      from public.pedidos p
  )
  update public.pedidos p
     set zona = r.ahora
    from recalculo r
   where p.id = r.id and p.zona is distinct from r.ahora;
  get diagnostics v_n = row_count;
  raise notice 'Pedidos con la zona corregida: %', v_n;
end $$;


-- ============================================================
-- COMPROBACIÓN 1 — que los casos típicos ahora entren
-- ============================================================
select nombre_que_llega,
       public.zona_de(nombre_que_llega) as zona
  from (values
    ('Santiago Centro'), ('santiago centro'), ('SANTIAGO'),
    ('Comuna de Maipú'), ('Ñuñoa, Región Metropolitana'),
    ('Estacion Central'), ('PAC'), ('Til Til'), ('San Bernando'),
    ('Puente Alto'), ('Rancagua'), ('Valparaíso')
  ) as v(nombre_que_llega);
-- Todas tienen que dar 'ok' menos Rancagua y Valparaíso, que sí están fuera.


-- ============================================================
-- COMPROBACIÓN 2 — ⬇️ ESTA ES LA QUE QUEDA EN PANTALLA ⬇️
--
-- Las comunas de tus pedidos que el sistema NO reconoce. Si ves alguna
-- que sí repartís, agregala en el panel maestro → Zona de cobertura
-- (o sumá el sinónimo a la lista del punto 1 y volvé a correr esto).
-- ============================================================
select p.comuna                          as comuna_que_no_reconoce,
       count(*)                          as pedidos,
       max(p.fecha_pedido)               as el_mas_reciente
  from public.pedidos p
 where public.zona_de(p.comuna) = 'fuera'
 group by p.comuna
 order by count(*) desc
 limit 40;
