-- ============================================================
-- MERCADOLIBRE EN PILOTO AUTOMÁTICO
--
-- Deja de hacer falta apretar «🔄 Sincronizar envíos ML»: Supabase llama
-- solo a la función ml-backfill cada 15 minutos y rellena el n° de envío
-- de cualquier venta Flex que le falte.
--
-- POR QUÉ HACE FALTA IGUAL, aunque ml-notif ya lo guarde
-- -----------------------------------------------------
-- MercadoLibre a veces no manda la notificación, o la manda antes de que
-- el envío exista. Esta tarea es la red de seguridad: cada 15 minutos
-- barre lo que quedó sin n° de envío y lo completa. Si no hay nada que
-- hacer, no hace nada.
--
-- ⬇️ ANTES DE CORRER: hay UNA línea para cambiar, marcada más abajo.
--    Necesitás el valor del secreto WEBHOOK_TOKEN, el mismo que ya usás.
--    Está en Supabase → Project Settings → Edge Functions → Secrets.
--
-- Supabase → SQL Editor → New query → pegar → cambiar la línea → Run.
-- Es seguro correrlo más de una vez: reemplaza la tarea anterior.
-- ============================================================

-- ---------- 1. las dos extensiones que hacen falta ----------
-- pg_cron: programa tareas dentro de la base
-- pg_net : le deja hacer llamadas HTTP
create extension if not exists pg_cron;
create extension if not exists pg_net;


-- ---------- 2. la tarea ----------
do $$
declare
  -- ⬇️⬇️⬇️  CAMBIÁ ESTA LÍNEA  ⬇️⬇️⬇️
  v_token   text := 'PEGA-ACA-TU-WEBHOOK_TOKEN';
  -- ⬆️⬆️⬆️                      ⬆️⬆️⬆️

  v_url     text := 'https://racwaageoajxaxzqtjio.supabase.co/functions/v1/ml-backfill';
  v_llamada text;
begin
  if v_token = 'PEGA-ACA-TU-WEBHOOK_TOKEN' or length(v_token) < 8 then
    raise exception 'Falta poner el WEBHOOK_TOKEN en la línea marcada. Lo sacás de Supabase → Project Settings → Edge Functions → Secrets.';
  end if;

  -- si ya existía, la sacamos para no duplicarla
  begin
    perform cron.unschedule('zas-ml-envios');
  exception when others then null;
  end;

  v_llamada := format(
    'select net.http_get(url := %L, timeout_milliseconds := 25000);',
    v_url || '?token=' || v_token || '&limite=300&dias=30');

  perform cron.schedule('zas-ml-envios', '*/15 * * * *', v_llamada);

  raise notice 'Listo: ZAS va a rellenar los n° de envío de MercadoLibre cada 15 minutos.';
end $$;


-- ---------- 3. comprobar que quedó programada ----------
select jobid, jobname, schedule, active
  from cron.job
 where jobname = 'zas-ml-envios';
-- Tiene que aparecer una fila con schedule = */15 * * * * y active = true.


-- ---------- 4. ver si corrió bien (mirá esto en 15-20 minutos) ----------
-- select jobid, status, return_message, start_time
--   from cron.job_run_details
--  where jobid = (select jobid from cron.job where jobname = 'zas-ml-envios')
--  order by start_time desc limit 5;


-- ============================================================
-- PARA APAGARLA, si alguna vez molesta:
--   select cron.unschedule('zas-ml-envios');
-- ============================================================
