// ============================================================
// APLICACION ZAS - Conectar tienda Jumpseller desde el panel
// Crear como NUEVA función: Edge Functions -> Deploy a new function
//   -> Via Editor -> nombre: conectar-tienda -> pegar -> Deploy
// En esta función "Verify JWT" queda ACTIVADO (valor por defecto):
// solo usuarios conectados del panel pueden llamarla, y además
// aquí se verifica que el usuario sea administrador.
// Las credenciales de la tienda se usan al momento y NO se guardan.
// Requiere el secreto WEBHOOK_TOKEN (el mismo de la función jumpseller).
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const API = "https://api.jumpseller.com/v1";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    // 1. Verificar que quien llama es un administrador del sistema
    const jwt = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: userData } = await supa.auth.getUser(jwt);
    const uid = userData?.user?.id;
    if (!uid) return json({ ok: false, error: "Sesión inválida." }, 401);
    const { data: perfil } = await supa.from("perfiles")
      .select("rol, activo").eq("id", uid).single();
    if (perfil?.rol !== "admin" || !perfil?.activo) {
      return json({ ok: false, error: "Solo administradores." }, 403);
    }

    // 2. Datos de entrada
    const { clienteId, login, authtoken } = await req.json();
    if (!clienteId || !login || !authtoken) {
      return json({ ok: false, error: "Faltan datos (cliente, login o token)." }, 400);
    }
    const cred = `login=${encodeURIComponent(login)}&authtoken=${encodeURIComponent(authtoken)}`;

    // 3. Validar credenciales contra Jumpseller
    const infoRes = await fetch(`${API}/store/info.json?${cred}`);
    if (!infoRes.ok) {
      return json({ ok: false, error: "Credenciales de Jumpseller inválidas. Revisa el Login y el Auth Token." }, 200);
    }
    const tienda = (await infoRes.json())?.store?.name ?? "tienda";

    // 4. URL del receptor con el token secreto
    const hookUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/jumpseller` +
      `?token=${Deno.env.get("WEBHOOK_TOKEN")}&cliente=${Number(clienteId)}`;

    // 5. Quitar conexiones anteriores hacia ZAS (si las hubiera) para no duplicar
    const hooksRes = await fetch(`${API}/hooks.json?${cred}`);
    const hooks = hooksRes.ok ? await hooksRes.json() : [];
    for (const h of hooks) {
      const hk = h?.hook;
      if (hk?.url?.includes("/functions/v1/jumpseller")) {
        await fetch(`${API}/hooks/${hk.id}.json?${cred}`, { method: "DELETE" });
      }
    }

    // 6. Registrar el aviso de venta pagada
    const crear = await fetch(`${API}/hooks.json?${cred}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ hook: { event: "order_paid", url: hookUrl } }),
    });
    if (!crear.ok) {
      const msg = await crear.text();
      return json({ ok: false, error: "Jumpseller rechazó el registro: " + msg }, 200);
    }

    // 7. Marcar el cliente como integrado
    await supa.from("clientes").update({ integracion: "jumpseller" })
      .eq("id", Number(clienteId));

    return json({ ok: true, tienda });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: "Error interno." }, 500);
  }
});
