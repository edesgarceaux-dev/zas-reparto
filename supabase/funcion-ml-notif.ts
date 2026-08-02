// ============================================================
// APLICACION ZAS - Receptor de ventas MercadoLibre Flex
// Crear como NUEVA función: Edge Functions -> Deploy a new function
//   -> Via Editor -> nombre: ml-notif -> pegar -> Deploy
// DESACTIVAR "Verify JWT".
// Requiere el secreto ML_SECRET.
// En la app de MercadoLibre, configurar "URL de callbacks de notificaciones":
//   https://<ref>.supabase.co/functions/v1/ml-notif   (tópico: orders_v2)
// Solo ingresa ventas PAGADAS con envío Flex (logistic_type = self_service).
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const APP_ID = "7050388200486625";
const ok = (msg: string) => new Response(msg, { status: 200 });

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => null);
    if (!body?.resource || !body?.user_id) return ok("sin datos");
    if (!String(body.resource).startsWith("/orders/")) return ok("tópico ignorado");

    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // cuenta conectada
    const { data: cta } = await supa.from("ml_cuentas")
      .select().eq("ml_user_id", body.user_id).maybeSingle();
    if (!cta) return ok("cuenta no conectada a ZAS");

    // token fresco (se renueva si le quedan <10 min)
    let token = cta.access_token as string;
    if (new Date(cta.expires_en).getTime() - Date.now() < 10 * 60_000) {
      const r = await fetch("https://api.mercadolibre.com/oauth/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
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
    }

    const ml = async (path: string) => {
      const r = await fetch("https://api.mercadolibre.com" + path,
        { headers: { Authorization: `Bearer ${token}` } });
      return r.ok ? await r.json() : null;
    };

    const orderId = String(body.resource).split("/")[2];
    const o = await ml(`/orders/${orderId}`);
    if (!o) return ok("orden no accesible");
    if (o.status !== "paid") return ok(`ignorado (status: ${o.status})`);
    if (!o.shipping?.id) return ok("sin envío asociado");

    const s = await ml(`/shipments/${o.shipping.id}`);
    if (!s) return ok("envío no accesible");
    if (s.logistic_type !== "self_service") {
      return ok(`no es Flex (${s.logistic_type ?? "?"})`);
    }

    const ra = s.receiver_address ?? {};
    const direccion = [ra.street_name, ra.street_number].filter(Boolean).join(" ") || "Sin dirección";
    const comuna = ra.city?.name ?? ra.municipality?.name ?? null;
    const nombre = ra.receiver_name ??
      ([o.buyer?.first_name, o.buyer?.last_name].filter(Boolean).join(" ") ||
        o.buyer?.nickname || "Comprador MercadoLibre");
    const telefono = ra.receiver_phone ?? o.buyer?.phone?.number ?? null;
    const lat = typeof ra.latitude === "number" ? ra.latitude : null;
    const lng = typeof ra.longitude === "number" ? ra.longitude : null;
    const productos = (o.order_items ?? [])
      .map((i: any) => `${i.quantity ?? 1}x ${i.item?.title ?? "producto"}`)
      .join(", ");

    // fecha real + regla de corte y días de despacho del cliente
    let creadoEn: string | null = null;
    let fechaPedido: string | null = null;
    const base = o.date_closed ?? o.date_created;
    if (base) {
      const d = new Date(base);
      if (!isNaN(d.getTime())) {
        creadoEn = d.toISOString();
        fechaPedido = d.toLocaleDateString("en-CA", { timeZone: "America/Santiago" });
      }
    }
    try {
      const { data: cli } = await supa.from("clientes")
        .select("hora_corte, dias_despacho").eq("id", cta.cliente_id).maybeSingle();
      const corte = cli?.hora_corte as string | null;
      const dias = (cli?.dias_despacho as string | null) ?? "1111111";
      if (creadoEn && fechaPedido) {
        const sumarDia = () => {
          const d2 = new Date(fechaPedido + "T12:00:00Z");
          d2.setUTCDate(d2.getUTCDate() + 1);
          fechaPedido = d2.toISOString().slice(0, 10);
        };
        if (corte) {
          const horaLocal = new Date(creadoEn).toLocaleTimeString("en-GB",
            { timeZone: "America/Santiago", hour12: false });
          if (horaLocal > corte) sumarDia();
        }
        for (let i = 0; i < 7; i++) {
          const dow = new Date(fechaPedido + "T12:00:00Z").getUTCDay();
          if (dias[(dow + 6) % 7] !== "0") break;
          sumarDia();
        }
      }
    } catch (_) { /* sin corte */ }

    const { error } = await supa.from("pedidos").upsert({
      ...(creadoEn ? { creado_en: creadoEn } : {}),
      ...(fechaPedido ? { fecha_pedido: fechaPedido } : {}),
      ...(lat != null && lng != null ? { lat, lng } : {}),
      cliente_id: cta.cliente_id,
      externo_id: "ML-" + orderId,
      envio_id: String(s.id),   // n° de envío: es lo que trae el QR de la etiqueta Flex
      cliente_nombre: nombre,
      cliente_telefono: telefono,
      direccion,
      comuna,
      referencia: ra.comment ?? null,
      detalle: productos || null,
      monto: o.total_amount ?? null,
      metodo_pago: "pagado",
      origen: "mercadolibre",
    }, { onConflict: "cliente_id,externo_id" });

    if (error) {
      console.error("error insertando pedido ML:", error.message);
      return new Response("error: " + error.message, { status: 500 });
    }
    return ok("ok");
  } catch (e) {
    console.error(e);
    return ok("error interno tolerado"); // 200 para que ML no reintente infinito
  }
});
