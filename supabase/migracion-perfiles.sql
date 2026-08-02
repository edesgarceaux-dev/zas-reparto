-- ============================================================
-- APLICACION ZAS - Migración: ficha completa del repartidor
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================

-- Datos de contacto del repartidor (editables desde el panel)
alter table public.perfiles add column if not exists direccion text;
alter table public.perfiles add column if not exists correo text;
-- Comunas de preferencia (separadas por coma): "Repartir auto" intenta darle esos sectores
alter table public.perfiles add column if not exists comuna_preferida text;

-- Punto de término propio de cada repartidor (la ruta cierra hacia ahí, ej: su casa)
alter table public.perfiles add column if not exists termino_lat double precision;
alter table public.perfiles add column if not exists termino_lng double precision;
alter table public.perfiles add column if not exists termino_nombre text;

-- Rellenar el correo de contacto con el correo de acceso actual
update public.perfiles p
set correo = u.email
from auth.users u
where u.id = p.id and p.correo is null;
