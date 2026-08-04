# TODO LO QUE HAY QUE HACER — en orden

Panel v1.40 · Maestro v1.2 · APK v2.6.0
Hacelo de arriba abajo, sin saltear. Toma unos 20 minutos.

---

## 1. Correr 5 archivos SQL, EN ESTE ORDEN

Supabase → **SQL Editor** → **New query** → pegar todo el archivo → **Run**.
Uno por uno. Todos son seguros de repetir. Están en la carpeta `supabase/`.

| # | Archivo | Qué hace |
|---|---------|----------|
| 1 | `migracion-red-empresas.sql` | ✅ **ya la corriste**, saltala |
| 2 | `migracion-ajuste-frenos.sql` | ordena los frenos viejos |
| 3 | `migracion-zona-cobertura.sql` | carga las 52 comunas de la RM |
| 4 | `migracion-escaneo-reclama.sql` | el escaneo reclama el pedido |
| 5 | `migracion-plan-y-carga.sql` | planificar en paralelo + «Mi carga» + avisos |

**Qué mirar en cada una** (te devuelven una tabla al final):
- En la **3**: `comunas_que_reparte` tiene que dar **52**. Abajo te lista las comunas que quedaron fuera de zona — si ves una de la RM mal escrita, la agregás después desde el maestro.
- En la **5**: `clientes_por_reglas` + `clientes_modo_abierto` tiene que ser el total de tus clientes.

**No corras** `migracion-pool-empresas.sql`: está anulada, el archivo es solo un cartel.

---

## 2. Subir los paneles y hacer push

Los archivos ya están en tu carpeta. Recordá que el sitio publica el **`index.html` de la raíz**, no `panel/`.

```
git add index.html panel-maestro.html panel/ supabase/ test-*.mjs PASOS-RED.md
git add ZAS-Reparto-v2.6.0-moderno.apk ZAS-Reparto-v2.6.0-antiguo.apk
git commit -m "v1.40 pedidos compartidos + mi carga + escaneo reclama"
git push
```

Esperá ~1 minuto a que GitHub Pages reconstruya y entrá con **Ctrl+F5**.

---

## 3. Instalar la APK

**`ZAS-Reparto-v2.6.0-moderno.apk`** en los teléfonos de los repartidores.
(La `-antiguo` es solo para teléfonos viejos de 32 bits.)

Sin esta versión el escaneo no reclama nada, así que los pedidos compartidos se quedan sin dueño.

---

## 4. Configurar (5 minutos, una sola vez)

**En el panel maestro → Reglas de la red**: revisá abajo la caja **Zona de cobertura**. Tienen que estar las 52 comunas. Si repartís a alguna más, agregala ahí.

**En el portal de cada cliente → Mis empresas de reparto**: elegí cómo quiere repartir.
- **Por mis reglas**: le da comunas a cada empresa. Lo que no calza con nadie queda compartido.
- **Abierto**: todos sus pedidos quedan a la vista de todas sus empresas y se los queda la que los cargue.

---

## 5. Probar que funciona

1. Entrá al panel con tu cuenta. En **Pedidos** los que todavía no son de nadie salen marcados **🤝 compartido**.
2. Seleccioná uno compartido y asignale un repartidor. Fijate que dice *"previsto"*: todavía no es tuyo.
3. Entrá con la cuenta de Rapiditos: el mismo pedido le aparece a ella también, y puede asignarle **su** repartidor sin pisar el tuyo.
4. Que un repartidor escanee esa etiqueta con la app. El pedido pasa a su empresa, se va a **📦 Mi carga**, y desaparece de la otra.
5. En el panel de la empresa que lo perdió aparece la franja **📣 «salió de tu ruta»** diciendo quién se lo llevó.

---

## Cómo funciona ahora, en tres líneas

- Un pedido fuera de la RM o sin comuna **no lo ve ninguna empresa**: solo el cliente.
- Un pedido que las reglas del cliente le asignaron a una empresa **es de esa empresa**, nadie más lo ve ni lo puede escanear.
- Todo lo demás queda **compartido**: todas lo ven, todas pueden planificarlo, y **se lo queda la empresa cuyo repartidor lo escanee**.

---

## Lo que sigue pendiente (no urgente)

- Separar el panel en tres páginas: empresa, cliente y maestro. Hoy el archivo grande tiene el panel de empresa y el portal del cliente juntos.
- Cobro por empresa: el maestro muestra plan, uso del mes y tope, pero **no bloquea ni factura**.
- Dashboard de estadísticas.
- WhatsApp automático (en pausa por lo de los socios).
