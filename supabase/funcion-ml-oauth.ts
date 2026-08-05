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
const PANEL = "https://edesgarceaux-dev.github.io/zas-reparto/";

// Verifica el state FIRMADO que arma ml-oauth-start: "cliente-<id>.<exp>.<sig>".
// Devuelve el cliente_id solo si la firma HMAC y el vencimiento son válidos.
// Sin esto, cualquiera con cuenta ML podía conectarla a un cliente ajeno.
const b64url = (buf: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
async function clienteDeState(state: string, secreto: string): Promise<number> {
  const partes = state.split(".");
  if (partes.length !== 3) return 0;
  const [p1, exp, sig] = partes;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secreto), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const esperado = b64url(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${p1}.${exp}`)));
  if (sig !== esperado) return 0;                      // firma inválida
  if (!(Number(exp) > Date.now())) return 0;           // vencido
  return Number((p1.match(/cliente-(\d+)/) ?? [])[1] ?? "0");
}

// Redirige de vuelta al panel, que muestra el resultado como notificación.
const pagina = (titulo: string, cuerpo: string, ok: boolean) =>
  new Response(null, {
    status: 302,
    headers: {
      Location: `${PANEL}?ml=${ok ? "ok" : "error"}&msg=${encodeURIComponent(titulo + ". " + cuerpo)}`,
    },
  });

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state") ?? "";
    const secretoFirma = Deno.env.get("ML_SECRET")!;
    const clienteId = await clienteDeState(state, secretoFirma);
    if (!code || !clienteId) {
      return pagina("Enlace vencido o inválido",
        "Vuelve al panel de ZAS y usa de nuevo el botón 'Conectar MercadoLibre'.", false);
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
