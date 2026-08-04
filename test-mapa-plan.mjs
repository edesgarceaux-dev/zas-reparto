/* ============================================================
   EL MAPA CON PEDIDOS COMPARTIDOS

   El caso que se rompía: le asignás 929 pedidos compartidos a un
   repartidor y el mapa decía «0 activos» y no dibujaba nada.
   ============================================================ */
import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
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
  const $ = id => document.getElementById(id);

  // 6 compartidos previstos para Hans, 2 propios de Martín, 2 sin nadie
  const PED = [];
  for (let i = 1; i <= 6; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Compartido ' + i,
    direccion: 'Calle ' + i, comuna: 'La Florida', cliente_id: 1,
    estado: 'pendiente', empresa_reparto_id: null, repartidor_id: null,
    ruta_orden: null, lat: -33.55 + i * .01, lng: -70.58 + i * .01,
    fecha_pedido: '2026-08-04', creado_en: '2026-08-04T10:00:00Z',
  });
  for (let i = 7; i <= 8; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Propio ' + i,
    direccion: 'Calle ' + i, comuna: 'Maipú', cliente_id: 1,
    estado: 'asignado', empresa_reparto_id: 1, repartidor_id: 'r2',
    ruta_orden: i - 6, lat: -33.51 + i * .01, lng: -70.76 + i * .01,
    fecha_pedido: '2026-08-04', creado_en: '2026-08-04T10:00:00Z',
  });
  for (let i = 9; i <= 10; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Sin nadie ' + i,
    direccion: 'Calle ' + i, comuna: 'Ñuñoa', cliente_id: 1,
    estado: 'pendiente', empresa_reparto_id: null, repartidor_id: null,
    ruta_orden: null, lat: -33.45, lng: -70.60,
    fecha_pedido: '2026-08-04', creado_en: '2026-08-04T10:00:00Z',
  });

  window.__P = PED;
  // el plan le da los 6 compartidos a Hans, en orden 6,5,4,3,2,1
  window.__PL = [6, 5, 4, 3, 2, 1].map((id, i) => ({
    pedido_id: id, repartidor_id: 'r1', orden: i + 1 }));

  eval(`
    pedidos   = window.__P;
    poolPedidos = [];
    misPlanes = window.__PL;
    perfiles  = [{id:'r1',nombre:'Hans Stuardo',rol:'repartidor',activo:true},
                 {id:'r2',nombre:'Martin Lagos',rol:'repartidor',activo:true}];
    clientes  = [{id:1,nombre:'DISTRIBUIDORA PEPITO',lat:-33.45,lng:-70.66}];
    HAY_POOL  = true;
    window.__poblar   = poblarSelectorRuta;
    window.__deRuta   = pedidosDeRuta;
    window.__ordenar  = ordenarParaRuta;
    window.__ordenEf  = ordenEfectivo;
    window.__pares    = paresDeOrden;
    window.__guardar  = guardarOrden;
    window.__setProp  = v => { ordenPropuesto = v; };
  `);
  window.hoyDia = () => '2026-08-04';

  // ---------- 1. el selector cuenta los previstos ----------
  window.__poblar();
  const ops = [...$('rutaRep').options].map(o => o.textContent);
  ok('1. Hans aparece con sus 6 pedidos previstos, no con 0',
     /Hans Stuardo — 6 activos/.test(ops.join(' | ')), ops.join(' | '));
  ok('1b. Martín cuenta los suyos de siempre',
     /Martin Lagos — 2 activos/.test(ops.join(' | ')), ops.join(' | '));
  ok('1c. «Sin asignar» ya no cuenta los que tienen repartidor previsto',
     /Sin asignar \(2\)/.test(ops.join(' | ')), ops.join(' | '));

  // ---------- 2. la ruta de Hans trae sus puntos ----------
  $('rutaRep').value = 'r1';
  const ruta = window.__deRuta();
  ok('2. la ruta de Hans trae los 6 puntos', ruta.length === 6, String(ruta.length));
  ok('2b. todos con coordenadas para dibujar en el mapa',
     ruta.every(p => p.lat != null && p.lng != null));

  $('rutaRep').value = 'r2';
  ok('2c. la de Martín trae los suyos', window.__deRuta().length === 2,
     String(window.__deRuta().length));

  $('rutaRep').value = '';
  ok('2d. «Sin asignar» solo muestra los que no tienen a nadie',
     window.__deRuta().length === 2 &&
     window.__deRuta().every(p => /Sin nadie/.test(p.cliente_nombre)),
     window.__deRuta().map(p => p.cliente_nombre).join(', '));

  // ---------- 3. el orden viene del plan ----------
  ok('3. el orden de un compartido sale del plan',
     window.__ordenEf(PED[5]) === 1, String(window.__ordenEf(PED[5])));
  ok('3b. y el de uno propio, del pedido',
     window.__ordenEf(PED[6]) === 1, String(window.__ordenEf(PED[6])));

  $('rutaRep').value = 'r1';
  const orden = window.__ordenar(window.__deRuta()).map(p => p.id);
  ok('3c. la ruta se dibuja en el orden del plan (6,5,4,3,2,1)',
     orden.join(',') === '6,5,4,3,2,1', orden.join(','));

  // ---------- 4. guardar el orden va a donde corresponde ----------
  window.__upd = []; window.__rpcs = [];
  eval(`
    sb.from = () => ({ update:(v)=>{ const o={ eq:(c,id)=>{ window.__upd.push({id, v});
      return { then:(f)=>Promise.resolve({data:[{id}],error:null}).then(f) }; } }; return o; } });
    sb.rpc = async (n,a)=>{ window.__rpcs.push({n,a}); return {data:{planificados:(a.p_ids||[]).length},error:null}; };
  `);
  window.toast = m => { window.__toast = m; };
  window.cargarTodo = async () => {};

  window.__setProp([1, 2, 3, 4, 5, 6]);
  await window.__guardar();
  ok('4. los compartidos guardan su orden en el plan',
     window.__rpcs.some(x => x.n === 'planificar_pedidos' &&
                        x.a.p_ids.join(',') === '1,2,3,4,5,6' && x.a.p_repartidor === 'r1'),
     JSON.stringify(window.__rpcs));
  ok('4b. y NO se intenta escribir en la tabla de pedidos',
     window.__upd.length === 0, JSON.stringify(window.__upd));

  // una ruta de pedidos propios: esa sí va a `pedidos`
  window.__upd = []; window.__rpcs = [];
  $('rutaRep').value = 'r2';
  window.__setProp([8, 7]);
  await window.__guardar();
  ok('5. una ruta de pedidos propios sí escribe ruta_orden',
     window.__upd.length === 2 &&
     window.__upd[0].id === 8 && window.__upd[0].v.ruta_orden === 1 &&
     window.__upd[1].id === 7 && window.__upd[1].v.ruta_orden === 2,
     JSON.stringify(window.__upd));
  ok('5b. y no llama a planificar de gusto',
     !window.__rpcs.some(x => x.n === 'planificar_pedidos'), JSON.stringify(window.__rpcs));

  // mezcla: cada uno a su lado, conservando la posición real de la ruta
  window.__upd = []; window.__rpcs = [];
  $('rutaRep').value = 'r1';
  window.__setProp([1, 7, 2, 8]);
  await window.__guardar();
  ok('6. en una ruta mezclada, los propios guardan su posición REAL',
     window.__upd.length === 2 &&
     window.__upd.find(u => u.id === 7)?.v.ruta_orden === 2 &&
     window.__upd.find(u => u.id === 8)?.v.ruta_orden === 4,
     JSON.stringify(window.__upd));
  ok('6b. y los compartidos van al plan',
     window.__rpcs.some(x => x.n === 'planificar_pedidos' && x.a.p_ids.join(',') === '1,2'),
     JSON.stringify(window.__rpcs));

  // ---------- 7. sin repartidor elegido no se puede guardar un plan ----------
  window.__rpcs = [];
  $('rutaRep').value = '';
  window.__setProp([1, 2]);
  await window.__guardar();
  ok('7. sin repartidor elegido avisa en vez de perder el trabajo',
     !window.__rpcs.length && /Eleg/.test(window.__toast || ''), window.__toast);

  // ---------- 8. sin la red instalada, todo como antes ----------
  eval('HAY_POOL = false;');
  window.__poblar();
  const ops2 = [...$('rutaRep').options].map(o => o.textContent);
  ok('8. sin la red, el mapa cuenta solo por repartidor_id',
     /Hans Stuardo — 0 activos/.test(ops2.join(' | ')) &&
     /Martin Lagos — 2 activos/.test(ops2.join(' | ')), ops2.join(' | '));
  eval('HAY_POOL = true;');

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
