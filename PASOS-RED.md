# Pasos para poner en marcha la red de empresas de reparto

Panel v1.33 · Maestro v1.0 · migración `migracion-red-empresas.sql`

---

## 1. Correr el SQL (5 min)

Supabase → **SQL Editor** → **New query** → pegar todo el contenido de
`supabase/migracion-red-empresas.sql` → **Run**.

Es una sola migración y es segura de correr más de una vez. **No** corras
`migracion-pool-empresas.sql`: quedó anulada, el archivo es solo un aviso.

Al terminar tiene que devolver una fila así:

| empresas_de_reparto | super_admins | vinculos_activos | pedidos_en_el_pool | plazo_minutos | tope_sin_asignar |
|---|---|---|---|---|---|
| 1 | 1 | (tus clientes) | **0** | 120 | 30 |

Lo importante: **`pedidos_en_el_pool` tiene que dar 0** (todo lo viejo queda
tuyo, nada se va al pool) y **`super_admins` tiene que dar 1** (vos).
Si alguno de esos dos no calza, pará y avisame antes de seguir.

Si aparece un aviso que dice *"hay N RUT repetidos en clientes"*, arreglá esos
RUT y volvé a correr la migración: sin RUT único no funciona el alta de
clientes de la red.

---

## 2. Subir los dos paneles

A donde los tengas publicados (GitHub Pages):

- `panel/panel-zas.html` — el de siempre, ahora v1.33
- `panel/panel-maestro.html` — **nuevo**, va al lado del otro

El maestro no funciona si no está en la misma carpeta: el botón 🛰️ Maestro
del panel apunta a `panel-maestro.html` relativo.

---

## 3. Comprobar que quedó bien

1. Abrí el panel de siempre y recargá con **Ctrl+F5** (si no, el navegador te
   deja el viejo en caché).
2. Tienen que aparecer la pestaña **📥 Pool** y el botón **🛰️ Maestro**.
3. Entrá al maestro. Si te dice *"esta cuenta no es la dueña del sistema"*,
   pará y avisame: quiere decir que el `superadmin` quedó en otra cuenta.

---

## 4. Probar la red con una empresa de mentira (10 min)

Vale la pena hacerlo antes de meter una empresa real.

1. **Maestro → Empresas → + Nueva empresa de reparto**. Nombre: `Rápido Ltda`.
   Guardar.
2. En la misma ficha, abajo, **crear un acceso**: un correo tuyo alternativo y
   una contraseña. Esa es la cuenta de administrador de esa empresa.
3. Abrí una **ventana de incógnito** y entrá al panel con esa cuenta.
   Tiene que ver **cero pedidos y cero clientes**. Si ve algo tuyo, pará y
   avisame: eso sería una filtración entre empresas.
4. Entrá al **portal del cliente** (la cuenta de Distribuidora Pepitos) →
   pestaña **🚚 Mis empresas de reparto** → abajo, *Sumar otra empresa* →
   elegí `Rápido Ltda` → **Invitar**.
5. Volvé a la ventana de Rápido: en Clientes le aparece la invitación →
   **Aceptar**.
6. De vuelta en el portal del cliente, repartí las comunas. Por ejemplo:
   - Envíos ZAS → `Maipú, Cerrillos`
   - Rápido Ltda → `Ñuñoa`

   **Guardar reglas** en cada tarjeta.
7. Cargá dos pedidos de prueba: uno en **Maipú** y otro en **Providencia**.
   - El de Maipú tiene que caer **directo a Envíos ZAS**.
   - El de Providencia, que no cubre nadie, tiene que caer **al pool** y
     verse desde las dos empresas.
8. Tomá el de Providencia desde una de las dos y fijate que **desaparece** de
   la otra.

Cuando funcione esto, la red está andando.

---

## 5. Lo que venía pendiente de antes

- Re-deploy de `ml-notif` y `ml-backfill` si no están al día, y apretar
  **🔄 Sincronizar envíos ML**.
- **Commit + push** del repo (eso lo hacés vos desde tu terminal).
- Instalar **ZAS-Reparto-v2.4.2-moderno.apk**. La APK **no necesita cambios**
  por la red: el repartidor sigue viendo solo lo que le toca a él.

---

## 6. Cosas para decidir, sin apuro

- **Cobro**: el maestro muestra el plan, el uso del mes y el tope con su
  barrita, pero **no bloquea** a nadie que se pase ni factura nada. Falta
  decidir si cobrás por pedido, por plan fijo o mixto.
- **Cuota diaria vs pool**: hoy la cuota limita el reparto **automático**,
  no la toma del pool. Si todas las empresas pasaron su cuota, el pedido cae
  al pool y cualquiera se lo puede llevar. Está así para que ningún pedido
  quede trabado sin dueño. Si en la práctica molesta, se cambia.
- **Plazo y tope de la red**: arrancan en 120 minutos y 30 pedidos. Cuando
  veas cómo se comporta la gente en la pestaña **Conducta**, ajustalos desde
  *Reglas de la red*.
