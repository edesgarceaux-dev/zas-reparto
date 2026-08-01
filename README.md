# ZAS Reparto

Sistema de gestión de pedidos y reparto: aplicación Android para administrador y repartidores + panel de control web, conectados a la misma base de datos Supabase en tiempo real.

## Estructura

| Carpeta / archivo | Qué es |
|---|---|
| `app-android/` | Código fuente de la app (Flutter). Login por rol: administrador o repartidor. |
| `panel/panel-zas.html` | Panel de control web (archivo autónomo, se abre con doble clic). |
| `index.html` | Copia del panel para publicar con GitHub Pages. |
| `supabase/esquema.sql` | Esquema completo de la base de datos (tablas, seguridad RLS, triggers). |
| `ZAS-Reparto-v1.0.apk` | Instalador Android listo (etapa 1). |

## Backend

Supabase — proyecto `zas-reparto` (región São Paulo). El esquema ya está aplicado; `esquema.sql` sirve como respaldo para recrearlo si hiciera falta.

## Recompilar el APK

Requiere Flutter 3.32+. Desde `app-android/`:

```
flutter pub get
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://racwaageoajxaxzqtjio.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon key del proyecto>
```

## Estados de un pedido

pendiente → asignado → aceptado → en_camino → entregado (o no_entregado / cancelado)

## Hoja de ruta

- [x] Etapa 1: pedidos, asignación, estados en tiempo real, panel web
- [ ] Etapa 2: GPS de repartidores en mapa + prueba de entrega con foto/firma
- [ ] Notificaciones push con app cerrada (Firebase FCM)
- [ ] Etapa 3: importación desde Excel + reportes
