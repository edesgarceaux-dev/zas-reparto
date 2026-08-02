// ============================================================
// APLICACION ZAS - Receptor de pedidos Jumpseller (v2, token secreto)
// Reemplazar el código de la función "jumpseller" existente con este.
// Requiere el secreto WEBHOOK_TOKEN configurado en:
//   Project Settings -> Edge Functions -> Secrets  (o Edge Functions -> Secrets)
// "Verify JWT" debe seguir DESACTIVADO en esta función.
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const esperado = Deno.env.get("WEBHOOK_TOKEN");
    if (!esperado || url.searchParams.get("token") !== esperado) {
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

    const addr = o.shipping_address ?? o.customer?.shipping_address ?? {};
    const direccion = [addr.address, addr.street_number ?? addr.number]
      .filter(Boolean).join(" ") || addr.address || "Retiro en tienda";
    const comuna = addr.municipality ?? addr.city ?? null;

    const comprador = o.customer?.fullname ?? o.customer?.name ??
      ([o.customer?.firstname, o.customer?.surname].filter(Boolean).join(" ") ||
        "Cliente Jumpseller");
    const telefono = o.customer?.phone ?? addr.phone ?? null;

    const productos = (o.products ?? [])
      .map((p: any) => `${p.qty ?? p.quantity ?? 1}x ${p.name}`)
      .join(", ");

    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Coordenadas de la dirección (OpenStreetMap Nominatim, máx 3s; si falla, sigue sin coords)
    let lat: number | null = null, lng: number | null = null;
    try {
      const q = encodeURIComponent(
        `${direccion}, ${comuna ?? ""}, Chile`.replace(/, ,/g, ","),
      );
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 3000);
      const geo = await fetch(
        `https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=cl&q=${q}`,
        { signal: ctrl.signal, headers: { "User-Agent": "zas-reparto/1.0" } },
      );
      clearTimeout(t);
      if (geo.ok) {
        const g = await geo.json();
        if (g?.[0]) { lat = Number(g[0].lat); lng = Number(g[0].lon); }
      }
    } catch (_) { /* sin coordenadas; el panel puede geocodificar después */ }

    // Fecha y hora reales del pedido en la tienda
    let creadoEn: string | null = null;
    let fechaPedido: string | null = null;
    if (o.created_at) {
      const d = new Date(String(o.created_at).replace(" UTC", "Z").replace(" ", "T"));
      if (!isNaN(d.getTime())) {
        creadoEn = d.toISOString();
        fechaPedido = d.toLocaleDateString("en-CA", { timeZone: "America/Santiago" });
      }
    }

    const { error } = await supa.from("pedidos").upsert({
      ...(creadoEn ? { creado_en: creadoEn } : {}),
      ...(fechaPedido ? { fecha_pedido: fechaPedido } : {}),
      ...(lat != null && lng != null ? { lat, lng } : {}),
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
    }, { onConflict: "cliente_id,externo_id" });
    // Nota: al repetirse un aviso se actualizan los datos de la tienda,
    // pero estado, repartidor y notas de entrega NO se tocan (no vienen en este upsert).

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
