// ============================================================
// APLICACION ZAS - Rellenar el N° DE ENVÍO de las ventas Flex antiguas
//
// PARA QUÉ SIRVE:
// El QR de la etiqueta de MercadoLibre Flex trae el n° de ENVÍO (shipment),
// pero ZAS solo guardaba el n° de ORDEN (el que empieza en 2000...). Por eso
// al escanear una etiqueta Flex la app decía "no está en tu ruta".
// Esta función recorre los pedidos de MercadoLibre que todavía no tienen
// envio_id, le pregunta a MercadoLibre cuál es el envío de cada orden y lo
// guarda. Se puede correr las veces que sea: solo toca los que faltan.
//
// CÓMO INSTALARLA:
//   1. Ejecutar antes migracion-envio.sql (crea la columna pedidos.envio_id)
//   2. Edge Functions -> Deploy a new function -> Via Editor
//      -> nombre: ml-backfill -> pegar esto -> Deploy
//   3. DESACTIVAR "Verify JWT"
//   4. Requiere los secretos ML_SECRET y WEBHOOK_TOKEN (ya existen)
//
// CÓMO USARLA (pegar en el navegador):
//   https://<ref>.supabase.co/functions/v1/ml-backfill?token=<WEBHOOK_TOKEN>
// Opcionales:
//   &limite=500   cuántos pedidos revisar de una vez (por defecto 300)
//   &dias=90      solo pedidos de los últimos N días (por defecto todos)
// Devuelve un resumen en JSON con cuántos actualizó.
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const APP_ID = "7050388200486625";

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const esperado = Deno.env.get("WEBHOOK_TOKEN");
    if (!esperado || url.searchParams.get("token") !== esperado) {
      return new Response("no autorizado", { status: 401 });
    }
    const limite = Math.min(Number(url.searchParams.get("limite") || "300"), 1000);
    const dias = Number(url.searchParams.get("dias") || "0");

    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // 1) pedidos de MercadoLibre a los que les falta el n° de envío
    let q = supa.from("pedidos")
      .select("id, cliente_id, externo_id, creado_en")
      .eq("origen", "mercadolibre")
      .is("envio_id", null)
      .like("externo_id", "ML-%")
      .order("creado_en", { ascending: false })
      .limit(limite);
    if (dias > 0) {
      q = q.gte("creado_en", new Date(Date.now() - dias * 86400_000).toISOString());
    }
    const { data: pedidos, error: errSel } = await q;
    if (errSel) {
      // el error típico: todavía no se corrió migracion-envio.sql
      return new Response(JSON.stringify({
        ok: false,
        error: errSel.message,
        pista: errSel.message.includes("envio_id")
          ? "Falta ejecutar migracion-envio.sql (agrega la columna pedidos.envio_id)."
          : undefined,
      }, null, 2), { status: 500, headers: { "Content-Type": "application/json" } });
    }
    if (!pedidos?.length) {
      return new Response(JSON.stringify({
        ok: true, revisados: 0, actualizados: 0,
        mensaje: "No hay ventas de MercadoLibre pendientes de n° de envío.",
      }, null, 2), { headers: { "Content-Type": "application/json" } });
    }

    // 2) un token vigente por cada cuenta de MercadoLibre conectada
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
              expires_en: new Date(Date.now() + (tk.expires_in ?? 21600) * 1000).toISOString(),
            }).eq("ml_user_id", cta.ml_user_id);
          }
        } catch (_) { /* si no se pudo renovar, se intenta con el actual */ }
      }
      tokenPorCliente.set(cta.cliente_id, token);
    }
    if (!tokenPorCliente.size) {
      return new Response(JSON.stringify({
        ok: false,
        error: "No hay ninguna cuenta de MercadoLibre conectada a ZAS.",
      }, null, 2), { status: 400, headers: { "Content-Type": "application/json" } });
    }

    // 3) preguntar a MercadoLibre el envío de cada orden (de a poco, para no
    //    pasarse del límite de llamadas de la API)
    let actualizados = 0, sinEnvio = 0, sinAcceso = 0, sinCuenta = 0;
    const errores: string[] = [];
    const LOTE = 5;

    for (let i = 0; i < pedidos.length; i += LOTE) {
      const lote = pedidos.slice(i, i + LOTE);
      await Promise.all(lote.map(async (p) => {
        const token = tokenPorCliente.get(p.cliente_id);
        if (!token) { sinCuenta++; return; }
        const orderId = String(p.externo_id).replace(/^ML-/, "");
        if (!/^\d+$/.test(orderId)) { sinAcceso++; return; }
        try {
          const r = await fetch(`https://api.mercadolibre.com/orders/${orderId}`,
            { headers: { Authorization: `Bearer ${token}` } });
          if (!r.ok) { sinAcceso++; return; }
          const o = await r.json();
          const envio = o?.shipping?.id;
          if (!envio) { sinEnvio++; return; }
          const { error } = await supa.from("pedidos")
            .update({ envio_id: String(envio) }).eq("id", p.id);
          if (error) errores.push(`pedido ${p.id}: ${error.message}`);
          else actualizados++;
        } catch (e) {
          errores.push(`pedido ${p.id}: ${e}`);
        }
      }));
      // respiro entre lotes
      if (i + LOTE < pedidos.length) await new Promise((r) => setTimeout(r, 250));
    }

    return new Response(JSON.stringify({
      ok: true,
      revisados: pedidos.length,
      actualizados,
      sin_envio_en_ml: sinEnvio,
      no_accesibles_en_ml: sinAcceso,
      sin_cuenta_conectada: sinCuenta,
      errores: errores.slice(0, 10),
      mensaje: actualizados
        ? `Listo: ${actualizados} venta(s) de MercadoLibre ya se pueden escanear con la etiqueta Flex.`
        : "No se actualizó ninguna. Revisa los contadores de arriba.",
      siguiente: pedidos.length >= limite
        ? "Quedaban más pendientes: vuelve a abrir esta misma dirección para seguir."
        : undefined,
    }, null, 2), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ ok: false, error: String(e) }, null, 2),
      { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
