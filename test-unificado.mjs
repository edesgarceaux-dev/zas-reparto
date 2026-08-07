/* ============================================================
   UNA SOLA LISTA DE PEDIDOS

   El caso que se rompía: el de bodega escanea 20 bultos, después le
   quita el repartidor a los 20, y quedan atrapados en «📦 Mi carga».
   No salen en Pedidos, no los ve «Repartir auto», no están en los
   tiles del resumen. Veinte bultos en la mesa y ninguna pantalla
   desde la cual moverlos.
   ============================================================ */
import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const page = await browser.newPage();
const errores = [];
page.on('pageerror', e => errores.push('pageerror: ' + e.message));
page.on('console', m => {
  if (m.type() === 'error' &&
      !/ERR_CONNECTION|ERR_FILE_NOT_FOUND|ERR_NAME_NOT_RESOLVED|Failed to load resource|leaflet/i.test(m.text()))
    errores.push('console: ' + m.text());
});
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra = '') => out.push({ n, ok: !!cond, extra });
  const HOY = new Date().toLocaleDateString('en-CA');
  const $ = id => document.getElementById(id);

  // 20 bultos escaneados por el de bodega y después desasignados:
  // cargado_en puesto, empresa nuestra, sin repartidor.
  const PED = [];
  for (let i = 1; i <= 20; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, externo_id: '' + (82800 + i), origen: 'jumpseller',
    cliente_nombre: 'Cargado ' + i, direccion: 'Calle ' + i, comuna: 'La Florida',
    cliente_id: 1, estado: 'pendiente', empresa_reparto_id: 1, repartidor_id: null,
    cargado_en: HOY + 'T13:20:00Z', ruta_orden: null,
    lat: -33.55 + i * .002, lng: -70.58 + i * .002,
    fecha_pedido: HOY, creado_en: HOY + 'T10:00:00Z',
  });
  // 5 recién llegados, sin escanear
  for (let i = 21; i <= 25; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, externo_id: '' + (82800 + i), origen: 'jumpseller',
    cliente_nombre: 'Nuevo ' + i, direccion: 'Calle ' + i, comuna: 'Maipú',
    cliente_id: 1, estado: 'pendiente', empresa_reparto_id: 1, repartidor_id: null,
    cargado_en: null, ruta_orden: null, lat: -33.51, lng: -70.76,
    fecha_pedido: HOY, creado_en: HOY + 'T10:00:00Z',
  });
  // 2 ya asignados y escaneados: esos no están «sueltos»
  for (let i = 26; i <= 27; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, externo_id: '' + (82800 + i), origen: 'jumpseller',
    cliente_nombre: 'Con dueño ' + i, direccion: 'Calle ' + i, comuna: 'Ñuñoa',
    cliente_id: 1, estado: 'asignado', empresa_reparto_id: 1, repartidor_id: 'r1',
    cargado_en: HOY + 'T13:20:00Z', ruta_orden: null, lat: -33.45, lng: -70.60,
    fecha_pedido: HOY, creado_en: HOY + 'T10:00:00Z',
  });

  window.__P = PED;
  eval(`
    HAY_POOL = true;
    perfiles = [{id:'r1',nombre:'Hans Stuardo',rol:'repartidor',activo:true},
                {id:'r2',nombre:'Martin Lagos',rol:'repartidor',activo:true}];
    clientes = [{id:1,nombre:'DISTRIBUIDORA PEPITO',lat:-33.45,lng:-70.66,hora_corte:'12:00'}];
    misPlanes = [];
    repartirPedidos(window.__P);
    window.__reparte  = () => ({ pedidos: pedidos.length, carga: poolPedidos.length });
    window.__pintar   = pintarPedidos;
    window.__tiles    = pintarTiles;
    window.__filtro   = v => { filtro = v; };
    window.__lista    = () => ultimaListaFiltrada;
    window.__todos    = todosLosPedidos;
    window.__auto     = () => autoLista;
    window.__sel      = seleccion;
  `);

  // ---------- 1. las dos listas siguen separadas por dentro ----------
  const rep = window.__reparte();
  ok('1. «Mi carga» sigue teniendo los 22 escaneados', rep.carga === 22, JSON.stringify(rep));
  ok('1b. y la lista cruda de no-cargados tiene los 5 nuevos', rep.pedidos === 5, JSON.stringify(rep));
  ok('1c. pero juntas son las 27: ninguna se pierde', window.__todos().length === 27,
     String(window.__todos().length));

  // ---------- 2. la pestaña Pedidos los muestra TODOS ----------
  window.__filtro('activos');
  window.__pintar();
  ok('2. Pedidos muestra los 27, no solo los 5 sin escanear',
     window.__lista().length === 27, String(window.__lista().length));
  const filas = $('tbodyPed').innerHTML;
  ok('2b. los que están en bodega llevan su 📦',
     (filas.match(/📦/g) || []).length === 22,
     String((filas.match(/📦/g) || []).length));
  ok('2c. y los recién llegados no lo llevan',
     /Nuevo 21/.test(filas) && !/Nuevo 21<\/b>[\s\S]{0,200}📦/.test(filas));

  // ---------- 3. el chip que rescata los bultos huérfanos ----------
  const chips = $('chipsFiltros').textContent;
  ok('3. aparece el chip «Cargados sin repartidor (20)»',
     /Cargados sin repartidor \(20\)/.test(chips), chips);
  window.__filtro('cargados_sueltos');
  window.__pintar();
  ok('3b. y filtra exactamente esos 20', window.__lista().length === 20,
     String(window.__lista().length));
  ok('3c. sin colar los que ya tienen repartidor',
     !window.__lista().includes(26) && !window.__lista().includes(27),
     window.__lista().join(','));

  // ---------- 4. «Sin asignar» tampoco los esconde ----------
  window.__filtro('sin_asignar');
  window.__pintar();
  ok('4. «Sin asignar» son los 20 de bodega + los 5 nuevos',
     window.__lista().length === 25, String(window.__lista().length));

  // ---------- 5. el desplegable de repartidor los cuenta ----------
  const opsR = [...$('fRep').options].map(o => o.textContent).join(' | ');
  ok('5. «Sin repartidor» dice 25, no 5', /Sin repartidor \(25\)/.test(opsR), opsR);
  ok('5b. y Hans sigue con sus 2', /Hans Stuardo \(2\)/.test(opsR), opsR);

  // ---------- 6. los tiles del resumen ----------
  window.__tiles();
  const tiles = $('tiles').textContent;
  ok('6. «Pedidos hoy» cuenta los 27', /27\s*Pedidos hoy/.test(tiles.replace(/\s+/g, ' ')), tiles);
  ok('6b. «Sin asignar» cuenta los 25', /25\s*Sin asignar/.test(tiles.replace(/\s+/g, ' ')), tiles);

  // ---------- 7. «Repartir auto» los agarra ----------
  window.toast = m => { window.__toast = m; };
  window.__sel.clear();
  window.abrirAutoRepartir();
  ok('7. el repartidor automático ve los 25 sin asignar',
     window.__auto().length === 25, String(window.__auto().length));
  ok('7b. y entre ellos están los de bodega',
     window.__auto().some(p => p.id === 1 && p.cargado_en),
     window.__auto().map(p => p.id).join(','));
  ok('7c. no vuelve a repartir los que ya tienen repartidor',
     !window.__auto().some(p => p.id === 26 || p.id === 27));

  // ---------- 8. se pueden seleccionar y accionar desde Pedidos ----------
  window.__filtro('cargados_sueltos');
  window.__pintar();
  window.seleccionarTodos(true);
  ok('8. seleccionar todo marca los 20 bultos huérfanos',
     window.__sel.size === 20, String(window.__sel.size));
  ok('8b. y cada uno se encuentra por id esté en la lista que esté',
     [...window.__sel].every(id => !!window.__todos().find(p => p.id === id)));
  window.__sel.clear();

  // ---------- 9. sin la red, nada de esto cambia ----------
  eval(`
    HAY_POOL = false;
    repartirPedidos(window.__P);
  `);
  window.__filtro('activos');
  window.__pintar();
  ok('9. sin la red, la lista sigue siendo una sola de 27',
     window.__lista().length === 27, String(window.__lista().length));
  const chips2 = $('chipsFiltros').textContent;
  ok('9b. y el chip de bodega aparece igual si hay bultos sueltos',
     /Cargados sin repartidor \(20\)/.test(chips2), chips2);

  return out;
});

let bien = 0;
for (const x of r) {
  console.log(x.ok ? `✅ ${x.n}` : `❌ ${x.n}  ← ${x.extra}`);
  if (x.ok) bien++;
}
if (errores.length) { console.log('\n⚠️ errores de página:'); errores.forEach(e => console.log('   ' + e)); }
console.log(`\n${bien}/${r.length} pruebas OK`);
await browser.close();
process.exit(bien === r.length && !errores.length ? 0 : 1);
