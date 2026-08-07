/* ============================================================
   FOTOS PRIVADAS (v1.54)
   El bucket 'entregas' es privado: el panel muestra y baja las fotos con
   una URL FIRMADA temporal. Se prueba que:
     - rutaFoto() saca bien la ruta dentro del bucket de la URL guardada
     - firmarFotos() devuelve las URLs firmadas (mock de createSignedUrls)
     - si firmar falla, cae a la URL guardada (nunca se queda sin fotos)
   ============================================================ */
import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const page = await browser.newPage();
const errores = [];
page.on('pageerror', e => errores.push('pageerror: ' + e.message));
await page.goto(url, { waitUntil: 'domcontentloaded' });

const PUB = 'https://x.supabase.co/storage/v1/object/public/entregas/';

const r = await page.evaluate(async (PUB) => {
  const out = [];
  const ok = (n, cond, extra = '') => out.push({ n, ok: !!cond, extra });

  // ---- rutaFoto: URL guardada -> ruta dentro del bucket ----
  ok('1. rutaFoto saca la ruta',
     eval(`rutaFoto('${PUB}123/domicilio_1700.jpg')`) === '123/domicilio_1700.jpg');
  ok('2. rutaFoto decodifica %20',
     eval(`rutaFoto('${PUB}45/foo%20bar.jpg')`) === '45/foo bar.jpg');
  ok('3. rutaFoto(null) = null', eval(`rutaFoto(null)`) === null);
  ok('4. URL que no es de entregas = null',
     eval(`rutaFoto('https://otro.com/imagen.jpg')`) === null);

  // ---- firmarFotos con mock que firma bien ----
  eval(`
    window.__firmaLlamadas = 0;
    sb.storage.from = (b) => ({
      createSignedUrls: async (paths) => {
        window.__firmaLlamadas++;
        return { data: paths.map(p => ({ signedUrl: 'SIGNED::' + p, error: null })), error: null };
      }
    });
  `);
  const dom = `${PUB}123/domicilio_1700.jpg`;
  const ped = `${PUB}123/pedido_1701.jpg`;
  const m = await eval(`firmarFotos(['${dom}', '${ped}', null])`);
  ok('5. firma ambas fotos', m.size === 2);
  ok('6. la firma es la esperada', m.get(dom) === 'SIGNED::123/domicilio_1700.jpg');
  ok('7. nulls no se firman ni rompen', !m.has(null) && m.get(ped) === 'SIGNED::123/pedido_1701.jpg');
  ok('8. una sola llamada para el lote', eval('window.__firmaLlamadas') === 1);

  // ---- fSrc: firmada si existe, si no la guardada ----
  const fSrc = u => m.get(u) || u;
  ok('9. fSrc usa la firmada', fSrc(dom) === 'SIGNED::123/domicilio_1700.jpg');
  ok('10. fSrc cae a la guardada si no hay firma', fSrc(`${PUB}999/x.jpg`) === `${PUB}999/x.jpg`);

  // ---- fallback: createSignedUrls devuelve error -> mapa vacío ----
  eval(`sb.storage.from = (b) => ({ createSignedUrls: async () => ({ data: null, error: { message: 'nope' } }) });`);
  const m2 = await eval(`firmarFotos(['${dom}'])`);
  ok('11. si firmar da error, mapa vacío (fallback)', m2.size === 0);

  // ---- fallback: createSignedUrls tira excepción -> no rompe ----
  eval(`sb.storage.from = (b) => ({ createSignedUrls: async () => { throw new Error('sin red'); } });`);
  let tiro = false, m3;
  try { m3 = await eval(`firmarFotos(['${dom}'])`); } catch (_) { tiro = true; }
  ok('12. si firmar tira excepción, no propaga y da mapa vacío', !tiro && m3 && m3.size === 0);

  return out;
}, PUB);

let bien = 0;
for (const x of r) { console.log(x.ok ? `✅ ${x.n}` : `❌ ${x.n}  ← ${x.extra}`); if (x.ok) bien++; }
if (errores.length) { console.log('\n⚠️ errores de página:'); errores.forEach(e => console.log('   ' + e)); }
console.log(`\n${bien}/${r.length} pruebas OK`);
await browser.close();
process.exit(bien === r.length && !errores.length ? 0 : 1);
