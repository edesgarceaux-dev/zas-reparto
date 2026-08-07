/* ============================================================
   EL MAPA CON PEDIDOS COMPARTIDOS

   El caso que se rompía: le asignás 929 pedidos compartidos a un
   repartidor y el mapa decía «0 activos» y no dibujaba nada.
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
  // la fecha se calcula: escrita a mano, el test se rompe al pasar la medianoche
  const HOY = new Date().toLocaleDateString('en-CA');
  const $ = id => document.getElementById(id);

  // 6 compartidos previstos para Hans, 2 propios de Martín, 2 sin nadie
  const PED = [];
  for (let i = 1; i <= 6; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Compartido ' + i,
    direccion: 'Calle ' + i, comuna: 'La Florida', cliente_id: 1,
    estado: 'pendiente', empresa_reparto_id: null, repartidor_id: null,
    ruta_orden: null, lat: -33.55 + i * .01, lng: -70.58 + i * .01,
    fecha_pedido: HOY, creado_en: '2026-08-04T10:00:00Z',
  });
  for (let i = 7; i <= 8; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Propio ' + i,
    direccion: 'Calle ' + i, comuna: 'Maipú', cliente_id: 1,
    estado: 'asignado', empresa_reparto_id: 1, repartidor_id: 'r2',
    ruta_orden: i - 6, lat: -33.51 + i * .01, lng: -70.76 + i * .01,
    fecha_pedido: HOY, creado_en: '2026-08-04T10:00:00Z',
  });
  for (let i = 9; i <= 10; i++) PED.push({
    id: i, codigo: 'ZAS-' + i, cliente_nombre: 'Sin nadie ' + i,
    direccion: 'Calle ' + i, comuna: 'Ñuñoa', cliente_id: 1,
    estado: 'pendiente', empresa_reparto_id: null, repartidor_id: null,
    ruta_orden: null, lat: -33.45, lng: -70.60,
    fecha_pedido: HOY, creado_en: '2026-08-04T10:00:00Z',
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
  window.hoyDia = () => HOY;

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

  // ============================================================
  // 8. LA VENTANA DEL MAPA: hoy + lo de ayer después de las 12:00
  // ============================================================
  const iso = d => d.toLocaleDateString('en-CA');
  const AYER = (() => { const d = new Date(); d.setDate(d.getDate()-1); return iso(d); })();
  const ANTEAYER = (() => { const d = new Date(); d.setDate(d.getDate()-2); return iso(d); })();
  const ayerAlas = h => { const d = new Date(); d.setDate(d.getDate()-1);
                          d.setHours(Math.floor(h), Math.round((h % 1) * 60), 0, 0);
                          return d.toISOString(); };

  const nuevo = (id, extra) => ({
    id, codigo:'ZAS-'+id, cliente_nombre:'P'+id, direccion:'Calle '+id,
    comuna:'Maipú', cliente_id:1, estado:'pendiente',
    empresa_reparto_id:1, repartidor_id:null, ruta_orden:null,
    lat:-33.5, lng:-70.7, ...extra });

  window.__P2 = [
    nuevo(101, { fecha_pedido: HOY,       creado_en: new Date().toISOString() }),
    nuevo(102, { fecha_pedido: AYER,      creado_en: ayerAlas(18) }),  // ayer 18:00 → entra
    nuevo(103, { fecha_pedido: AYER,      creado_en: ayerAlas(12) }),  // justo a las 12 → entra
    nuevo(104, { fecha_pedido: AYER,      creado_en: ayerAlas(9)  }),  // ayer 9:00 → atrasado
    nuevo(105, { fecha_pedido: ANTEAYER,  creado_en: ayerAlas(20) }),  // anteayer → atrasado
    nuevo(106, { fecha_pedido: null,      creado_en: new Date().toISOString() }), // sin fecha
    // uno de ayer temprano PERO ya asignado: no cuenta como atrasado
    nuevo(107, { fecha_pedido: AYER, creado_en: ayerAlas(8), repartidor_id:'r2', estado:'asignado' }),
  ];
  eval('pedidos = window.__P2; misPlanes = [];');
  eval('window.__mapa = sinAsignarDelMapa; window.__atras = sinAsignarAtrasados;');
  window.__poblar();

  const enMapa = window.__mapa().map(p=>p.id).sort();
  ok('8. el de hoy entra al mapa', enMapa.includes(101), enMapa.join(','));
  ok('8b. el de ayer a las 18:00 también', enMapa.includes(102), enMapa.join(','));
  ok('8c. y el de ayer justo a las 12:00', enMapa.includes(103), enMapa.join(','));
  ok('8d. el de ayer a las 9 de la mañana NO', !enMapa.includes(104), enMapa.join(','));
  ok('8e. el de anteayer tampoco', !enMapa.includes(105), enMapa.join(','));
  ok('8f. y uno sin fecha de despacho no se cuela', !enMapa.includes(106), enMapa.join(','));

  const atras = window.__atras().map(p=>p.id).sort();
  ok('9. los que quedaron afuera se cuentan como atrasados',
     atras.join(',') === '104,105,106', atras.join(','));
  ok('9b. un pedido de ayer temprano YA asignado no figura como atrasado',
     !atras.includes(107), atras.join(','));

  ok('10. el conteo del desplegable dice lo mismo que el mapa',
     /Sin asignar \(3\)/.test([...$('rutaRep').options][0].textContent),
     [...$('rutaRep').options][0].textContent);

  ok('11. aparece el cartel de los atrasados',
     $('mapaAtrasados').style.display === 'flex', $('mapaAtrasados').style.display);
  ok('11b. y dice cuántos son y de cuándo es el más viejo',
     /3 pedidos sin asignar quedaron atrasados/.test($('mapaAtrasadosTxt').textContent) &&
     $('mapaAtrasadosTxt').textContent.includes(ANTEAYER),
     $('mapaAtrasadosTxt').textContent);

  eval('pedidos = window.__P2.filter(p=>p.id===101);');
  window.__poblar();
  ok('11c. sin atrasados, el cartel no aparece',
     $('mapaAtrasados').style.display === 'none', $('mapaAtrasados').style.display);

  // ============================================================
  // 12. CADA CLIENTE CON SU HORA DE CORTE
  //     Pepito corta a las 12:00, Ferretería a las 11:00, y un tercero
  //     no tiene hora cargada (se asume el mediodía).
  // ============================================================
  eval(`clientes = [
    { id:1, nombre:'DISTRIBUIDORA PEPITO', hora_corte:'12:00:00' },
    { id:2, nombre:'FERRETERÍA SUR',       hora_corte:'11:00:00' },
    { id:3, nombre:'SIN CORTE',            hora_corte:null },
  ];`);
  eval('window.__corte = horaCorteDe;');

  ok('12. lee la hora de corte de cada cliente',
     window.__corte(1).h === 12 && window.__corte(2).h === 11,
     JSON.stringify([window.__corte(1), window.__corte(2)]));
  ok('12b. sin hora cargada asume el mediodía, no la medianoche',
     window.__corte(3).h === 12 && window.__corte(3).m === 0,
     JSON.stringify(window.__corte(3)));
  ok('12c. y un cliente que ni existe tampoco rompe',
     window.__corte(999).h === 12, JSON.stringify(window.__corte(999)));

  window.__P3 = [
    // un pedido de ayer a las 11:30 para cada cliente
    nuevo(201, { cliente_id:1, fecha_pedido:AYER, creado_en: ayerAlas(11.5) }),
    nuevo(202, { cliente_id:2, fecha_pedido:AYER, creado_en: ayerAlas(11.5) }),
    nuevo(203, { cliente_id:3, fecha_pedido:AYER, creado_en: ayerAlas(11.5) }),
  ];
  eval('pedidos = window.__P3;');
  const m3 = window.__mapa().map(p=>p.id);
  ok('13. a las 11:30, el de Pepito (corta 12:00) queda atrasado',
     !m3.includes(201), m3.join(','));
  ok('13b. el de Ferretería (corta 11:00) SÍ entra al mapa',
     m3.includes(202), m3.join(','));
  ok('13c. y el del cliente sin corte se trata como mediodía: atrasado',
     !m3.includes(203), m3.join(','));

  // media hora antes del corte de Ferretería: ninguno entra
  window.__P3 = [
    nuevo(204, { cliente_id:1, fecha_pedido:AYER, creado_en: ayerAlas(10.5) }),
    nuevo(205, { cliente_id:2, fecha_pedido:AYER, creado_en: ayerAlas(10.5) }),
  ];
  eval('pedidos = window.__P3;');
  ok('14. a las 10:30 no entra ninguno de los dos',
     window.__mapa().length === 0, window.__mapa().map(p=>p.id).join(','));

  // pasadas las 12 entran los dos
  window.__P3 = [
    nuevo(206, { cliente_id:1, fecha_pedido:AYER, creado_en: ayerAlas(13) }),
    nuevo(207, { cliente_id:2, fecha_pedido:AYER, creado_en: ayerAlas(13) }),
  ];
  eval('pedidos = window.__P3;');
  ok('14b. y pasadas las 13:00 entran los dos',
     window.__mapa().length === 2, window.__mapa().map(p=>p.id).join(','));

  // el cartel nombra las horas de corte que están en juego
  window.__P3 = [
    nuevo(208, { cliente_id:1, fecha_pedido:AYER, creado_en: ayerAlas(9) }),
    nuevo(209, { cliente_id:2, fecha_pedido:AYER, creado_en: ayerAlas(9) }),
  ];
  eval('pedidos = window.__P3;');
  window.__poblar();
  ok('15. el cartel dice qué horas de corte se aplicaron',
     /11:00/.test($('mapaAtrasadosTxt').textContent) &&
     /12:00/.test($('mapaAtrasadosTxt').textContent),
     $('mapaAtrasadosTxt').textContent.slice(-120));
  ok('15b. y dónde se cambian', /Clientes/.test($('mapaAtrasadosTxt').textContent));

  eval('pedidos = window.__P; misPlanes = window.__PL; clientes = [{id:1,nombre:"DISTRIBUIDORA PEPITO",lat:-33.45,lng:-70.66}];');

  // ============================================================
  // 16. LOS BULTOS YA ESCANEADOS TIENEN QUE SEGUIR EN EL MAPA
  //     Al escanear, el pedido se va a «Mi carga» (poolPedidos) y sale
  //     de `pedidos`. El mapa igual los tiene que ver.
  // ============================================================
  eval(`
    clientes = [{id:1,nombre:'DISTRIBUIDORA PEPITO',hora_corte:'12:00:00',lat:-33.45,lng:-70.66}];
    pedidos = [
      { id:301, codigo:'ZAS-301', cliente_nombre:'Sin cargar', direccion:'C 1', comuna:'Maipú',
        cliente_id:1, estado:'asignado', empresa_reparto_id:1, repartidor_id:'r1',
        ruta_orden:2, lat:-33.51, lng:-70.75, fecha_pedido:window.__HOY, cargado_en:null },
    ];
    poolPedidos = [
      { id:302, codigo:'ZAS-302', cliente_nombre:'Ya escaneado', direccion:'C 2', comuna:'Maipú',
        cliente_id:1, estado:'asignado', empresa_reparto_id:1, repartidor_id:'r1',
        ruta_orden:1, lat:-33.52, lng:-70.76, fecha_pedido:window.__HOY,
        cargado_en:'2026-08-05T10:00:00Z' },
      { id:303, codigo:'ZAS-303', cliente_nombre:'Cargado sin dueño', direccion:'C 3', comuna:'Ñuñoa',
        cliente_id:1, estado:'pendiente', empresa_reparto_id:1, repartidor_id:null,
        ruta_orden:null, lat:-33.45, lng:-70.60, fecha_pedido:window.__HOY,
        cargado_en:'2026-08-05T10:05:00Z' },
    ];
    misPlanes = [];
  `);
  window.__HOY = HOY;
  window.__setProp(null);          // limpiar la propuesta que quedó de la prueba 7
  eval(`pedidos[0].fecha_pedido = window.__HOY;
        poolPedidos[0].fecha_pedido = window.__HOY;
        poolPedidos[1].fecha_pedido = window.__HOY;`);
  window.__poblar();

  ok('16. el repartidor cuenta también los bultos ya escaneados',
     /Hans Stuardo — 2 activos/.test([...$('rutaRep').options].map(o=>o.textContent).join(' | ')),
     [...$('rutaRep').options].map(o=>o.textContent).join(' | '));

  $('rutaRep').value = 'r1';
  const ruta16 = window.__deRuta().map(p=>p.id).sort();
  ok('16b. y su ruta trae el escaneado y el que falta escanear',
     ruta16.join(',') === '301,302', ruta16.join(','));

  const ord16 = window.__ordenar(window.__deRuta()).map(p=>p.id);
  ok('16c. en el orden guardado (el escaneado va primero)',
     ord16.join(',') === '302,301', ord16.join(','));

  $('rutaRep').value = '';
  ok('16d. un bulto cargado sin repartidor sale en «Sin asignar»',
     window.__mapa().map(p=>p.id).join(',') === '303',
     window.__mapa().map(p=>p.id).join(','));

  eval('pedidos = window.__P; poolPedidos = []; misPlanes = window.__PL; clientes = [{id:1,nombre:"DISTRIBUIDORA PEPITO",lat:-33.45,lng:-70.66}];');

  // ---------- 17. sin la red instalada, todo como antes ----------
  eval('HAY_POOL = false;');
  window.__poblar();
  const ops2 = [...$('rutaRep').options].map(o => o.textContent);
  ok('17. sin la red, el mapa cuenta solo por repartidor_id',
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
