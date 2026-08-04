-- ============================================================
-- ¿POR QUÉ HAY QUE SINCRONIZAR LOS ENVÍOS DE MERCADOLIBRE A MANO?
--
-- Pegá esto entero en el SQL Editor y apretá Run. No cambia nada.
-- La consulta IMPORTANTE es la última: es la que queda en pantalla.
--
-- QUÉ ESTAMOS MIRANDO
-- La función ml-notif ya guarda el n° de ENVÍO (envio_id) apenas entra la
-- venta. Si las ventas NUEVAS siguen llegando sin envio_id, es que esa
-- versión de la función no está desplegada en Supabase.
-- ============================================================

-- ---------- ¿la cuenta de MercadoLibre sigue conectada? ----------
select c.nombre as cliente, m.ml_user_id, m.expires_en,
       case when m.expires_en > now() then 'token vigente'
            else 'token vencido: se renueva solo al llegar una venta' end as estado
  from public.ml_cuentas m
  left join public.clientes c on c.id = m.cliente_id;


-- ---------- el total, para saber cuánto falta rellenar ----------
select count(*)                                          as ventas_ml_totales,
       count(*) filter (where envio_id is null)          as les_falta_el_envio,
       min(fecha_pedido) filter (where envio_id is null) as la_mas_vieja_sin_envio,
       max(fecha_pedido) filter (where envio_id is null) as la_mas_nueva_sin_envio
  from public.pedidos
 where origen = 'mercadolibre';


-- ============================================================
-- ⬇️⬇️  ESTA ES LA QUE IMPORTA — la que te queda en pantalla  ⬇️⬇️
--
-- Mirá la columna DIAGNOSTICO de los días de arriba (los más nuevos):
--   · «OK»                    → ml-notif está al día, no toques nada
--   · «ml-notif no está al día» → hay que volver a desplegar la función
--   · «se perdieron notificaciones» → ml-notif anda, pero MercadoLibre no
--      avisó de algunas: eso lo arregla migracion-ml-automatico.sql
-- ============================================================
select p.fecha_pedido,
       count(*)                                       as ventas_ml,
       count(*) filter (where p.envio_id is not null) as con_n_de_envio,
       count(*) filter (where p.envio_id is null)     as sin_n_de_envio,
       case
         when count(*) filter (where p.envio_id is null) = 0
           then 'OK · entraron completas'
         when count(*) filter (where p.envio_id is not null) = 0
           then 'ml-notif no está al día: hay que redesplegarla'
         else 'se perdieron notificaciones de ML en algunas'
       end                                            as diagnostico
  from public.pedidos p
 where p.origen = 'mercadolibre'
   and p.fecha_pedido >= (now() at time zone 'America/Santiago')::date - 10
 group by p.fecha_pedido
 order by p.fecha_pedido desc;
