// ============================================================
// APLICACION ZAS - Arranque firmado del OAuth de MercadoLibre
// Crear como NUEVA función: Edge Functions -> Deploy a new function
//   -> Via Editor -> nombre: ml-oauth-start -> pegar -> Deploy
// "Verify JWT" queda ACTIVADO (por defecto): solo un usuario conectado
// del panel puede llamarla.
// Requiere el secreto ML_SECRET (se reusa como llave de firma del state).
//
// QUÉ RESUELVE
// -----------
// Antes el panel abría el OAuth de ML con state = "cliente-<id>" a secas,
// sin firma. Un tercero con cuenta ML podía completar el flujo con
// state=cliente-1 y conectar SU cuenta al cliente víctima. Ahora el panel
// pide acá un state FIRMADO: esta función comprueba que quien llama es
// admin y que el cliente trabaja con su empresa, y devuelve un state con
// HMAC y vencimiento que ml-oauth verifica.
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const b64url = (buf: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function firmar(payload: string, secreto: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secreto), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64url(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const jwt = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: userData } = await supa.auth.getUser(jwt);
    const uid = userData?.user?.id;
    if (!uid) return json({ ok: false, error: "Sesión inválida." }, 401);

    const { data: perfil } = await supa.from("perfiles")
      .select("rol, activo, empresa_reparto_id, superadmin").eq("id", uid).single();
    if (perfil?.rol !== "admin" || !perfil?.activo) {
      return json({ ok: false, error: "Solo administradores." }, 403);
    }

    const { clienteId } = await req.json();
    const cid = Number(clienteId);
    if (!cid) return json({ ok: false, error: "Falta el cliente." }, 400);

    // 🔒 solo un cliente vinculado a MI empresa (el superadmin, cualquiera)
    if (!perfil.superadmin) {
      const { data: vinc } = await supa.from("cliente_empresas")
        .select("cliente_id")
        .eq("cliente_id", cid)
        .eq("empresa_reparto_id", perfil.empresa_reparto_id)
        .eq("estado", "activa")
        .maybeSingle();
      if (!vinc) return json({ ok: false, error: "Ese cliente no está vinculado a tu empresa." }, 403);
    }

    const secreto = Deno.env.get("ML_SECRET");
    if (!secreto) return json({ ok: false, error: "Falta ML_SECRET." }, 500);

    const exp = Date.now() + 10 * 60_000;          // el state vale 10 minutos
    const payload = `cliente-${cid}.${exp}`;
    const state = `${payload}.${await firmar(payload, secreto)}`;
    return json({ ok: true, state });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: "Error interno." }, 500);
  }
});
