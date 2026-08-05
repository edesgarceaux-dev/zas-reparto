/* ============================================================
   ASIGNAR ES QUEDÁRSELO

   Con la red, asignar un pedido compartido guardaba una intención en
   `plan_reparto` («previsto») y el pedido quedaba partido en dos tablas
   hasta que alguien lo escaneara. De ahí salieron el mapa vacío, «0
   activos», la ruta desordenada y el previsto que no se iba.

   Ahora elegir repartidor lo toma Y lo asigna: el pedido queda entero en
   `pedidos`, como antes de que existieran las otras empresas.
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
  const HOY = new Date().toLocaleDateString('en-CA');

  const nuevos = () => {
    const P = [];
    // 1..6 compartidos (de nadie todavía), 7..8 ya míos
    for (let i = 1; i <= 6; i++) P.push({
      id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Compartido ' + i,
      direccion: 'Calle ' + i, comuna: 'La Florida', cliente_id: 1,
      estado: 'pendiente', empresa_reparto_id: null, repartidor_id: null,
      cargado_en: null, ruta_orden: null, lat: -33.55 + i * .01, lng: -70.58 + i * .01,
      fecha_pedido: HOY, creado_en: HOY + 'T10:00:00Z',
    });
    for (let i = 7; i <= 8; i++) P.push({
      id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Mío ' + i,
      direccion: 'Calle ' + i, comuna: 'Maipú', cliente_id: 1,
      estado: 'pendiente', empresa_reparto_id: 1, repartidor_id: null,
      cargado_en: null, ruta_orden: null, lat: -33.51, lng: -70.76,
      fecha_pedido: HOY, creado_en: HOY + 'T10:00:00Z',
    });
    return P;
  };

  window.__P = nuevos();
  eval(`
    HAY_POOL = true; miEmpresa = 1; soySuper = false;
    perfiles = [{id:'r1',nombre:'Hans Stuardo',rol:'repartidor',activo:true},
                {id:'r2',nombre:'Martin Lagos',rol:'repartidor',activo:true}];
    clientes = [{id:1,nombre:'DISTRIBUIDORA PEPITO',lat:-33.45,lng:-70.66}];
    empresas = [{id:1,nombre:'Envíos ZAS'}];
    misPlanes = [];
    repartirPedidos(window.__P);
    window.__asignar  = asignarRepartidorA;
    window.__quitar   = quitarAsignacionA;
    window.__pares    = paresDeOrden;
    window.__guardarO = guardarOrdenDeRuta;
    window.__repEf    = repartidorEfectivo;
    window.__ordenEf  = ordenEfectivo;
    window.__esComp   = esCompartido;
    window.__resetP   = () => { misPlanes = []; repartirPedidos(window.__P); };
    window.__planes   = () => misPlanes;
    window.__setPlanes= v => { misPlanes = v; };
  `);
  window.toast = m => { window.__toast = m; };
  window.cargarTodo = async () => {};

  // ---- espía de la base ----
  const espiar = (opciones = {}) => {
    window.__rpcs = []; window.__upd = [];
    window.__P = nuevos();
    eval(`
      window.__resetP();
      sb.rpc = async (n, a) => {
        window.__rpcs.push({ n, a });
        if (n === 'tomar_y_asignar') {
          if (window.__sinFuncion)
            return { data:null, error:{ message:'Could not find the function public.tomar_y_asignar' } };
          const tomados = (a.p_ids||[]).filter(id => !(window.__pierde||[]).includes(id));
          return { data:{ asignados:tomados.length, ids:tomados,
                          rechazados:(window.__pierde||[]).map(id=>({id,motivo:'se adelantó Rapiditos 360'})) },
                   error:null };
        }
        if (n === 'planificar_pedidos')
          return { data:{ planificados:(a.p_ids||[]).length, rechazados:[] }, error:null };
        if (n === 'desplanificar_pedidos')
          return { data:{ sacados:(a.p_ids||[]).length }, error:null };
        return { data:null, error:null };
      };
      sb.from = () => ({
        update: v => ({
          in: (c, ids) => ({ not: () => ({ select: async () => ({ data: ids.map(id=>({id})), error:null }) }) }),
          eq: (c, id) => { window.__upd.push({ id, v });
            return { then: f => Promise.resolve({ data:[{id}], error:null }).then(f) }; },
        })
      });
    `);
    window.__sinFuncion = !!opciones.sinFuncion;
    window.__pierde = opciones.pierde || [];
  };

  // ---------- 1. lo compartido pasa a ser mío ----------
  espiar();
  let res = await window.__asignar([3, 1, 2], 'r1');
  const llam = window.__rpcs.find(x => x.n === 'tomar_y_asignar');
  ok('1. se llama a tomar_y_asignar, no a planificar', !!llam && !window.__rpcs.some(x=>x.n==='planificar_pedidos'),
     JSON.stringify(window.__rpcs.map(x=>x.n)));
  ok('1b. con los ids EN ORDEN DE RUTA', llam && llam.a.p_ids.join(',') === '3,1,2',
     JSON.stringify(llam?.a));
  ok('1c. y con el repartidor elegido', llam && llam.a.p_repartidor === 'r1');
  ok('1d. los tres quedan asignados en firme', res.enFirme === 3 && res.n === 3,
     JSON.stringify(res));
  ok('1e. ninguno queda «previsto»', res.previstos === 0 && res.compartidos === 0,
     JSON.stringify(res));

  // ---------- 2. dejan de ser un caso especial en el acto ----------
  const p3 = window.__P.find(p => p.id === 3);
  ok('2. el pedido ya no es compartido', !window.__esComp(p3));
  ok('2b. su repartidor sale de `pedidos`', window.__repEf(p3) === 'r1', String(window.__repEf(p3)));
  ok('2c. y el plan quedó limpio', window.__planes().length === 0);

  // ---------- 3. el orden de ruta se puede guardar donde el mapa lo busca ----------
  const pares = window.__pares([3, 1, 2].map(id => ({ id })));
  ok('3. los tres entran al guardado de ruta_orden', pares.length === 3, JSON.stringify(pares));
  ok('3b. conservando la posición de la ruta',
     pares[0].id === 3 && pares[0].orden === 1 && pares[2].id === 2 && pares[2].orden === 3,
     JSON.stringify(pares));
  await window.__guardarO(pares);
  ok('3c. y se escriben en la tabla de pedidos', window.__upd.length === 3,
     JSON.stringify(window.__upd));

  // ---------- 4. mezcla: unos míos y otros compartidos ----------
  espiar();
  res = await window.__asignar([7, 1, 8, 2], 'r2');
  ok('4. los cuatro quedan asignados', res.n === 4, JSON.stringify(res));
  ok('4b. dos ya eran míos', res.mios.length === 2, JSON.stringify(res.mios));
  ok('4c. y dos pasaron a serlo', res.enFirme === 2, String(res.enFirme));

  // ---------- 5. si otra empresa se adelantó, ese vuelve a «previsto» ----------
  espiar({ pierde: [2] });
  res = await window.__asignar([1, 2, 3], 'r1');
  ok('5. los que sí se pudieron quedan en firme', res.enFirme === 2, JSON.stringify(res));
  ok('5b. el perdido se intenta planificar igual',
     window.__rpcs.some(x => x.n === 'planificar_pedidos' && x.a.p_ids.join(',') === '2'),
     JSON.stringify(window.__rpcs));
  ok('5c. y no se cuenta dos veces: si el previsto entró, no es un rechazo',
     (res.rechazados || []).length === 0, JSON.stringify(res.rechazados));
  ok('5c-bis. queda contado como previsto, no como perdido',
     res.previstos === 1, String(res.previstos));
  ok('5d. el total suma los dos caminos', res.n === 3, String(res.n));

  // ---------- 6. base sin la migración: sigue funcionando como antes ----------
  espiar({ sinFuncion: true });
  res = await window.__asignar([1, 2, 3], 'r1');
  ok('6. sin la función nueva no se rompe nada', res.errores.length === 0,
     JSON.stringify(res.errores));
  ok('6b. cae en planificar_pedidos, como antes',
     window.__rpcs.some(x => x.n === 'planificar_pedidos' && x.a.p_ids.join(',') === '1,2,3'),
     JSON.stringify(window.__rpcs.map(x=>x.n)));
  ok('6c. y quedan previstos', res.previstos === 3 && res.enFirme === 0, JSON.stringify(res));

  // ---------- 7. quitar la asignación de uno ya firme ----------
  espiar();
  await window.__asignar([1, 2], 'r1');
  window.__upd = []; window.__rpcs = [];
  const q = await window.__quitar([1, 2]);
  ok('7. se quita con un update normal a `pedidos`', q.n === 2, JSON.stringify(q));
  ok('7b. sin pasar por desplanificar: ya no hay plan que borrar',
     !window.__rpcs.some(x => x.n === 'desplanificar_pedidos'),
     JSON.stringify(window.__rpcs.map(x=>x.n)));
  ok('7c. y el pedido sigue siendo de la empresa: no vuelve al limbo',
     window.__P.find(p => p.id === 1).empresa_reparto_id === 1);

  // ---------- 8. sin red, nada de esto se activa ----------
  espiar();
  eval(`HAY_POOL = false; repartirPedidos(window.__P);`);
  window.__rpcs = [];
  res = await window.__asignar([1, 2, 3], 'r1');
  ok('8. sin la red no se llama a tomar_y_asignar',
     !window.__rpcs.some(x => x.n === 'tomar_y_asignar'),
     JSON.stringify(window.__rpcs.map(x=>x.n)));
  ok('8b. se asignan derecho, como siempre', res.n === 3 && res.enFirme === 0,
     JSON.stringify(res));
  eval(`HAY_POOL = true;`);

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
