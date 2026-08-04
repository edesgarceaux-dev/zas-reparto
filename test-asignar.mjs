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

  // ---------- gente de mentira ----------
  const GENTE = [
    { id: 'u1', nombre: 'Etienne',     rol: 'admin',      activo: true,  puede_asignar: true  },
    { id: 'u2', nombre: 'Juan Pérez',  rol: 'repartidor', activo: true,  puede_asignar: false },
    { id: 'u3', nombre: 'Jefe Bodega', rol: 'repartidor', activo: true,  puede_asignar: true,
      telefono: '912345678', correo: 'bodega@zas.cl', comuna_preferida: 'Maipú' },
  ];
  window.__updates = [];
  window.__falla = null;
  eval(`
    perfiles = window.__gente;
    adminUid = 'u1';
    sb.from = (t) => ({
      update: (v) => {
        const err = window.__falla && window.__falla(v);
        const res = { data: null, error: err };
        const o = { eq: () => o, select: () => o,
                    maybeSingle: () => Promise.resolve(res),
                    then: (f) => Promise.resolve(res).then(f) };
        window.__updates.push({ t, v });
        return o;
      },
      select: () => { const o = { eq:()=>o, order:()=>o, limit:()=>o,
                    maybeSingle:()=>Promise.resolve({data:null,error:null}),
                    then:(f)=>Promise.resolve({data:[],error:null}).then(f) }; return o; },
    });
    window.__pintarReps = pintarReps;
    window.__editarRep  = editarRep;
  `);
  window.__gente = GENTE;
  // eval corre antes de que window.__gente exista: se reasigna
  eval('perfiles = window.__gente;');
  window.cargarTodo = async () => {};
  window.toast = (m) => { window.__ultimoToast = m; };

  // ---------- 1. la casilla existe en la ficha ----------
  ok('1. la ficha tiene la casilla de asignar por QR', !!$('ePuedeAsignar'));
  ok('1b. y explica para qué sirve',
     /pasando los bultos por la c/i.test($('mEditRep').textContent),
     $('mEditRep').textContent.replace(/\s+/g, ' ').slice(0, 90));

  // ---------- 2. la lista marca a quien puede ----------
  window.__pintarReps();
  const tabla = $('tbodyReps').innerHTML;
  ok('2. la lista marca al que puede asignar', /Jefe Bodega[\s\S]*?asigna/.test(tabla));
  ok('2b. y no marca al repartidor común',
     !/Juan Pérez[\s\S]*?asigna[\s\S]*?<\/tr>/.test(tabla.split('Jefe Bodega')[0]));

  // ---------- 3. abrir la ficha refleja el estado real ----------
  window.__editarRep('u3');
  ok('3. al abrir a un habilitado, la casilla viene marcada', $('ePuedeAsignar').checked);
  ok('3b. y trae el resto de sus datos',
     $('eNombre').value === 'Jefe Bodega' && $('eTel').value === '912345678');

  window.__editarRep('u2');
  ok('3c. al abrir a uno sin permiso, viene desmarcada', $('ePuedeAsignar').checked === false);

  // ---------- 4. guardar prende el permiso ----------
  window.__editarRep('u2');
  $('ePuedeAsignar').checked = true;
  await $('eGuardar').onclick();
  ok('4. guardar manda puede_asignar = true',
     window.__updates.some(u => u.t === 'perfiles' && u.v.puede_asignar === true),
     JSON.stringify(window.__updates.slice(-1)));

  // ---------- 5. apagarlo también se guarda ----------
  window.__updates = [];
  window.__editarRep('u3');
  $('ePuedeAsignar').checked = false;
  await $('eGuardar').onclick();
  ok('5. apagarlo manda puede_asignar = false',
     window.__updates.some(u => u.t === 'perfiles' && u.v.puede_asignar === false),
     JSON.stringify(window.__updates.slice(-1)));

  // ---------- 6. sin la migración, no se pierde el resto ----------
  window.__updates = [];
  window.__falla = (v) => ('puede_asignar' in v)
    ? { message: `column "puede_asignar" of relation "perfiles" does not exist` }
    : null;
  window.__editarRep('u3');
  $('eNombre').value = 'Jefe Bodega 2';
  $('ePuedeAsignar').checked = true;
  await $('eGuardar').onclick();
  ok('6. si falta la migración, reintenta sin el permiso',
     window.__updates.length === 2 && !('puede_asignar' in window.__updates[1].v),
     JSON.stringify(window.__updates.map(u => Object.keys(u.v))));
  ok('6b. y el nombre igual se guarda',
     window.__updates[1]?.v.nombre === 'Jefe Bodega 2');
  ok('6c. y le avisa qué archivo correr',
     /migracion-permisos|migracion-asignar-por-qr/.test(window.__ultimoToast || ''),
     window.__ultimoToast);

  // ---------- 7. el nombre sigue siendo obligatorio ----------
  window.__falla = null;
  window.__updates = [];
  window.__editarRep('u3');
  $('eNombre').value = '   ';
  await $('eGuardar').onclick();
  ok('7. no deja guardar sin nombre',
     window.__updates.length === 0 && /obligatorio/.test($('eErr').textContent),
     $('eErr').textContent);

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
