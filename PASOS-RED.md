# TODO LO QUE HAY QUE HACER — en orden

Panel v1.50 · Maestro v1.2 · APK v2.9.0
Hacelo de arriba abajo, sin saltear. Toma unos 20 minutos.

---

## 1. Correr los archivos SQL, EN ESTE ORDEN

Supabase → **SQL Editor** → **New query** → pegar todo el archivo → **Run**.
Uno por uno. Todos son seguros de repetir. Están en la carpeta `supabase/`.

| # | Archivo | Qué hace |
|---|---------|----------|
| 1 | `migracion-red-empresas.sql` | ✅ **ya la corriste**, saltala |
| 2 | `migracion-ajuste-frenos.sql` | ordena los frenos viejos |
| 3 | `migracion-zona-cobertura.sql` | carga las 52 comunas de la RM |
| 4 | `migracion-escaneo-reclama.sql` | el escaneo reclama el pedido |
| 5 | `migracion-plan-y-carga.sql` | planificar en paralelo + «Mi carga» + avisos |
| 6 | `migracion-asignar-por-qr.sql` | asignar repartidor escaneando, desde la app |
| 7 | `migracion-permisos.sql` | quién entra al panel y quién a la app |
| 8 | `migracion-archivo-fotos.sql` | respaldo descargable y limpieza de fotos viejas |
| 9 | `migracion-comunas-alias.sql` | **«Santiago Centro» deja de quedar fuera de zona** |

**Qué mirar en cada una** (te devuelven una tabla al final):
- En la **3**: `comunas_que_reparte` tiene que dar **52**. Abajo te lista las comunas que quedaron fuera de zona — si ves una de la RM mal escrita, la agregás después desde el maestro.
- En la **5**: `clientes_por_reglas` + `clientes_modo_abierto` tiene que ser el total de tus clientes.
- En la **6**: `permiso_creado` = 1 y `funciones_creadas` = 3. `cuentas_que_pueden_asignar` son tus admin, que lo reciben prendido.
- En la **7**: la fila `repartidor` tiene que decir `entran_al_panel = 0`. Ahí es donde tus repartidores dejan de poder entrar a la página.
- En la **8**: `tabla_creada` = 1 y `funciones_creadas` = 5.
- En la **9**: la primera tabla tiene que dar `ok` en todas menos Rancagua y Valparaíso. **La segunda es la que queda en pantalla**: te lista las comunas de tus pedidos que el sistema todavía no reconoce. Si ves alguna que sí repartís, agregala en el maestro → Zona de cobertura.

**No corras** `migracion-pool-empresas.sql`: está anulada, el archivo es solo un cartel.

---

## 2. Subir los paneles y hacer push

