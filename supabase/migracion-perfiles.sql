-- ============================================================
-- APLICACION ZAS - Migración: ficha completa del repartidor
-- Ejecutar en: Supabase Dashboard -> SQL Editor -> New query -> Run
-- ============================================================

-- Datos de contacto del repartidor (editables desde el panel)
alter table public.perfiles add column if not exists direccion text;
alter table public.perfiles add column if not exists correo text;
-- Comuna de preferencia: "Repartir auto" intenta darle el sector de esa comuna
alter table public.perfiles add column if not exists comuna_preferida text;

-- Rellenar el correo de contacto con el correo de acceso actual
update public.perfiles p
set correo = u.email
from auth.users u
where u.id = p.id and p.correo is null;
