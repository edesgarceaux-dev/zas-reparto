/* ============================================================
   CARGAR POR QR — asignar es quedárselo también acá  (v1.53)

   Antes, "Cargar por QR" (cqProcesar) hacía un update directo `.eq('id')`:
     · un pedido COMPARTIDO quedaba con empresa_reparto_id = NULL, así que
       otra empresa se lo podía llevar igual aunque acá dijera "cargado";
     · con 0 filas (RLS, o tomado por otro) marcaba "✓ cargado" en falso.

   Ahora cqProcesar pasa por asignarRepartidorA: tomar_y_asignar para
   compartidos (queda de la empresa en firme) y update verificado para los
   propios. Este test lo blinda.
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

  const nuevos = () => ([
    // 1 compartido (de nadie), 2 ya mío
    { id: 1, codigo: 'ZAS-1', externo_id: null, cliente_nombre: 'Compartido', direccion: 'Calle 1',
      comuna: 'La Florida', cliente_id: 1, estado: 'pendiente', empresa_reparto_id: null,
      repartidor_id: null, cargado_en: null, ruta_orden: null, fecha_pedido: HOY, creado_en: HOY + 'T10:00:00Z' },
    { id: 2, codigo: 'ZAS-2', externo_id: null, cliente_nombre: 'Mío', direccion: 'Calle 2',
      comuna: 'Maipú', cliente_id: 1, estado: 'pendiente', empresa_reparto_id: 1,
      repartidor_id: null, cargado_en: null, ruta_orden: null, fecha_pedido: HOY, creado_en: HOY + 'T10:00:00Z' },
  ]);

  window.__P = nuevos();
  eval(`
    HAY_POOL = true; miEmpresa = 1; soySuper = false;
    perfiles = [{id:'r1',nombre:'Hans Stuardo',rol:'repartidor',activo:true}];
    clientes = [{id:1,nombre:'DISTRIBUIDORA PEPITO'}];
    empresas = [{id:1,nombre:'Envíos ZAS'}];
    misPlanes = [];
    repartirPedidos(window.__P);
    window.__cq       = cqProcesar;
    window.__P0       = () => pedidoPorId(1);
    window.__esComp   = esCompartido;
  `);
  window.toast = m => { window.__toast = m; };
  window.cargarTodo = async () => {};
  // el flujo espera un repartidor elegido en el <select> #cqRep
  eval(`document.getElementById('cqRep').innerHTML = '<option value="r1" selected>Hans</option>';
        document.getElementById('cqRep').value = 'r1';`);

  const espiar = (opciones = {}) => {
    window.__rpcs = []; window.__upd = [];
    window.__P = nuevos();
    eval(`
      cqUltimo = ''; cqUltimaVez = 0;   // soltar el anti-rebote entre escaneos del test
      repartirPedidos(window.__P);
      sb.rpc = async (n, a) => {
        window.__rpcs.push({ n, a });
        if (n === 'tomar_y_asignar') {
          const tomados = (a.p_ids||[]).filter(id => !(window.__pierde||[]).includes(id));
          return { data:{ asignados:tomados.length, ids:tomados,
                          rechazados:(window.__pierde||[]).map(id=>({id,motivo:'se adelantó Rapiditos 360'})) }, error:null };
        }
        if (n === 'planificar_pedidos')
          return { data:{ planificados:(a.p_ids||[]).length, rechazados:(window.__pierde||[]).map(id=>({id,motivo:'se adelantó Rapiditos 360'})) }, error:null };
        return { data:null, error:null };
      };
      sb.from = () => ({
        update: v => ({
          in: (c, ids) => ({ not: () => ({ select: async () => ({ data: ids.map(id=>({id})), error:null }) }) }),
          eq: (c, id) => { window.__upd.push({ id, v }); return { then: f => Promise.resolve({ data:[{id}], error:null }).then(f) }; },
        })
      });
    `);
    window.__pierde = opciones.pierde || [];
  };

  // ---------- 1. escanear un COMPARTIDO pasa por tomar_y_asignar ----------
  espiar();
  await window.__cq('ZAS-1');
  const llam = window.__rpcs.find(x => x.n === 'tomar_y_asignar');
  ok('1. un compartido escaneado pasa por tomar_y_asignar (no update directo)',
     !!llam && !window.__upd.some(u => u.id === 1),
     JSON.stringify({ rpcs: window.__rpcs.map(x=>x.n), upd: window.__upd }));
  ok('1b. queda de mi empresa en firme (no NULL)', window.__P0().empresa_reparto_id === 1,
     String(window.__P0().empresa_reparto_id));
  ok('1c. y asignado al repartidor elegido', window.__P0().repartidor_id === 'r1' && !window.__esComp(window.__P0()));

  // ---------- 2. si otra empresa se adelantó, NO marca éxito falso ----------
  espiar({ pierde: [1] });
  window.__toast = '';
  await window.__cq('ZAS-1');
  const p = window.__P.find(x => x.id === 1);
  ok('2. si se adelantó otra empresa, el pedido NO queda como mío',
     p.empresa_reparto_id === null || p.repartidor_id !== 'r1',
     JSON.stringify({ emp: p.empresa_reparto_id, rep: p.repartidor_id }));
  ok('2b. y el aviso dice que no se pudo (no "cargado")',
     /no se pudo|adelant|previsto/i.test(document.getElementById('cqAviso').textContent),
     document.getElementById('cqAviso').textContent);

  // ---------- 3. un pedido YA MÍO se asigna con update verificado ----------
  espiar();
  await window.__cq('ZAS-2');
  ok('3. un pedido propio no llama tomar_y_asignar', !window.__rpcs.some(x => x.n === 'tomar_y_asignar'),
     JSON.stringify(window.__rpcs.map(x=>x.n)));
  ok('3b. queda asignado a mi repartidor', window.__P.find(x=>x.id===2).repartidor_id === 'r1');

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