⚠️ **El sitio publica el `index.html` de la RAÍZ, no la carpeta `panel/`.**
Por eso te mando los tres archivos ya renombrados y listos para dejar caer en
la raíz de `zas-reparto\` (pisando lo que haya):

| Archivo que te mandé | Dónde va |
|---|---|
| `index.html` | raíz — **es el panel v1.50 ya renombrado** |
| `panel-maestro.html` | raíz |
| `seguimiento.html` | raíz |

```
git add index.html panel-maestro.html seguimiento.html panel/ supabase/ test-*.mjs PASOS-RED.md
git add ZAS-Reparto-v2.9.0-moderno.apk ZAS-Reparto-v2.9.0-antiguo.apk
git commit -m "v1.50 Santiago Centro en zona + los escaneados vuelven al mapa"
git push
```

Esperá ~1 minuto a que GitHub Pages reconstruya y entrá con **Ctrl+F5**.

---

## 3. Instalar la APK

**`ZAS-Reparto-v2.9.0-moderno.apk`** en los teléfonos de los repartidores
**y en el del que reparte la pega en bodega**.
(La `-antiguo` es solo para teléfonos viejos de 32 bits.)

Sin esta versión el escaneo no reclama nada, así que los pedidos compartidos se quedan sin dueño.

---

## 4. Configurar (5 minutos, una sola vez)

**En el panel maestro → Reglas de la red**: revisá abajo la caja **Zona de cobertura**. Tienen que estar las 52 comunas. Si repartís a alguna más, agregala ahí.

**En Repartidores → Editar** hay una caja de **PERMISOS** con tres interruptores:

| | Qué hace | Cómo arranca |
|---|---|---|
| 🖥️ **panel web** | entra a esta página con su cuenta | admin sí · repartidor **no** |
| 📱 **app del teléfono** | entra a la APK de reparto | admin y repartidor sí · cliente no |
| 📲 **asignar por QR** | dentro de la app, reparte bultos entre repartidores | solo admin |

En la lista de Repartidores se ve de un vistazo por dónde entra cada uno. Lo que hay
que revisar una vez: a quien reparte la pega en bodega, prendele **📲 asignar**; a una
cuenta de oficina que nunca sale a repartir, apagale **📱 app**.

Si te apagás el panel a vos mismo, el panel te avisa y te pide confirmación: quedarías
afuera hasta que otro admin te lo prenda.

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

**Las puertas**: entrá al panel con la cuenta de un repartidor. Te tiene que salir el
cartel **«Esta cuenta usa la app»** con su nombre, y no dejarlo pasar.

**Y el atajo de bodega**: entrá a la app con la cuenta habilitada, tocá **Asignar**
arriba a la derecha, elegí un repartidor y pasá tres bultos por la cámara. Los tres
quedan a nombre suyo, el contador del chip sube, y **Deshacer último** revierte el
que pasó por error.

---

## Cómo funciona ahora, en tres líneas

- Un pedido fuera de la RM o sin comuna **no lo ve ninguna empresa**: solo el cliente.
- Un pedido que las reglas del cliente le asignaron a una empresa **es de esa empresa**, nadie más lo ve ni lo puede escanear.
- Todo lo demás queda **compartido**: todas lo ven, todas pueden planificarlo, y **se lo queda la empresa cuyo repartidor lo escanee**.
- Da igual quién escanee: el repartidor con su ruta, o el de bodega asignando. El bulto es de quien lo pasa por la cámara primero.

---

## 6. Lo nuevo de la tabla de pedidos (v1.43)

- **Se fue la columna «Código»**: el código interno de ZAS no le servía a nadie.
  Igual se puede seguir buscando por él en el buscador.
- **La columna ahora es «N° de envío»**: en las ventas de MercadoLibre muestra el
  **n° de envío**, que es el que va impreso en la etiqueta y el que se escanea —
  antes salía el n° de orden, que no está en ninguna parte del paquete. Si a una
  venta ML todavía le falta el envío, sale el n° de orden con un **⚠️**: esas son
  las que arregla «🔄 Sincronizar envíos ML».
- **Dos listas desplegables** al lado del buscador: **Estado** y **Repartidor**.
  Se combinan entre ellas, con los chips de arriba y con lo que escribas. La de
  repartidor dice cuántos lleva cada uno, y tiene «Sin repartidor». Cuando hay un
  filtro puesto los desplegables se pintan de naranja y aparece una **✕** para
  sacarlos.

### El reparto automático: qué estaba fallando

Asignaba de menos por dos motivos, los dos arreglados:

1. **El grande**: el panel trataba como «compartido» a cualquier pedido sin
   empresa. En una base donde esa columna todavía no existe, eso daba *todos*.
   Así que «🤖 Repartir auto» no los asignaba: los mandaba a planificar, y el
   reparto se cortaba a la mitad.
2. Los pedidos **sin ubicar en el mapa** se metían a los grupos aunque el cupo ya
   estuviera lleno, y el resumen contaba lo que había *pedido*, no lo que la base
   había *escrito*.

3. **El orden de la ruta se perdía en los pedidos compartidos.** El orden se
   escribía en la tabla `pedidos`, pero un pedido compartido todavía no es de tu
   empresa: esa escritura no entraba (y está bien que no entre, no es tuyo). El
   repartidor recibía la ruta desordenada. Ahora el orden de los compartidos se
   guarda en el plan, y la app lo lee de ahí.

Además, cuando se acaban los pedidos de las comunas de preferencia, ahora completa
con los **más cercanos a ese sector**, no con los más cercanos al centro móvil del
grupo — antes una ruta que arrancaba en Maipú terminaba con bultos en Recoleta.
Y el orden de ruta se guarda de a 40 en paralelo: con 250 bultos tardaba minutos.

Y cuando la base deja pedidos afuera, ahora te dice **por qué**, agrupado:
«7 no se pudieron asignar: 5 fuera de la zona de reparto · 2 ya está entregado».

### «Mi carga» ya no es solo de lectura (v1.44)

Un bulto que entraba a **📦 Mi carga** quedaba trabado: hacer clic en la fila no
hacía nada. El panel buscaba el pedido solo en la lista de *Pedidos*, y los bultos
cargados viven en otra lista. Ahora:

- **Hacer clic en la fila abre la ficha**, como en cualquier otra pestaña.
- En la ficha hay una fila de botones **«Mover el estado desde acá»**: pendiente,
  asignado, aceptado, en camino, entregado, no entregado. Normalmente lo mueve el
  repartidor desde la app; esto es para corregir a mano desde la oficina.
- La tabla tiene **casillas** y una barra de acciones: reasignar a otro repartidor,
  quitar la asignación, cambiar el estado de varios de una, o cancelarlos.

### El mapa y los pedidos compartidos (v1.45)

Le asignabas 900 pedidos a un repartidor y en **Mapa** aparecía con **«0 activos»**,
sin un solo punto: no había forma de armarle la ruta. Misma causa que lo anterior —
el mapa buscaba por `repartidor_id`, y un pedido compartido guarda su repartidor en
el plan, no en el pedido. Ahora el mapa mira los dos lados:

- El desplegable cuenta bien: **«Hans Stuardo — 929 activos»**.
- **«Sin asignar»** ya no cuenta los que tienen repartidor previsto.
- Los puntos se dibujan y la ruta se ordena con el orden del plan.
- **Guardar orden** manda cada pedido a donde corresponde: los tuyos a
  `pedidos.ruta_orden`, los compartidos al plan. En una ruta mezclada cada uno
  conserva su posición real.

### Que no se te llene el servidor (v1.46)

Primero, la corrección importante: **lo que se llena no es la base de datos**. Un
pedido pesa alrededor de 1 KB; tus 7.700 pedidos al mes son 8 MB, o sea nada. La
base puede crecer tranquila durante años. Lo que se llena es el **almacenamiento
de las fotos de entrega**: 3 fotos por entrega, ~180 KB cada una.

    258 pedidos × 3 fotos × 180 KB ≈ 140 MB por día ≈ 4,2 GB por mes

Tres cosas para manejarlo, en **Reportes → 📦 Respaldo y limpieza de fotos**:

**1. Las fotos nuevas pesan un tercio.** La APK ahora saca a 900 px calidad 45 en
vez de 1280 px calidad 55: unos 70 KB en vez de 180. Se sigue leyendo el número de
la casa y la cara de quien recibe. Con eso solo, los 4,2 GB al mes bajan a 1,6 GB.

**2. El respaldo descargable.** Elegís semana, quincena o mes y bajás:

- un **ZIP** con `pedidos.csv` (se abre directo en Excel: n° de envío, cliente,
  dirección, repartidor, quién recibió, RUT, motivo de no entrega) y una carpeta
  de fotos por pedido. Ese archivo es tu prueba de entrega;
- un **PDF por cliente**, una página por entrega con los datos y las fotos, para
  mandárselo al cliente cuando reclama.

Consejo: bajalo **por semana**. Un mes entero son ~23.000 fotos y el navegador
puede quedarse sin memoria. El botón **👁️ Ver qué incluye** te dice cuántas son
antes de empezar, y te avisa si son demasiadas.

**3. Liberar el espacio.** Abajo hay una tabla con lo que ocupa cada mes y si ya
está respaldado. El botón **🧹 Liberar** borra del servidor solo las fotos que
cumplen **las tres condiciones a la vez**: más de 90 días, ya descargadas en un
respaldo, y de tu empresa. Los datos del pedido, quién recibió y su RUT **no se
borran nunca** — lo único que se va son los archivos de imagen.

Si nunca descargaste el respaldo de un período, ese período **no se puede borrar**.
Es a propósito.

### Rutas más cortas y sectores que no se cruzan (v1.47)

Medido con un día simulado de la RM (20 comunas, con más peso donde más se
vende). «Repartir auto» contra las alternativas:

| 500 pedidos entre 6 repartidores | km totales | radio del sector | pedidos que le quedaban mejor a otro |
|---|---|---|---|
| Al azar, sin mirar el mapa | 1.096 km | 20–34 km | 81% |
| Por comuna, como se haría a mano | 512 km | 9–35 km | 45% |
| 🤖 **Repartir auto** | **453 km** | **5–21 km** | **12%** |

O sea: **la mitad de los kilómetros** que repartir sin mirar el mapa, y un 12%
menos que agrupar por comuna. Dos arreglos concretos de esta versión:

**El optimizador de ruta no corría en las rutas grandes.** Solo se ejecutaba
hasta 80 paradas, porque medía la ruta entera para cada intento. Con 84 pedidos
—justo lo que da repartir 500 entre 6— no hacía nada y la ruta quedaba como
salió del «vecino más cercano», que suele ser un 25% peor. Ahora calcula solo la
diferencia de cada cambio, así que corre entero aunque sean 500 paradas, y
además mueve paradas sueltas a mejor lugar (or-opt). En 500 pedidos: 525 → 453 km.

**Los bordes de los sectores se cruzaban.** Los sectores se armaban creciendo de
a un pedido, y en los bordes siempre quedaban cruces. Ahora hay una pasada final
que **intercambia pares** entre dos sectores cuando los dos quedan mejor. Como es
un intercambio, los cupos no se mueven. Un pedido de una comuna preferida nunca
cambia de dueño. Resultado: los pedidos «invadidos» bajaron de 13% a 5% en las
rutas chicas, y los sectores pasaron de 18–31 km de radio a 11–22.

**Sobre las comunas de preferencia**: funcionan, y al 100% — en la medición, el
repartidor con «Maipú, Cerrillos» se llevó las 74 de 74 que había. Si te parece
que no las respeta, lo más probable es que **no estén puestas**. Se cargan en
**Repartidores → Editar → «Comunas de preferencia»**, separadas por coma y en
orden de prioridad. Ahora la ventana de «🤖 Repartir auto» te dice de entrada
cuántos repartidores las tienen puestas, así no queda la duda.

### El mapa, solo con los pedidos del día (v1.48)

El desplegable decía **«Sin asignar (648)»** y en el mapa aparecían muchos menos:
el conteo sumaba *todos* los pendientes de la base, pero el mapa ya dibujaba solo
los del día. Dos filtros distintos para la misma cosa. Ahora usan exactamente el
mismo, y ese filtro es una ventana clara:

> **Entran al mapa los pedidos de hoy, y los de ayer que hayan entrado después
> de la hora de corte DE SU CLIENTE.** Lo de antes ya está atrasado.

La hora de corte es la que cada cliente tiene cargada en **Clientes → Editar →
Hora de corte**, la misma que ya usás para programar los despachos. Si Pepito
corta a las 12:00 y otro cliente corta a las 11:00, un pedido de ayer a las 11:30
**entra** para el segundo y **no** para el primero. Un cliente sin hora cargada
se trata como mediodía.

Un pedido sin asignar de la semana pasada no es una parada de la ruta de hoy —
metido en el mapa solo ensucia la vista y estira los sectores.

Lo atrasado **no se esconde**: arriba del mapa aparece una franja
«⚠️ N pedidos sin asignar quedaron atrasados (el más viejo es del …)» con un
botón **Ver cuáles son** que te lleva a Pedidos ya filtrado por «Anteriores» y
«Sin repartidor». El cartel también dice qué horas de corte se aplicaron, así se
entiende el criterio de un vistazo.

### Dos arreglos de la calle (v1.50)

**«Va a Santiago Centro, fuera de la zona de reparto».** El repartidor tenía el
bulto en la mano y la dirección a diez cuadras, pero la app lo rebotaba. La lista
de cobertura dice «Santiago» y MercadoLibre manda «Santiago Centro»: la
comparación era exacta y no calzaban. Ahora el nombre se limpia antes de
comparar —le saca «Comuna de», la región, el país— y hay una tabla de sinónimos
para lo que se ve en la calle: `Santiago Centro`, `Comuna de Maipú`,
`Ñuñoa, Región Metropolitana`, `Estacion Central` sin tilde, `PAC`, `Til Til`,
`San Bernando` mal escrito. Lo que está de verdad afuera —Rancagua, Valparaíso—
sigue rebotando, y «Maipo» no se cuela como «Maipú».

Correr `migracion-comunas-alias.sql` **recalcula la zona de todos los pedidos ya
guardados**, así los que quedaron mal marcados se arreglan solos. Si te aparece
otra comuna mal escrita, se agrega a la lista de sinónimos del punto 1 de ese
archivo y se vuelve a correr.

**Los pedidos escaneados desaparecían del mapa.** Al escanear, el bulto se va a
«📦 Mi carga» —que es otra lista— y el mapa solo miraba la de Pedidos. O sea que
los puntos se borraban del mapa justo cuando el repartidor terminaba de cargar,
que es cuando más falta hace la ruta. Ahora el mapa mira las dos listas: cuenta
bien los activos de cada repartidor, dibuja los puntos de los bultos ya cargados
y respeta su orden de ruta.

---

## 7. MercadoLibre en piloto automático

**El problema ya casi no existe**: `ml-notif` guarda el n° de envío al entrar la
venta, y funciona — 237 de 238 ventas en tres días entraron completas. El botón
«🔄 Sincronizar envíos ML» solo hace falta para el rezagado ocasional, cuando
MercadoLibre no manda la notificación o la manda antes de que el envío exista.

Para cerrar ese último hueco y no apretar más ese botón:

1. Buscá el valor de **WEBHOOK_TOKEN** en Supabase → Project Settings → Edge
   Functions → Secrets.
2. Abrí `supabase/migracion-ml-automatico.sql`, pegalo en el SQL Editor y
   **cambiá la única línea marcada** con ese token.
3. Run. Queda programado que Supabase llame sola a `ml-backfill` cada 15
   minutos y complete lo que falte. Si no falta nada, no hace nada.

Para comprobar cómo viene: `supabase/revisar-ml.sql` (no cambia nada, la
consulta que importa es la última).

Para apagarlo alguna vez: `select cron.unschedule('zas-ml-envios');`

---

## Lo que sigue pendiente (no urgente)

- Separar el panel en tres páginas: empresa, cliente y maestro. Hoy el archivo grande tiene el panel de empresa y el portal del cliente juntos.
- Cobro por empresa: el maestro muestra plan, uso del mes y tope, pero **no bloquea ni factura**.
- Dashboard de estadísticas.
- WhatsApp automático (en pausa por lo de los socios).
