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

    // Coordenadas: abreviaturas chilenas expandidas + cadena de estrategias
    let lat: number | null = null, lng: number | null = null;
    let dirLimpia = direccion.split(",")[0]
      .replace(/\b(depto\.?|dpto\.?|departamento|casa|block|bloque|torre|oficina|of\.)\s*\S*/gi, "")
      .trim();
    const abrev: [RegExp, string][] = [
      [/\bpdte\b\.?/gi, "Presidente"], [/\bpte\b\.?/gi, "Presidente"],
      [/\bgral\b\.?/gi, "General"], [/\bav(da)?\b\.?/gi, "Avenida"],
      [/\bpje\b\.?/gi, "Pasaje"], [/\bsta\b\.?/gi, "Santa"], [/\bsto\b\.?/gi, "Santo"],
      [/\bfco\b\.?/gi, "Francisco"], [/\bdr\b\.?/gi, "Doctor"],
      [/\bcmdte\b\.?/gi, "Comandante"], [/\bsgto\b\.?/gi, "Sargento"],
      [/\balm\b\.?/gi, "Almirante"], [/\bmons\b\.?/gi, "Monseñor"],
    ];
    for (const [re, palabra] of abrev) dirLimpia = dirLimpia.replace(re, palabra);
    dirLimpia = dirLimpia.replace(/\s+/g, " ").trim();
    const sinTitulo = dirLimpia.replace(/^(presidente|general|avenida|pasaje|calle|doctor|comandante|sargento|almirante|monseñor|don|doña)\.?\s+/i, "").trim();
    const sinNumero = dirLimpia.replace(/\s+\d+\S*\s*$/, "").trim();
    const traer = async (url: string) => {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 3000);
      try {
        const r = await fetch(url,
          { signal: ctrl.signal, headers: { "User-Agent": "zas-reparto/1.0" } });
        clearTimeout(t);
        return r.ok ? await r.json() : null;
      } catch (_) { clearTimeout(t); return null; }
    };
    // 1) Nominatim estructurada (calle + comuna por separado: más precisa)
    let g = await traer(`https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=cl&street=${encodeURIComponent(dirLimpia)}&city=${encodeURIComponent(comuna ?? "")}`);
    if (g?.[0]) { lat = +g[0].lat; lng = +g[0].lon; }
    // 2) Nominatim libre
    if (lat == null) {
      g = await traer(`https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=cl&q=${encodeURIComponent(`${dirLimpia}, ${comuna ?? ""}, Chile`)}`);
      if (g?.[0]) { lat = +g[0].lat; lng = +g[0].lon; }
    }
    // 3) Photon (más tolerante a errores de escritura)
    if (lat == null) {
      const ph = await traer(`https://photon.komoot.io/api/?q=${encodeURIComponent(`${dirLimpia} ${comuna ?? ""} Chile`)}&limit=1&lat=-33.45&lon=-70.66`);
      const f = (ph?.features ?? []).find((x: any) => x?.properties?.countrycode === "CL");
      if (f) { lat = f.geometry.coordinates[1]; lng = f.geometry.coordinates[0]; }
    }
    // 4) sin el título del nombre (Pdte/Gral a veces difieren en el mapa)
    if (lat == null && sinTitulo !== dirLimpia) {
      g = await traer(`https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=cl&q=${encodeURIComponent(`${sinTitulo}, ${comuna ?? ""}, Chile`)}`);
      if (g?.[0]) { lat = +g[0].lat; lng = +g[0].lon; }
    }
    // 5) último recurso: nivel de calle (sin número)
    if (lat == null && sinNumero && sinNumero !== dirLimpia) {
      g = await traer(`https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=cl&q=${encodeURIComponent(`${sinNumero}, ${comuna ?? ""}, Chile`)}`);
      if (g?.[0]) { lat = +g[0].lat; lng = +g[0].lon; }
    }

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

    // Hora de corte + días de despacho del cliente:
    // pagado después del corte => día siguiente; si el día no es hábil para
    // el cliente (ej: domingo), salta al próximo día de despacho.
    try {
      const { data: cli } = await supa.from("clientes")
        .select("hora_corte, dias_despacho").eq("id", clienteId).maybeSingle();
      const corte = cli?.hora_corte as string | null;       // "12:00:00"
      const dias = (cli?.dias_despacho as string | null) ?? "1111111"; // lun..dom
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
        // avanzar hasta un día en que el cliente despache (máx 7 saltos)
        for (let i = 0; i < 7; i++) {
          const dow = new Date(fechaPedido + "T12:00:00Z").getUTCDay(); // 0=dom
          const idx = (dow + 6) % 7;                                    // 0=lun..6=dom
          if (dias[idx] !== "0") break;
          sumarDia();
        }
      }
    } catch (_) { /* sin configuración de corte */ }

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
