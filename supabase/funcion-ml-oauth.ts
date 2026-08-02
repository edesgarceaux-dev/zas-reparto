// ============================================================
// APLICACION ZAS - Autorización de MercadoLibre (OAuth)
// Crear como NUEVA función: Edge Functions -> Deploy a new function
//   -> Via Editor -> nombre: ml-oauth -> pegar -> Deploy
// DESACTIVAR "Verify JWT" (MercadoLibre llega sin credenciales de Supabase).
// Requiere el secreto ML_SECRET (Secret Key de la app de MercadoLibre).
// La Redirect URI registrada en la app de ML debe ser EXACTAMENTE:
//   https://<ref>.supabase.co/functions/v1/ml-oauth
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const APP_ID = "7050388200486625";

const pagina = (titulo: string, cuerpo: string, ok: boolean) =>
  new Response(
    `<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">
     <meta name="viewport" content="width=device-width,initial-scale=1">
     <title>${titulo}</title></head>
     <body style="font-family:system-ui;display:flex;align-items:center;justify-content:center;min-height:90vh;background:#f7f5f2">
       <div style="background:#fff;border-radius:16px;padding:40px;max-width:420px;text-align:center;box-shadow:0 8px 30px rgba(0,0,0,.08)">
         <div style="font-size:46px">${ok ? "✅" : "❌"}</div>
         <h2 style="margin:12px 0 6px">${titulo}</h2>
         <p style="color:#666">${cuerpo}</p>
       </div>
     </body></html>`,
    { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state") ?? "";
    const clienteId = Number((state.match(/cliente-(\d+)/) ?? [])[1] ?? "0");
    if (!code || !clienteId) {
      return pagina("Falta información",
        "Vuelve al panel de ZAS y usa el botón 'Conectar MercadoLibre'.", false);
    }

    const redirect = `${Deno.env.get("SUPABASE_URL")}/functions/v1/ml-oauth`;
    const r = await fetch("https://api.mercadolibre.com/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: APP_ID,
        client_secret: Deno.env.get("ML_SECRET")!,
        code,
        redirect_uri: redirect,
      }),
    });
    const tk = await r.json();
    if (!tk.access_token) {
      return pagina("MercadoLibre rechazó la autorización",
        (tk.message ?? tk.error ?? "Revisa que la Redirect URI de la app coincida.") +
        " — cierra esta ventana e inténtalo de nuevo.", false);
    }

    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { error } = await supa.from("ml_cuentas").upsert({
      ml_user_id: tk.user_id,
      cliente_id: clienteId,
      access_token: tk.access_token,
      refresh_token: tk.refresh_token,
      expires_en: new Date(Date.now() + (tk.expires_in ?? 21600) * 1000).toISOString(),
    });
    if (error) {
      return pagina("Error al guardar", error.message, false);
    }
    return pagina("¡MercadoLibre conectado!",
      "Las ventas Flex pagadas de esta cuenta empezarán a llegar a ZAS automáticamente. Ya puedes cerrar esta ventana.", true);
  } catch (e) {
    console.error(e);
    return pagina("Error inesperado", "Inténtalo de nuevo en unos minutos.", false);
  }
});
