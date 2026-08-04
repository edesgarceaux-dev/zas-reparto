import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
const page = await browser.newPage();
const errores = [];
page.on('pageerror', e => errores.push('pageerror: ' + e.message));
page.on('console', m => {
  if (m.type() === 'error' &&
      !/ERR_CONNECTION|ERR_FILE_NOT_FOUND|ERR_NAME_NOT_RESOLVED|Failed to load resource/.test(m.text()))
    errores.push('console: ' + m.text());
});
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra = '') => out.push({ n, ok: !!cond, extra });
  const $ = id => document.getElementById(id);
  const visible = id => $(id).style.display !== 'none' && $(id).style.display !== '';

  const GENTE = [
    { id: 'u1', nombre: 'Etienne',     rol: 'admin',      activo: true,
      puede_panel: true,  puede_app: true,  puede_asignar: true },
    { id: 'u2', nombre: 'Juan Pérez',  rol: 'repartidor', activo: true,
      puede_panel: false, puede_app: true,  puede_asignar: false },
    { id: 'u3', nombre: 'Jefe Bodega', rol: 'repartidor', activo: true, telefono: '912345678',
      puede_panel: false, puede_app: true,  puede_asignar: true },
    { id: 'u4', nombre: 'Contadora',   rol: 'admin',      activo: true,
      puede_panel: true,  puede_app: false, puede_asignar: false },
    { id: 'u5', nombre: 'Sin nada',    rol: 'repartidor', activo: true,
      puede_panel: false, puede_app: false, puede_asignar: false },
  ];
  window.__gente = GENTE;
  window.__updates = [];
  window.__falla = null;
  window.__salidas = 0;

  eval(`
    adminUid = 'u1';
    sb.from = (t) => ({
      update: (v) => {
        const err = window.__falla && window.__falla(v);
        const res = { data: null, error: err };
        const o = { eq: () => o, select: () => o,
                    maybeSingle: () => Promise.resolve(res),
                    then: (f) => Promise.resolve(res).then(f) };
        window.__updates.push({ t, v }); return o;
      },
      select: () => {
        const o = { order:()=>o, limit:()=>o,
          eq: (col, val) => ({
            maybeSingle: () => Promise.resolve({
              data: window.__gente.find(g => g.id === val) ?? null, error: null }),
            order: () => o, limit: () => o,
            then: (f) => Promise.resolve({ data: [], error: null }).then(f) }),
          maybeSingle: () => Promise.resolve({ data: null, error: null }),
          then: (f) => Promise.resolve({ data: [], error: null }).then(f) };
        return o;
      },
    });
    sb.auth.signOut = async () => { window.__salidas++; await manejarSesion(null); };
    perfiles = window.__gente;
    window.__pintarReps  = pintarReps;
    window.__editarRep   = editarRep;
    window.__manejar     = manejarSesion;
    window.__marcas      = marcasPermisos;
  `);
  window.cargarTodo = async () => {};
  window.suscribir = () => {};
  window.revisarAlertas = () => {};
  window.toast = m => { window.__ultimoToast = m; };

  // ---------- 1. la puerta del panel ----------
  await window.__manejar({ user: { id: 'u2' } });
  ok('1. al repartidor lo rebota del panel', visible('soloApp') && !visible('app'));
  ok('1b. y le dice su nombre', /Juan Pérez/.test($('soloApp').textContent));
  ok('1c. y le explica que use la app', /app ZAS Reparto/.test($('soloApp').textContent));
  ok('1d. le cierra la sesión', window.__salidas === 1, String(window.__salidas));
  ok('1e. el cartel NO se pierde al cerrar la sesión', visible('soloApp'),
     'display=' + $('soloApp').style.display);

  $('saSalir').onclick();
  ok('1f. "Volver" lo devuelve al login', visible('login') && !visible('soloApp'));

  // ---------- 2. el admin sí entra ----------
  window.__salidas = 0;
  await window.__manejar({ user: { id: 'u1' } });
  ok('2. el admin entra al panel', visible('app') && !visible('soloApp'));
  ok('2b. sin cerrarle la sesión', window.__salidas === 0);

  // ---------- 3. sin la migración, no se bloquea a nadie ----------
  eval('sesionMontada = null; rebotado = false;');
  $('app').style.display = 'none';
  window.__gente = [{ id: 'u9', nombre: 'Viejo', rol: 'repartidor', activo: true }];
  window.__salidas = 0;
  await window.__manejar({ user: { id: 'u9' } });
  ok('3. base sin la migración: entra igual que antes',
     !visible('soloApp') && window.__salidas === 0,
     'soloApp=' + $('soloApp').style.display + ' salidas=' + window.__salidas);
  window.__gente = GENTE;

  // ---------- 4. cuenta desactivada sigue rebotando por lo suyo ----------
  eval('sesionMontada = null; rebotado = false;');
  window.__gente = [{ id: 'u8', nombre: 'Ex', rol: 'admin', activo: false, puede_panel: true }];
  window.__salidas = 0;
  await window.__manejar({ user: { id: 'u8' } });
  ok('4. una cuenta desactivada no entra',
     window.__salidas === 1 && /desactivada/.test($('lErr').textContent),
     $('lErr').textContent);
  window.__gente = GENTE;

  // ---------- 5. las marcas de la lista ----------
  eval('perfiles = window.__gente;');
  window.__pintarReps();
  const tabla = $('tbodyReps').innerHTML;
  ok('5. marca al que entra al panel y a la app', /Etienne[\s\S]*?panel[\s\S]*?app/.test(tabla));
  ok('5b. al de la app sin panel no le pone panel',
     !/Juan Pérez<\/b><br><span[^>]*>🖥️/.test(tabla));
  ok('5c. marca al que asigna', /Jefe Bodega[\s\S]*?asigna/.test(tabla));
  ok('5d. avisa del que no entra a ningún lado', /no entra a ningún lado/.test(tabla));
  ok('5e. sin migración no muestra marcas',
     window.__marcas({ nombre: 'Viejo' }) === '', window.__marcas({ nombre: 'Viejo' }));

  // ---------- 6. la ficha refleja los tres ----------
  window.__editarRep('u4');
  ok('6. la contadora: panel sí, app no',
     $('ePuedePanel').checked === true && $('ePuedeApp').checked === false);
  window.__editarRep('u3');
  ok('6b. el jefe de bodega: app y asignar, sin panel',
     $('ePuedePanel').checked === false && $('ePuedeApp').checked === true &&
     $('ePuedeAsignar').checked === true);

  // ---------- 7. guardar manda los tres ----------
  window.__updates = [];
  window.__editarRep('u2');
  $('ePuedePanel').checked = true;
  await $('eGuardar').onclick();
  const v = window.__updates.at(-1)?.v || {};
  ok('7. guarda los tres permisos juntos',
     v.puede_panel === true && v.puede_app === true && v.puede_asignar === false,
     JSON.stringify(v));

  // ---------- 8. no te dejás afuera sin querer ----------
  window.__editarRep('u1');
  ok('8. edita tu propia cuenta y te avisa',
     $('ePermAviso').style.display === 'block' && /TU cuenta/.test($('ePermAviso').textContent),
     $('ePermAviso').textContent);
  window.__updates = [];
  window.confirm = () => false;              // el usuario dice "no"
  $('ePuedePanel').checked = false;
  await $('eGuardar').onclick();
  ok('8b. si te apagás el panel a vos mismo, pide confirmación y respeta el "no"',
     window.__updates.length === 0);
  window.confirm = () => true;               // ahora dice "sí"
  await $('eGuardar').onclick();
  ok('8c. y si confirmás, lo guarda',
     window.__updates.at(-1)?.v.puede_panel === false);

  // ---------- 9. sin la migración, no se pierde el resto de la ficha ----------
  window.__updates = [];
  window.__falla = (val) => ('puede_panel' in val)
    ? { message: 'column "puede_panel" of relation "perfiles" does not exist' } : null;
  window.__editarRep('u3');
  $('eNombre').value = 'Jefe Bodega 2';
  await $('eGuardar').onclick();
  ok('9. reintenta sin los permisos',
     window.__updates.length === 2 &&
     !('puede_panel' in window.__updates[1].v) &&
     !('puede_app' in window.__updates[1].v) &&
     !('puede_asignar' in window.__updates[1].v),
     JSON.stringify(window.__updates.map(u => Object.keys(u.v))));
  ok('9b. y el nombre igual se guarda', window.__updates[1]?.v.nombre === 'Jefe Bodega 2');
  ok('9c. y le dice qué archivo correr',
     /migracion-permisos/.test(window.__ultimoToast || ''), window.__ultimoToast);

  return out;
});

await browser.close();
let malos = 0;
for (const t of r) {
  if (!t.ok) malos++;
  console.log((t.ok ? '✅' : '❌') + ' ' + t.n + (t.extra ? ('  ← ' + t.extra) : ''));
}
if (errores.length) {
  console.log('\nERRORES DE LA PÁGINA:');
  errores.forEach(e => console.log('  ' + e));
}
console.log(`\n${r.length - malos}/${r.length} pruebas OK` +
            (errores.length ? ` · ${errores.length} errores de página` : ''));
process.exit(malos || errores.length ? 1 : 0);
