-- ============================================================
--  MIGRACIÓN — Cola offline idempotente (app v2.9.2)
--  Objetivo: que reintentar un cierre a medio subir NO cree filas
--  repetidas en entregas_prueba.
--
--  La app pone un identificador estable (cola_uid) por cada trabajo
--  de la cola y hace upsert con ON CONFLICT (cola_uid) DO NOTHING.
--  Para que ese ON CONFLICT funcione hace falta:
--    1. la columna entregas_prueba.cola_uid
--    2. un índice ÚNICO NO parcial sobre esa columna
--
--  Idempotente: se puede correr varias veces sin romper.
--  Requisitos: ninguno (solo la tabla entregas_prueba ya existente).
-- ============================================================

begin;

-- 1) Columna que guarda la identidad del trabajo de la cola.
alter table public.entregas_prueba
  add column if not exists cola_uid text;

-- 2) Índice único para que ON CONFLICT (cola_uid) matchee.
--    Debe ser un índice único NO parcial: Postgres solo usa como
--    árbitro de ON CONFLICT un índice único total sobre la columna.
--    Las filas viejas (cola_uid NULL) no chocan entre sí porque en un
--    índice único los NULL se consideran distintos.
create unique index if not exists ux_entregas_cola_uid
  on public.entregas_prueba (cola_uid);

commit;

-- ------------------------------------------------------------
-- Verificación rápida (opcional, no rompe nada):
--   select column_name from information_schema.columns
--     where table_name='entregas_prueba' and column_name='cola_uid';
--   select indexname from pg_indexes
--     where tablename='entregas_prueba' and indexname='ux_entregas_cola_uid';
-- ------------------------------------------------------------
