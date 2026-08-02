-- ============================================================
-- APLICACION ZAS - Migración: prueba de entrega completa + fotos
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================

-- Datos del receptor y las 3 fotos exigidas
alter table public.entregas_prueba add column nombre_recibe text;
alter table public.entregas_prueba add column rut_recibe text;
alter table public.entregas_prueba add column foto_domicilio text;  -- fachada con el número visible
alter table public.entregas_prueba add column foto_pedido text;     -- el pedido
alter table public.entregas_prueba add column foto_receptor text;   -- persona con el pedido en mano

-- Bucket de almacenamiento para las fotos (lectura pública por URL)
insert into storage.buckets (id, name, public)
values ('entregas', 'entregas', true)
on conflict (id) do nothing;

-- Usuarios conectados pueden subir; cualquiera con la URL puede ver
create policy "subir fotos entregas" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'entregas');
create policy "leer fotos entregas" on storage.objects
  for select using (bucket_id = 'entregas');
