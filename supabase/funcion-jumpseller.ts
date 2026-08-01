// ============================================================
// APLICACION ZAS - Receptor de pedidos Jumpseller (Edge Function)
// Crear en: Supabase Dashboard -> Edge Functions -> Deploy a new function
//   -> Via Editor -> nombre: jumpseller -> pegar este código -> Deploy
// Luego, en los detalles de la función: DESACTIVAR "Verify JWT with legacy secret"
// (el webhook de Jumpseller no envía credenciales de Supabase).
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

// Token secreto propio: la URL del webhook debe incluirlo para ser aceptada.
const TOKEN = "65e42ae41505d0df25ca6efbd9e9c620ab0d6e0b22486679";

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    if (url.searchParams.get("token") !== TOKEN) {
      return new Response("no autorizado", { status: 401 });
    }
    const clienteId = Number(url.searchParams.get("cliente") || "0");
    if (!clienteId) return new Response("falta cliente", { status: 400 });

    const body = await req.json().catch(() => null);
    const o = body?.order ?? body;
    if (!o?.id) return new Response("sin orden", { status: 200 });

    // Solo pedidos pagados
    const status = String(o.status ?? "").toLowerCase();
    if (status !== "paid") {
      return new Response(`ignorado (status: ${status})`, { status: 200 });
    }

    // Dirección de envío (Jumpseller varía los nombres según versión)
    const addr = o.shipping_address ?? o.customer?.shipping_address ?? {};
    const direccion = [addr.address, addr.street_number ?? addr.number]
      .filter(Boolean).join(" ") || addr.address || "Retiro en tienda";
    const comuna = addr.municipality ?? addr.city ?? null;

    // Cliente final
    const comprador = o.customer?.fullname ?? o.customer?.name ??
      ([o.customer?.firstname, o.customer?.surname].filter(Boolean).join(" ") ||
        "Cliente Jumpseller");
    const telefono = o.customer?.phone ?? addr.phone ?? null;

    // Detalle: lista de productos
    const productos = (o.products ?? [])
      .map((p: any) => `${p.qty ?? p.quantity ?? 1}x ${p.name}`)
      .join(", ");

    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { error } = await supa.from("pedidos").upsert({
      cliente_id: clienteId,
      externo_id: String(o.id),
      cliente_nombre: comprador,
      cliente_telefono: telefono,
      direccion,
      comuna,
      referencia: addr.complement ?? null,
      detalle: productos || null,
      monto: o.total ?? null,
      metodo_pago: "pagado",
      origen: "jumpseller",
    }, { onConflict: "cliente_id,externo_id", ignoreDuplicates: true });

    if (error) {
      console.error("error insertando pedido:", error.message);
      return new Response("error: " + error.message, { status: 500 });
    }
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("error interno", { status: 500 });
  }
});
