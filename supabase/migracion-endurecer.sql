-- ============================================================
-- ENDURECIMIENTO  (auditoría 06-08-2026)
--
-- Correr en el SQL Editor del proyecto de ZAS. Seguro repetirlo.
-- Va al final, después de las demás migraciones.
--
-- QUÉ CIERRA
--   1. El repartidor podía editar CUALQUIER campo de sus pedidos (monto,
--      dirección, teléfono, hasta la empresa) desde la consola del navegador.
--      Ahora solo puede tocar estado / nota_entrega / motivo_no_entrega.
--   2. candidatas_reparto (qué empresas, prioridades y volúmenes atienden a
--      un cliente) era ejecutable por cualquier repartidor → inteligencia
--      competitiva. Se revoca (los triggers la siguen usando internamente).
--   3. avisos_update tenía with check(true): un aviso podía saltar de empresa.
--   4. 5 funciones security definer sin search_path fijo (endurecimiento).
--   5. Índice faltante en entregas_prueba(pedido_id).
--   6. Token de seguimiento débil (10 chars de md5(random())) → 32 hex de
--      gen_random_bytes para los pedidos NUEVOS (los viejos no se tocan para
--      no invalidar links ya enviados).
--   7. Política DELETE para las fotos de entrega (habilita el borrado real;
--      la privacidad del bucket va en el paso siguiente).
-- ============================================================


-- ============================================================
-- 1. EL REPARTIDOR SOLO MUEVE ESTADO / NOTA / MOTIVO
--    La RLS ya limita QUÉ filas ve (las suyas). Esto limita QUÉ columnas
--    puede cambiar. Admin y superadmin no se tocan; el backend (auth.uid
--    null) tampoco.
-- ============================================================
create or replace function public.fn_frenar_pedido_repartidor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;          -- backend / triggers
  if public.es_admin() or public.es_superadmin() then return new; end if;

  -- si quien edita es el repartidor del pedido, vigilamos las columnas
  if old.repartidor_id is not distinct from auth.uid() then
    if new.monto              is distinct from old.monto
    or new.direccion          is distinct from old.direccion
    or new.comuna             is distinct from old.comuna
    or new.cliente_nombre     is distinct from old.cliente_nombre
    or new.cliente_telefono   is distinct from old.cliente_telefono
    or new.cliente_id         is distinct from old.cliente_id
    or new.empresa_reparto_id is distinct from old.empresa_reparto_id
    or new.repartidor_id      is distinct from old.repartidor_id
    or new.fecha_pedido       is distinct from old.fecha_pedido
    or new.externo_id         is distinct from old.externo_id
    or new.envio_id           is distinct from old.envio_id
    or new.codigo             is distinct from old.codigo then
      raise exception 'Un repartidor solo puede cambiar el estado y la nota de entrega de su pedido.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists tr_frenar_pedido_repartidor on public.pedidos;
create trigger tr_frenar_pedido_repartidor
  before update on public.pedidos
  for each row execute function public.fn_frenar_pedido_repartidor();


-- ============================================================
-- 2. candidatas_reparto deja de ser ejecutable por cualquiera
--    (los triggers que la usan corren como definer: siguen andando)
-- ============================================================
revoke execute on function public.candidatas_reparto(bigint, text, date) from public, anon, authenticated;


-- ============================================================
-- 3. avisos_update: no se puede mover un aviso de empresa/repartidor
-- ============================================================
drop policy if exists avisos_update on public.avisos_red;
create policy avisos_update on public.avisos_red for update
  using (repartidor_id = auth.uid()
      or (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto()))
  with check (repartidor_id = auth.uid()
      or (public.es_admin() and empresa_reparto_id = public.mi_empresa_reparto()));


-- ============================================================
-- 4. search_path fijo en las funciones definer que faltaban
--    (ALTER no reescribe el cuerpo: es seguro y no cambia la lógica)
-- ============================================================
alter function public.es_admin()                       set search_path = public;
alter function public.fn_log_estado()                  set search_path = public;
alter function public.fn_nuevo_usuario()               set search_path = public;
alter function public.cliente_de_usuario()             set search_path = public;
alter function public.seguimiento_publico(text, text)  set search_path = public;


-- ============================================================
-- 5. Índice para reporte_periodo / uso_fotos / policies por fila
-- ============================================================
create index if not exists idx_entregas_prueba_pedido
  on public.entregas_prueba (pedido_id);


-- ============================================================
-- 6. Token de seguimiento fuerte para los pedidos NUEVOS
--    (32 hex aleatorios; los existentes se dejan como están para no
--     romper links ya enviados a clientes finales)
-- ============================================================
alter table public.pedidos
  alter column token_seguimiento set default encode(gen_random_bytes(16), 'hex');


-- ============================================================
-- 7. Política DELETE para las fotos de entrega
--    (deja borrar de verdad; la privacidad del bucket va aparte)
-- ============================================================
drop policy if exists "borrar fotos entregas" on storage.objects;
create policy "borrar fotos entregas" on storage.objects
  for delete to authenticated
  using (bucket_id = 'entregas' and public.es_admin());


-- ============================================================
-- COMPROBACIÓN
-- ============================================================
select
  (select count(*) from pg_trigger where tgname='tr_frenar_pedido_repartidor')          as guardia_repartidor,   -- 1
  (select not has_function_privilege('authenticated',
     'public.candidatas_reparto(bigint,text,date)','execute'))                            as candidatas_cerrada,   -- true
  (select count(*) from pg_indexes where indexname='idx_entregas_prueba_pedido')          as indice_fotos,         -- 1
  (select pg_get_expr(adbin, adrelid) from pg_attrdef d
     join pg_attribute a on a.attrelid=d.adrelid and a.attnum=d.adnum
    where a.attrelid='public.pedidos'::regclass and a.attname='token_seguimiento')        as token_default;        -- gen_random_bytes
