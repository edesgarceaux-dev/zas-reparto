/* ============================================================
   EL REPARTIDOR AUTOMÁTICO — ¿reparte lo que se le pide?

   Escenarios con datos parecidos a un día real: pedidos con y sin
   coordenadas, comunas de preferencia que no alcanzan, y cupos fijos.
   ============================================================ */
import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
const page = await browser.newPage();
const errores = [];
page.on('pageerror', e => errores.push('pageerror: ' + e.message));
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra = '') => out.push({ n, ok: !!cond, extra });

  eval(`
    window.__sectores = repartirEnSectores;
    window.__cupos    = calcularCupos;
    window.__orden    = ordenarGrupoPorCercania;
    clientes = [{id:1, nombre:'Bodega', lat:-33.45, lng:-70.66}];
  `);

  // Santiago, más o menos
  const COMUNAS = [
    ['Maipú', -33.51, -70.76], ['Puente Alto', -33.61, -70.57],
    ['Ñuñoa', -33.45, -70.60], ['Providencia', -33.43, -70.61],
    ['La Florida', -33.55, -70.58], ['Las Condes', -33.41, -70.55],
    ['Santiago', -33.44, -70.65], ['Recoleta', -33.41, -70.64],
  ];
  // sin Math.random: una secuencia fija, así el resultado siempre es el mismo
  let semilla = 7;
  const rnd = () => (semilla = (semilla * 1103515245 + 12345) % 2147483648) / 2147483648;

  const hacerPedidos = (n, sinCoordsPct = 0) => {
    const lista = [];
    for (let i = 0; i < n; i++) {
      const [comuna, lat, lng] = COMUNAS[i % COMUNAS.length];
      const sinCoords = (i % 100) < sinCoordsPct;
      lista.push({
        id: i + 1, comuna, estado: 'pendiente',
        lat: sinCoords ? null : lat + (rnd() - .5) * .05,
        lng: sinCoords ? null : lng + (rnd() - .5) * .05,
      });
    }
    return lista;
  };

  const cuenta = g => g.reduce((s, x) => s + x.length, 0);
  const sinRepetir = g => new Set(g.flat().map(p => p.id)).size === cuenta(g);

  // ---------- 1. el caso simple: todo con coordenadas ----------
  {
    const lista = hacerPedidos(90);
    const { grupos, fuera } = window.__sectores(lista, [30, 30, 30], [null, null, null]);
    ok('1. tres repartidores de 30 reciben 30 cada uno',
       grupos.every(g => g.length === 30), grupos.map(g => g.length).join(' / '));
    ok('1b. no queda nadie afuera', fuera.length === 0, String(fuera.length));
    ok('1c. ningún pedido en dos rutas', sinRepetir(grupos));
  }

  // ---------- 2. el caso real: la mitad sin coordenadas ----------
  {
    const lista = hacerPedidos(258, 50);
    const { grupos, fuera } = window.__sectores(lista, [86, 86, 86], [null, null, null]);
    ok('2. con la mitad sin ubicar, igual reparte 86 / 86 / 86',
       grupos.every(g => g.length === 86), grupos.map(g => g.length).join(' / '));
    ok('2b. no se pierde ningún pedido',
       cuenta(grupos) + fuera.length === 258, cuenta(grupos) + ' + ' + fuera.length);
    ok('2c. ninguno repetido', sinRepetir(grupos));
  }

  // ---------- 3. cupos distintos ----------
  {
    const lista = hacerPedidos(200, 30);
    const { grupos } = window.__sectores(lista, [100, 50, 50], [null, null, null]);
    ok('3. respeta cupos distintos (100 / 50 / 50)',
       grupos[0].length === 100 && grupos[1].length === 50 && grupos[2].length === 50,
       grupos.map(g => g.length).join(' / '));
  }

  // ---------- 4. comuna de preferencia que NO alcanza ----------
  {
    // 8 comunas × 10 = 80 pedidos; Maipú tiene 10 nada más
    const lista = hacerPedidos(80);
    const { grupos } = window.__sectores(lista, [40, 40], ['Maipú', null]);
    ok('4. si Maipú no alcanza, igual le completa los 40',
       grupos[0].length === 40, grupos.map(g => g.length).join(' / '));
    const enMaipu = grupos[0].filter(p => p.comuna === 'Maipú').length;
    ok('4b. y se lleva todos los de Maipú que había', enMaipu === 10, String(enMaipu));
    // Las Condes y Puente Alto son los dos extremos opuestos a Maipú:
    // meterlos en esa ruta es cruzar Santiago entero.
    const extremos = grupos[0].filter(p => ['Las Condes', 'Puente Alto'].includes(p.comuna)).length;
    ok('4c. completa con las comunas cercanas, no cruzando la ciudad',
       extremos === 0,
       JSON.stringify(grupos[0].reduce((m, p) => (m[p.comuna] = (m[p.comuna] || 0) + 1, m), {})));
    // y el sector queda compacto: nadie a más de 20 km del centro de la ruta
    const cx = grupos[0].reduce((s, p) => s + p.lat, 0) / grupos[0].length;
    const cy = grupos[0].reduce((s, p) => s + p.lng, 0) / grupos[0].length;
    const radio = Math.max(...grupos[0].map(p =>
      Math.hypot((p.lat - cx) * 111, (p.lng - cy) * 93)));
    ok('4d. y el sector queda compacto (radio menor a 20 km)', radio < 20, radio.toFixed(1) + ' km');
  }

  // ---------- 5. varias comunas de preferencia ----------
  {
    const lista = hacerPedidos(80);
    const { grupos } = window.__sectores(lista, [30, 50], ['Maipú, Puente Alto', null]);
    ok('5. con dos comunas preferidas también llega al cupo',
       grupos[0].length === 30, grupos.map(g => g.length).join(' / '));
    ok('5b. y prioriza las dos comunas que le tocan',
       grupos[0].filter(p => ['Maipú', 'Puente Alto'].includes(p.comuna)).length === 20,
       String(grupos[0].filter(p => ['Maipú', 'Puente Alto'].includes(p.comuna)).length));
  }

  // ---------- 6. piden más de lo que hay ----------
  {
    const lista = hacerPedidos(50);
    const { grupos, fuera } = window.__sectores(lista, [40, 40], [null, null]);
    ok('6. si piden 80 y hay 50, se reparten los 50 sin inventar',
       cuenta(grupos) === 50 && fuera.length === 0, cuenta(grupos) + ' / fuera ' + fuera.length);
    ok('6b. ninguno repetido', sinRepetir(grupos));
  }

  // ---------- 7. piden menos de lo que hay ----------
  {
    const lista = hacerPedidos(100);
    const { grupos, fuera } = window.__sectores(lista, [20, 20], [null, null]);
    ok('7. si piden 40 de 100, asigna exactamente 40',
       cuenta(grupos) === 40, String(cuenta(grupos)));
    ok('7b. y los 60 restantes quedan marcados como fuera',
       fuera.length === 60, String(fuera.length));
  }

  // ---------- 8. TODOS sin coordenadas (base sin geocodificar) ----------
  {
    const lista = hacerPedidos(60, 100);
    const { grupos } = window.__sectores(lista, [20, 20, 20], [null, null, null]);
    ok('8. sin ninguna coordenada, igual reparte 20 / 20 / 20',
       grupos.every(g => g.length === 20), grupos.map(g => g.length).join(' / '));
  }

  // ---------- 8b. todos sin coordenadas y cupos que no alcanzan ----------
  {
    const lista = hacerPedidos(100, 100);
    const { grupos, fuera } = window.__sectores(lista, [20, 20], [null, null]);
    ok('8b. sin coordenadas y cupos cortos, NO se pasa del cupo',
       grupos.every((g, j) => g.length <= [20, 20][j]), grupos.map(g => g.length).join(' / '));
    ok('8c. y los que sobran quedan como fuera, no metidos a la fuerza',
       fuera.length === 60, String(fuera.length));
  }

  // ---------- 9. un solo repartidor se lleva todo ----------
  {
    const lista = hacerPedidos(120, 40);
    const { grupos } = window.__sectores(lista, [120], [null]);
    ok('9. un solo repartidor con cupo 120 se lleva los 120',
       grupos[0].length === 120, String(grupos[0].length));
  }

  // ---------- 10. la cuenta de los cupos ----------
  {
    ok('10. tres en "auto" con 258 pedidos → 86 / 86 / 86',
       JSON.stringify(window.__cupos([null, null, null], 258).cupos) === '[86,86,86]',
       JSON.stringify(window.__cupos([null, null, null], 258).cupos));
    ok('10b. 100 pedidos entre 3 → 34 / 33 / 33, sin perder ninguno',
       window.__cupos([null, null, null], 100).cupos.reduce((a, b) => a + b, 0) === 100,
       JSON.stringify(window.__cupos([null, null, null], 100).cupos));
    ok('10c. uno fijo en 50 y dos en auto sobre 258 → 50 / 104 / 104',
       JSON.stringify(window.__cupos([50, null, null], 258).cupos) === '[50,104,104]',
       JSON.stringify(window.__cupos([50, null, null], 258).cupos));
    ok('10d. si los fijos suman más que los pedidos, avisa',
       window.__cupos([200, 200], 258).error != null,
       String(window.__cupos([200, 200], 258).error));
    ok('10e. todos fijos y sobran pedidos: lo dice',
       window.__cupos([50, 50], 258).sobrante === 158,
       String(window.__cupos([50, 50], 258).sobrante));
  }

  // ---------- 11. el orden de la ruta ----------
  {
    const lista = hacerPedidos(20);
    const orden = window.__orden(lista);
    ok('11. ordena la ruta sin perder ni repetir pedidos',
       orden.length === 20 && new Set(orden.map(p => p.id)).size === 20,
       String(orden.length));
  }

  // ============================================================
  // 12. DE PUNTA A PUNTA: apretar el botón y contar lo que se escribió
  // ============================================================
  window.__escritos = [];
  window.__orden = [];
  window.__rechazar = new Set();     // ids que la base "no deja" escribir
  eval(`
    perfiles = window.__perfiles;
    HAY_POOL = false;
    sb.from = () => ({
      update: (v) => {
        const o = {
          in: (col, ids) => { o.__ids = ids; return o; },
          eq: (col, id)  => { if ('ruta_orden' in v) window.__orden.push({id, n:v.ruta_orden});
                              o.__ids = [id]; return o; },
          not: () => o,
          select: () => o,
          then: (f) => {
            const ids = (o.__ids || []).filter(id => !window.__rechazar.has(id));
            if ('repartidor_id' in v) window.__escritos.push(...ids.map(id => ({id, rep: v.repartidor_id})));
            return Promise.resolve({ data: ids.map(id => ({id})), error: null }).then(f);
          },
        };
        return o;
      },
    });
    sb.rpc = async (n, a) => { window.__rpcs = window.__rpcs || []; window.__rpcs.push(n);
                               return { data:{planificados:(a&&a.p_ids||[]).length}, error:null }; };
    window.__abrir = abrirAutoRepartir;
    window.__go    = () => document.getElementById('autoGo').onclick();
  `);
  window.__perfiles = [
    { id: 'r1', nombre: 'Juan',  rol: 'repartidor', activo: true },
    { id: 'r2', nombre: 'Pedro', rol: 'repartidor', activo: true },
  ];
  eval('perfiles = window.__perfiles;');
  window.cargarTodo = async () => {};
  window.toast = m => { window.__ultimoToast = m; };
  window.confirm = () => true;
  const HOY = new Date().toLocaleDateString('en-CA');   // no escribir la fecha a mano:
  window.hoyStr = () => HOY;                           // el test se rompía al pasar la medianoche

  const correrBoton = async (lista, cuposEscritos) => {
    window.__escritos = []; window.__orden = []; window.__firmes = [];
    eval('pedidos = window.__lista; seleccion.clear();');
    window.__abrir();
    const cbs = [...document.querySelectorAll('#autoReps input[type="checkbox"]')];

    cbs.forEach(c => c.checked = true);
    cuposEscritos.forEach((v, i) => {
      const id = cbs[i].value;
      document.querySelector(`#autoReps input[data-cupo="${id}"]`).value = v ?? '';
    });
    await window.__go();
    window.__errUI = document.getElementById('autoErr').textContent;
  };

  {
    const lista = hacerPedidos(258, 45).map(p => ({...p, fecha_pedido:HOY}));
    window.__lista = lista;
    await correrBoton(lista, [80, 80]);
    ok('12. pido 80 y 80: se escriben exactamente 160 asignaciones',
       window.__escritos.length === 160,
       window.__escritos.length + ' · UI dice: ' + window.__errUI);
    const porRep = window.__escritos.reduce((m, e) => (m[e.rep] = (m[e.rep]||0)+1, m), {});
    ok('12b. y son 80 para cada uno, no menos',
       porRep.r1 === 80 && porRep.r2 === 80, JSON.stringify(porRep));
    ok('12c. ningún pedido se asigna a los dos',
       new Set(window.__escritos.map(e => e.id)).size === 160,
       String(new Set(window.__escritos.map(e => e.id)).size));
    ok('12d. y a cada uno se le guarda el orden de ruta',
       window.__orden.length === 160, String(window.__orden.length));
    ok('12e. avisa que quedaron 98 sin asignar',
       /98 quedaron sin asignar/.test(window.__ultimoToast || ''), window.__ultimoToast);
  }

  // ---------- el aviso de las comunas de preferencia ----------
  {
    const lista = hacerPedidos(20, 0).map(p => ({...p, fecha_pedido:HOY}));
    window.__lista = lista;
    eval('pedidos = window.__lista; seleccion.clear();');
    window.__perfiles.forEach(p => { delete p.comuna_preferida; });
    window.__abrir();
    ok('12f. si nadie tiene comunas de preferencia, el panel lo dice',
       /Ninguno tiene comunas de preferencia/.test(
         document.getElementById('autoPref').textContent),
       document.getElementById('autoPref').textContent.slice(0, 80));
    ok('12g. y explica dónde ponerlas',
       /Repartidores/.test(document.getElementById('autoPref').innerHTML));
    window.__perfiles[0].comuna_preferida = 'Maipú, Cerrillos';
    window.__abrir();
    ok('12h. y si alguno las tiene, dice cuántos son',
       /1 de 2/.test(document.getElementById('autoPref').textContent),
       document.getElementById('autoPref').textContent.slice(0, 80));
    delete window.__perfiles[0].comuna_preferida;
  }

  {
    const lista = hacerPedidos(120, 30).map(p => ({...p, fecha_pedido:HOY}));
    window.__lista = lista;
    await correrBoton(lista, [null, null]);
    ok('13. en "auto" se reparten los 120 completos',
       window.__escritos.length === 120, String(window.__escritos.length));
    const porRep = window.__escritos.reduce((m, e) => (m[e.rep] = (m[e.rep]||0)+1, m), {});
    ok('13b. y quedan parejos: 60 y 60', porRep.r1 === 60 && porRep.r2 === 60,
       JSON.stringify(porRep));
  }

  {
    // la base rechaza 12 pedidos (otro los tomó mientras tanto)
    const lista = hacerPedidos(100, 0).map(p => ({...p, fecha_pedido:HOY}));
    window.__lista = lista;
    window.__rechazar = new Set(lista.slice(0, 12).map(p => p.id));
    await correrBoton(lista, [50, 50]);
    window.__rechazar = new Set();
    ok('14. si la base rechaza algunos, el resumen NO miente',
       window.__escritos.length === 88, String(window.__escritos.length));
    ok('14b. y el aviso dice cuántos no se pudieron asignar',
       /12 no se pudieron asignar/.test(window.__ultimoToast || ''), window.__ultimoToast);
  }

  // ============================================================
  // 15. EL CASO REAL DE HOY: TODO COMPARTIDO
  //     La red está instalada y el cliente está en modo «abierto», así que
  //     ningún pedido es de la empresa todavía. Desde v1.51 asignar un
  //     compartido lo TOMA: deja de estar en tierra de nadie.
  // ============================================================
  window.__planes = []; window.__firmes = [];
  eval(`
    HAY_POOL = true; miEmpresa = 1;
    sb.rpc = async (n, a) => {
      window.__rpcs = window.__rpcs || []; window.__rpcs.push({n, a});
      const ids = (a && a.p_ids) || [];
      const malos  = ids.filter(id =>  window.__malos && window.__malos.has(id));
      const buenos = ids.filter(id => !(window.__malos && window.__malos.has(id)));
      const rechazados = malos.map(id => ({id, motivo:'fuera de la zona de reparto'}));
      if (n === 'tomar_y_asignar') {
        if (window.__sinMigracion)
          return { data:null, error:{message:'Could not find the function public.tomar_y_asignar'} };
        buenos.forEach((id, i) => window.__firmes.push({pedido_id:id, orden:i+1, rep:a.p_repartidor}));
        return { data:{ asignados: buenos.length, ids: buenos, rechazados }, error:null };
      }
      if (window.__sinMigracion)
        return { data:null, error:{message:'Could not find the function public.planificar_pedidos'} };
      buenos.forEach((id, i) => window.__planes.push({pedido_id:id, orden:i+1, rep:a.p_repartidor}));
      return { data:{ planificados: buenos.length, rechazados }, error:null };
    };
  `);

  {
    const lista = hacerPedidos(120, 20).map(p => ({...p,
      fecha_pedido:HOY, empresa_reparto_id:null}));
    window.__lista = lista;
    window.__planes = []; window.__firmes = []; window.__rpcs = [];
    await correrBoton(lista, [60, 60]);
    ok('15. los 120 compartidos pasan a ser de la empresa', window.__firmes.length === 120,
       String(window.__firmes.length));
    ok('15b. ninguno queda en el limbo del «previsto»', window.__planes.length === 0,
       String(window.__planes.length));
    ok('15c. 60 para cada repartidor',
       new Set(window.__firmes.map(p => p.rep)).size === 2 &&
       window.__firmes.filter(p => p.rep === window.__firmes[0].rep).length === 60,
       JSON.stringify(window.__firmes.reduce((m,p)=>(m[p.rep]=(m[p.rep]||0)+1,m),{})));
    ok('15d. el aviso ya no habla de previstos',
       !/previstos/.test(window.__ultimoToast || ''), window.__ultimoToast);
  }

  // ---------- 16. el orden de ruta vuelve a la tabla de pedidos ----------
  {
    const lista = hacerPedidos(20, 0).map(p => ({...p,
      fecha_pedido:HOY, empresa_reparto_id:null}));
    window.__lista = lista;
    window.__planes = []; window.__firmes = [];
    await correrBoton(lista, [20]);
    ok('16. la base recibe el orden de ruta al asignar, del 1 al 20',
       window.__firmes.map(p => p.orden).join(',') ===
         Array.from({length:20}, (_, i) => i + 1).join(','),
       window.__firmes.map(p => p.orden).join(','));
    ok('16b. y además queda escrito en `pedidos.ruta_orden`',
       window.__orden.length === 20, String(window.__orden.length));
    ok('16c. ese orden es el de la ruta, no el de la tabla',
       window.__firmes.map(p => p.pedido_id).join(',') !==
         lista.map(p => p.id).join(','),
       window.__firmes.map(p => p.pedido_id).slice(0, 6).join(','));
  }

  // ---------- 17. mezcla: unos ya míos y otros compartidos ----------
  {
    const lista = hacerPedidos(40, 0).map((p, i) => ({...p,
      fecha_pedido:HOY, empresa_reparto_id: i < 20 ? 1 : null}));
    window.__lista = lista;
    window.__planes = []; window.__firmes = []; window.__escritos = []; window.__orden = [];
    await correrBoton(lista, [40]);
    ok('17. los que ya eran míos se asignan derecho', window.__escritos.length === 20,
       String(window.__escritos.length));
    ok('17b. y los compartidos pasan a serlo en el acto', window.__firmes.length === 20,
       String(window.__firmes.length));
    ok('17c. el orden de ruta se escribe para los 40, no para la mitad',
       window.__orden.length === 40, String(window.__orden.length));
  }

  // ---------- 18. la base rechaza algunos: se explica el motivo ----------
  {
    const lista = hacerPedidos(30, 0).map(p => ({...p,
      fecha_pedido:HOY, empresa_reparto_id:null}));
    window.__lista = lista;
    window.__malos = new Set(lista.slice(0, 7).map(p => p.id));
    window.__planes = []; window.__firmes = [];
    await correrBoton(lista, [30]);
    window.__malos = null;
    ok('18. avisa cuántos no entraron', /7 no se pudieron asignar/.test(window.__ultimoToast || ''),
       window.__ultimoToast);
    ok('18b. y por qué', /fuera de la zona de reparto/.test(window.__ultimoToast || ''),
       window.__ultimoToast);
  }

  // ---------- 19. sin la migración corrida ----------
  {
    const lista = hacerPedidos(10, 0).map(p => ({...p,
      fecha_pedido:HOY, empresa_reparto_id:null}));
    window.__lista = lista;
    window.__sinMigracion = true;
    window.__planes = []; window.__firmes = [];
    await correrBoton(lista, [10]);
    window.__sinMigracion = false;
    ok('19. si falta el SQL lo dice claro, no falla en silencio',
       /migracion-plan-y-carga/.test(window.__errUI || ''), window.__errUI);
    ok('19b. y sin la función nueva no se pierde nada: cae en el camino viejo',
       window.__rpcs.some(x => x.n === 'tomar_y_asignar'),
       JSON.stringify((window.__rpcs||[]).map(x => x.n).slice(-4)));
  }

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
