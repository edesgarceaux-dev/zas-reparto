/* ============================================================
   CERRAR SESIÓN LIMPIA (v1.53)
   Al cerrar sesión hay que soltar los canales de tiempo real y el timer
   de empresa; si no, siguen consultando la base para siempre y se
   acumulan cuando entra otra cuenta en la misma pestaña.
   ============================================================ */
import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const page = await browser.newPage();
const errores = [];
page.on('pageerror', e => errores.push('pageerror: ' + e.message));
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra = '') => out.push({ n, ok: !!cond, extra });

  // espía de removeAllChannels y clearInterval
  window.__removed = 0;
  window.__cleared = [];
  eval(`
    sb.removeAllChannels = () => { window.__removed++; };
    const _ci = window.clearInterval;
    window.clearInterval = (h) => { window.__cleared.push(h); return _ci(h); };
    // dejamos una "sesión de empresa" viva: guardas prendidas + timer real
    yaSuscrito = true; repSuscrito = true; empSuscrito = true;
    adminUid = 'admin-1'; repUid = 'rep-1'; empCliId = 99;
    empTimer = setInterval(()=>{}, 999999);
    rebotado = false;
    window.__timerAntes = empTimer;
  `);

  // cerrar sesión
  await window.manejarSesion(null);

  ok('1. se llamó removeAllChannels', window.__removed === 1, String(window.__removed));
  ok('2. se limpió el timer de empresa', window.__cleared.includes(window.__timerAntes),
     JSON.stringify(window.__cleared));
  ok('3. empTimer quedó en null', eval('empTimer') === null);
  ok('4. se resetearon las guardas de suscripción',
     eval('yaSuscrito')===false && eval('repSuscrito')===false && eval('empSuscrito')===false);
  ok('5. se limpiaron los ids de sesión',
     eval('adminUid')===null && eval('repUid')===null && eval('empCliId')===null);
  ok('6. y vuelve a mostrarse el login', document.getElementById('login').style.display === 'flex');

  // segundo logout seguido no rompe (idempotente)
  window.__removed = 0;
  await window.manejarSesion(null);
  ok('7. un segundo cierre no rompe', window.__removed === 1 && errores_ok());
  function errores_ok(){ return true; }

  return out;
});

let bien = 0;
for (const x of r) { console.log(x.ok ? `✅ ${x.n}` : `❌ ${x.n}  ← ${x.extra}`); if (x.ok) bien++; }
if (errores.length) { console.log('\n⚠️ errores de página:'); errores.forEach(e => console.log('   ' + e)); }
console.log(`\n${bien}/${r.length} pruebas OK`);
await browser.close();
process.exit(bien === r.length && !errores.length ? 0 : 1);
