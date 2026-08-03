# Arreglar el escaneo de etiquetas MercadoLibre Flex

## El problema (lo que descubrió Etienne)

El QR de la etiqueta de MercadoLibre Flex trae el **n° de ENVÍO** (shipment).
Pero ZAS solo guardaba el **n° de ORDEN**, que es el largo que empieza en
`2000…` y que en el panel se ve como "Cód. envío: #ML-2000017717158596".

Son dos números distintos, de la misma venta. Como no coincidían, la app decía
*"este bulto no es de tu ruta"* aunque el bulto sí fuera correcto.

La solución es guardar también el n° de envío, en la columna `pedidos.envio_id`.

---

## Los 3 pasos (en este orden)

### 1. Crear la columna
Supabase → **SQL Editor** → New query → pegar el contenido de
`migracion-envio.sql` → **Run**.

```sql
alter table public.pedidos add column if not exists envio_id text;
```

### 2. Actualizar el receptor de ventas nuevas
Supabase → **Edge Functions** → función **`ml-notif`** → pegar el contenido
actualizado de `funcion-ml-notif.ts` → **Deploy**.

Esto hace que **de aquí en adelante** toda venta Flex que entre guarde su n° de
envío sola. (Ojo: esto NO arregla las ventas que ya estaban, para eso es el
paso 3.)

### 3. Rellenar las ventas que ya estaban ← **este es el que faltaba**
Supabase → **Edge Functions** → *Deploy a new function* → Via Editor
→ nombre: **`ml-backfill`** → pegar el contenido de `funcion-ml-backfill.ts`
→ **Deploy** → y **desactivar "Verify JWT"**.

Después, abrir esta dirección en el navegador (reemplazando el token por el
valor del secreto `WEBHOOK_TOKEN`):

```
https://racwaageoajxaxzqtjio.supabase.co/functions/v1/ml-backfill?token=TU_WEBHOOK_TOKEN
```

La función le pregunta a MercadoLibre, una por una, cuál es el envío de cada
venta antigua, y lo guarda. Responde algo así:

```json
{
  "ok": true,
  "revisados": 42,
  "actualizados": 42,
  "mensaje": "Listo: 42 venta(s) de MercadoLibre ya se pueden escanear con la etiqueta Flex."
}
```

Se puede correr **las veces que sea**: solo toca las que todavía les falta.
Si dice `"siguiente": "Quedaban más pendientes…"`, abrir la misma dirección de
nuevo hasta que diga que no queda ninguna.

Parámetros opcionales:
- `&limite=500` — cuántas revisar de una pasada (por defecto 300, máximo 1000)
- `&dias=90` — solo las de los últimos 90 días

---

## Cómo saber que quedó bien

- En la app (v2.4.2 o superior), escanear una etiqueta Flex: debe sonar el bip
  y sumar al contador.
- Si todavía faltara sincronizar, la app ahora lo dice claro en vez de culpar al
  bulto: *"Etiqueta Flex leída OK, pero a tus ventas de MercadoLibre les falta
  el n° de envío en el sistema — avisa a la oficina"*.

## Nota

Las ventas Flex muy antiguas que MercadoLibre ya no deje consultar por API
aparecerán en el contador `no_accesibles_en_ml`. Esas no se pueden recuperar,
pero tampoco importan: son entregas ya cerradas.
