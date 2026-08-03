// ============================================================
// APLICACION ZAS - Rellenar el N° DE ENVÍO de las ventas Flex
//
// PARA QUÉ SIRVE:
// El QR de la etiqueta de MercadoLibre Flex trae el n° de ENVÍO (shipment),
// pero ZAS guardaba solo el n° de ORDEN (el que empieza en 2000...). Por eso
// al escanear una etiqueta Flex la app decía "no está en tu ruta".
// Esta función recorre las ventas de MercadoLibre que todavía no tienen
// envio_id, le pregunta a MercadoLibre cuál es el envío de cada orden y lo
// guarda. Se puede correr las veces que sea: solo toca las que faltan.
//
// CÓMO INSTALARLA:
//   1. Ejecutar antes migracion-envio.sql (crea la columna pedidos.envio_id)
//   2. Edge Functions -> Deploy a new function -> Via Editor
//      -> nombre: ml-backfill -> pegar esto -> Deploy
//   3. DESACTIVAR "Verify JWT"  (la autorización la hace esta misma función)
//   4. Requiere los secretos ML_SECRET y WEBHOOK_TOKEN (ya existen)
//
// CÓMO USARLA:
//   a) Desde el panel: botón "🔄 Sincronizar envíos ML" (entra con la sesión
//      del admin, no hace falta ningún token).
//   b) A mano en el navegador:
//      https://<ref>.supabase.co/functions/v1/ml-backfill?token=<WEBHOOK_TOKEN>
//   Opcionales: &limite=500 (por defecto 300, máx 1000) · &dias=90
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const APP_ID = "7050388200486625";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj, null, 2), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const url = new URL(req.url);
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // --- autorización: token en la URL, o sesión de un admin del panel ---
    const esperado = Deno.env.get("WEBHOOK_TOKEN");
    let autorizado = !!esperado && url.searchParams.get("token") === esperado;
    if (!autorizado) {
      const jwt = (req.headers.get("Authorization") ?? "")
        .replace(/^Bearer\s+/i, "");
      if (jwt) {
        try {
          const { data } = await supa.auth.getUser(jwt);
          if (data?.user) {
            const { data: perfil } = await supa.from("perfiles")
              .select("rol").eq("id", data.user.id).maybeSingle();
            autorizado = perfil?.rol === "admin";
          }
        } catch (_) { /* jwt inválido */ }
      }
    }
    if (!autorizado) return json({ ok: false, error: "no autorizado" }, 401);

    let cuerpo: Record<string, unknown> = {};
    if (req.method === "POST") cuerpo = await req.json().catch(() => ({}));
    const leer = (k: string) =>
      url.searchParams.get(k) ?? (cuerpo[k] != null ? String(cuerpo[k]) : null);
    const limite = Math.min(Number(leer("limite") || "300"), 1000);
    const dias = Number(leer("dias") || "0");

    // --- 1) ventas de MercadoLibre a las que les falta el n° de envío ---
    let q = supa.from("pedidos")
      .select("id, cliente_id, externo_id, creado_en")
      .eq("origen", "mercadolibre")
      .is("envio_id", null)
      .like("externo_id", "ML-%")
      .order("creado_en", { ascending: false })
      .limit(limite);
    if (dias > 0) {
      q = q.gte("creado_en",
        new Date(Date.now() - dias * 86400_000).toISOString());
    }
    const { data: pedidos, error: errSel } = await q;
    if (errSel) {
      return json({
        ok: false,
        error: errSel.message,
        pista: errSel.message.includes("envio_id")
          ? "Falta ejecutar migracion-envio.sql (crea la columna pedidos.envio_id)."
          : undefined,
      }, 500);
    }

    if (!pedidos?.length) {
      // "cero pendientes" puede significar dos cosas MUY distintas: que ya
      // está todo al día, o que no hay ninguna venta de ML guardada. Lo
      // separamos para que la respuesta sirva de diagnóstico.
      const { count: totalMl } = await supa.from("pedidos")
        .select("id", { count: "exact", head: true })
        .eq("origen", "mercadolibre");
      const { count: conEnvio } = await supa.from("pedidos")
        .select("id", { count: "exact", head: true })
        .eq("origen", "mercadolibre").not("envio_id", "is", null);
      const { count: cuentas } = await supa.from("ml_cuentas")
        .select("ml_user_id", { count: "exact", head: true });
      return json({
        ok: true,
        revisados: 0,
        actualizados: 0,
        ventas_ml_en_zas: totalMl ?? 0,
        ya_tenian_envio: conEnvio ?? 0,
        cuentas_ml_conectadas: cuentas ?? 0,
        mensaje: (totalMl ?? 0) === 0
          ? "No hay NINGUNA venta de MercadoLibre guardada en ZAS. Entonces el problema no es el n° de envío: las ventas Flex no están entrando al sistema. Revisar la función ml-notif y que la cuenta de ML siga conectada."
          : "Todas las ventas de MercadoLibre ya tienen su n° de envío guardado.",
      });
    }

    // --- 2) un token vigente por cada cuenta de MercadoLibre conectada ---
    const { data: cuentas } = await supa.from("ml_cuentas").select();
    const tokenPorCliente = new Map<number, string>();
    for (const cta of cuentas ?? []) {
      let token = cta.access_token as string;
      if (new Date(cta.expires_en).getTime() - Date.now() < 10 * 60_000) {
        try {
          const r = await fetch("https://api.mercadolibre.com/oauth/token", {
            method: "POST",
            headers: {
              "Content-Type": "application/x-www-form-urlencoded",
              Accept: "application/json",
            },
            body: new URLSearchParams({
              grant_type: "refresh_token",
              client_id: APP_ID,
              client_secret: Deno.env.get("ML_SECRET")!,
              refresh_token: cta.refresh_token,
            }),
          });
          const tk = await r.json();
          if (tk.access_token) {
            token = tk.access_token;
            await supa.from("ml_cuentas").update({
              access_token: tk.access_token,
              refresh_token: tk.refresh_token ?? cta.refresh_token,
              expires_en: new Date(
                Date.now() + (tk.expires_in ?? 21600) * 1000,
              ).toISOString(),
            }).eq("ml_user_id", cta.ml_user_id);
          }
        } catch (_) { /* si no se pudo renovar, se prueba con el actual */ }
      }
      tokenPorCliente.set(cta.cliente_id, token);
    }
    if (!tokenPorCliente.size) {
      return json({
        ok: false,
        pendientes: pedidos.length,
        error:
          "Hay ventas por sincronizar pero no hay ninguna cuenta de MercadoLibre conectada a ZAS (la tabla ml_cuentas está vacía). Reconectar la cuenta desde el panel.",
      }, 400);
    }

    // --- 3) preguntar a ML el envío de cada orden, de a poco ---
    let actualizados = 0, sinEnvio = 0, noAccesibles = 0, sinCuenta = 0;
    const errores: string[] = [];
    const ejemplos: string[] = [];
    const LOTE = 5;

    for (let i = 0; i < pedidos.length; i += LOTE) {
      const lote = pedidos.slice(i, i + LOTE);
      await Promise.all(lote.map(async (p) => {
        const token = tokenPorCliente.get(p.cliente_id);
        if (!token) {
          sinCuenta++;
          if (ejemplos.length < 5) {
            ejemplos.push(`${p.externo_id}: su empresa (cliente_id ${p.cliente_id}) no tiene cuenta de ML conectada`);
          }
          return;
        }
        const orderId = String(p.externo_id).replace(/^ML-/, "");
        if (!/^\d+$/.test(orderId)) {
          noAccesibles++;
          if (ejemplos.length < 5) ejemplos.push(`${p.externo_id}: no parece un n° de orden`);
          return;
        }
        try {
          const r = await fetch(
            `https://api.mercadolibre.com/orders/${orderId}`,
            { headers: { Authorization: `Bearer ${token}` } },
          );
          if (!r.ok) {
            noAccesibles++;
            if (ejemplos.length < 5) {
              ejemplos.push(`${p.externo_id}: MercadoLibre respondió ${r.status}`);
            }
            return;
          }
          const o = await r.json();
          const envio = o?.shipping?.id;
          if (!envio) {
            sinEnvio++;
            if (ejemplos.length < 5) {
              ejemplos.push(`${p.externo_id}: la orden no tiene envío asociado en ML`);
            }
            return;
          }
          const { error } = await supa.from("pedidos")
            .update({ envio_id: String(envio) }).eq("id", p.id);
          if (error) errores.push(`pedido ${p.id}: ${error.message}`);
          else actualizados++;
        } catch (e) {
          errores.push(`pedido ${p.id}: ${e}`);
        }
      }));
      if (i + LOTE < pedidos.length) {
        await new Promise((r) => setTimeout(r, 250));
      }
    }

    return json({
      ok: true,
      revisados: pedidos.length,
      actualizados,
      sin_envio_en_ml: sinEnvio,
      no_accesibles_en_ml: noAccesibles,
      sin_cuenta_conectada: sinCuenta,
      ejemplos: ejemplos.length ? ejemplos : undefined,
      errores: errores.length ? errores.slice(0, 10) : undefined,
      mensaje: actualizados
        ? `Listo: ${actualizados} venta(s) de MercadoLibre ya se pueden escanear con la etiqueta Flex.`
        : "No se actualizó ninguna. Mira los contadores y los ejemplos de arriba para saber por qué.",
      siguiente: pedidos.length >= limite
        ? "Quedaban más pendientes: vuelve a apretar el botón para seguir."
        : undefined,
    });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String(e) }, 500);
  }
});
