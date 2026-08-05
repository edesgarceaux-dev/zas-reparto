/* ============================================================
   LA TABLA DE PEDIDOS: qué número se muestra y cómo se filtra
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
      !/ERR_CONNECTION|ERR_FILE_NOT_FOUND|ERR_NAME_NOT_RESOLVED|Failed to load resource/.test(m.text()))
    errores.push('console: ' + m.text());
});
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra = '') => out.push({ n, ok: !!cond, extra });
  // la fecha se calcula: escrita a mano, el test se rompe al pasar la medianoche
  const HOY = new Date().toLocaleDateString('en-CA');
  const $ = id => document.getElementById(id);

  const PEDIDOS = [
    // MercadoLibre Flex con n° de envío: es el que va en la etiqueta
    { id:1, codigo:'ZAS-03833', externo_id:'ML-2000123', envio_id:'44001122333',
      origen:'mercadolibre', cliente_nombre:'Patricia Morales', direccion:'Estacion carampangue 0735',
      comuna:'Puente Alto', estado:'pendiente', fecha_pedido:HOY, cliente_id:1,
      repartidor_id:null, empresa_reparto_id:1 },
    // MercadoLibre al que todavía le falta el n° de envío
    { id:2, codigo:'ZAS-03834', externo_id:'ML-2000124', envio_id:null,
      origen:'mercadolibre', cliente_nombre:'Rosa Díaz', direccion:'Los Aromos 12',
      comuna:'Maipú', estado:'asignado', fecha_pedido:HOY, cliente_id:1,
      repartidor_id:'r1', empresa_reparto_id:1 },
    // Jumpseller
    { id:3, codigo:'ZAS-03835', externo_id:'82652', envio_id:null,
      origen:'jumpseller', cliente_nombre:'Luis Soto', direccion:'Gran Avenida 900',
      comuna:'La Cisterna', estado:'en_camino', fecha_pedido:HOY, cliente_id:1,
      repartidor_id:'r2', empresa_reparto_id:1 },
    // cargado a mano, sin ningún número de tienda
    { id:4, codigo:'ZAS-03836', externo_id:null, envio_id:null,
      origen:'manual', cliente_nombre:'Ana Rojas', direccion:'Sucre 44',
      comuna:'Ñuñoa', estado:'entregado', fecha_pedido:HOY, cliente_id:1,
      repartidor_id:'r1', empresa_reparto_id:1 },
    // compartido: todavía no es de nadie
    { id:5, codigo:'ZAS-03837', externo_id:'82999', envio_id:null,
      origen:'jumpseller', cliente_nombre:'Mario Pino', direccion:'Vicuña 10',
      comuna:'Recoleta', estado:'pendiente', fecha_pedido:HOY, cliente_id:1,
      repartidor_id:null, empresa_reparto_id:null },
  ];
  const GENTE = [
    { id:'r1', nombre:'Juan Pérez', rol:'repartidor', activo:true },
    { id:'r2', nombre:'Pedro Soto', rol:'repartidor', activo:true },
    { id:'r3', nombre:'Sin nada',   rol:'repartidor', activo:true },
  ];

  window.__ped = PEDIDOS; window.__gente = GENTE;
  eval(`
    pedidos   = window.__ped;
    perfiles  = window.__gente;
    clientes  = [{id:1, nombre:'Distribuidora Pepitos'}];
    misPlanes = [{pedido_id:5, repartidor_id:'r2'}];
    HAY_POOL  = true;
    filtro    = 'todos';
    window.__pintar = pintarPedidos;
    window.__num    = numeroDeEnvio;
    window.__numTxt = numeroDeEnvioTxt;
    window.__setBusq = v => { busq = v; };
  `);
  window.__pintar();
  const tabla = () => $('tbodyPed').innerHTML;
  const filas = () => [...$('tbodyPed').querySelectorAll('tr')]
      .filter(tr => !tr.querySelector('.empty'));

  // ---------- 1. el código interno ya no ocupa columna ----------
  const encabezados = [...document.querySelectorAll('#tblPedidos thead th')]
      .map(t => t.textContent.trim());
  ok('1. la tabla ya no tiene columna "Código"', !encabezados.includes('Código'),
     encabezados.join(' | '));
  ok('1b. y la de envío se llama "N° de envío"', encabezados.includes('N° de envío'),
     encabezados.join(' | '));
  ok('1c. no quedan códigos ZAS sueltos en la tabla', !/ZAS-0383[3-5]/.test(tabla()));

  // ---------- 2. el número que se muestra ----------
  ok('2. MercadoLibre muestra el N° DE ENVÍO, no el de orden',
     /44001122333/.test(window.__num(PEDIDOS[0])) && !/2000123/.test(window.__num(PEDIDOS[0])),
     window.__num(PEDIDOS[0]));
  ok('2b. si a la venta ML le falta el envío, muestra la orden y avisa',
     /2000124/.test(window.__num(PEDIDOS[1])) && /⚠️/.test(window.__num(PEDIDOS[1])),
     window.__num(PEDIDOS[1]));
  ok('2c. y sin el prefijo ML-', !/ML-/.test(window.__num(PEDIDOS[1])),
     window.__num(PEDIDOS[1]));
  ok('2d. Jumpseller muestra el n° de pedido de la tienda',
     /82652/.test(window.__num(PEDIDOS[2])), window.__num(PEDIDOS[2]));
  ok('2e. un pedido a mano cae al código de ZAS',
     /ZAS-03836/.test(window.__num(PEDIDOS[3])), window.__num(PEDIDOS[3]));
  ok('2f. cada origen mantiene su marquita',
     /Ⓜ/.test(window.__num(PEDIDOS[0])) && /⚡/.test(window.__num(PEDIDOS[2])));

  // ---------- 3. el buscador ----------
  window.__setBusq('44001122333'); window.__pintar();
  ok('3. se puede buscar por el n° de envío de ML', filas().length === 1,
     String(filas().length));
  window.__setBusq('ZAS-03835'); window.__pintar();
  ok('3b. y el código interno sigue sirviendo aunque no se muestre',
     filas().length === 1, String(filas().length));
  window.__setBusq('carampangue'); window.__pintar();
  ok('3c. y por dirección', filas().length === 1, String(filas().length));
  window.__setBusq(''); window.__pintar();

  // ---------- 4. la lista de estados ----------
  const ops = [...$('fEstado').options].map(o => o.value);
  ok('4. hay una lista desplegable de estados', ops.length > 1, ops.join(','));
  ok('4b. solo ofrece los estados que hay hoy',
     ops.includes('pendiente') && ops.includes('en_camino') && !ops.includes('cancelado'),
     ops.join(','));
  ok('4c. y ofrece los compartidos aparte', ops.includes('compartido'), ops.join(','));

  eval('fEstado = "en_camino";'); window.__pintar();
  ok('5. filtrar por "en camino" deja un solo pedido', filas().length === 1,
     String(filas().length));
  ok('5b. y es el correcto', /Luis Soto/.test(tabla()));

  eval('fEstado = "compartido";'); window.__pintar();
  ok('5c. filtrar por compartidos deja el que no es de nadie',
     filas().length === 1 && /Mario Pino/.test(tabla()), String(filas().length));
  eval('fEstado = "pendiente";'); window.__pintar();
  ok('5d. "pendiente" NO se lleva a los compartidos por delante',
     filas().length === 1 && /Patricia Morales/.test(tabla()), String(filas().length));
  eval('fEstado = "";');

  // ---------- 6. la lista de repartidores ----------
  const opsR = [...$('fRep').options].map(o => o.value);
  ok('6. hay una lista desplegable de repartidores',
     opsR.includes('r1') && opsR.includes('r2'), opsR.join(','));
  ok('6b. con la opción de ver los que no tienen a nadie', opsR.includes('sin'));
  ok('6c. y dice cuántos lleva cada uno',
     /Juan Pérez \(2\)/.test($('fRep').innerHTML), $('fRep').innerHTML.replace(/<[^>]*>/g, ' '));

  eval('fRep = "r1";'); window.__pintar();
  ok('7. filtrar por Juan deja sus 2 pedidos', filas().length === 2, String(filas().length));
  eval('fRep = "r2";'); window.__pintar();
  ok('7b. Pedro tiene el suyo y el compartido que le planificaron',
     filas().length === 2, String(filas().length));
  eval('fRep = "r3";'); window.__pintar();
  ok('7c. el que no tiene nada muestra la tabla vacía', filas().length === 0,
     String(filas().length));
  eval('fRep = "sin";'); window.__pintar();
  ok('7d. "sin repartidor" deja solo el que no tiene a nadie',
     filas().length === 1 && /Patricia Morales/.test(tabla()), String(filas().length));

  // ---------- 8. los filtros se combinan ----------
  eval('fRep = "r1"; fEstado = "entregado";'); window.__pintar();
  ok('8. estado y repartidor se combinan',
     filas().length === 1 && /Ana Rojas/.test(tabla()), String(filas().length));
  window.__setBusq('nadie asi'); window.__pintar();
  ok('8b. y el buscador se suma a los dos', filas().length === 0, String(filas().length));
  window.__setBusq('');

  // ---------- 9. limpiar ----------
  window.__pintar();
  ok('9. con filtros puestos aparece el botón de limpiar',
     $('fLimpiar').style.display !== 'none', $('fLimpiar').style.display);
  ok('9b. y los desplegables se resaltan',
     $('fRep').style.fontWeight === '700' && $('fEstado').style.fontWeight === '700');
  window.limpiarFiltros();
  ok('9c. limpiar devuelve los 5 pedidos', filas().length === 5, String(filas().length));
  ok('9d. y esconde el botón', $('fLimpiar').style.display === 'none');
  ok('9e. y apaga el resaltado', $('fRep').style.fontWeight === '');

  // ---------- 10. sin la red de empresas instalada ----------
  eval('HAY_POOL = false;'); window.__pintar();
  ok('10. sin la migración de la red, nada figura como compartido',
     !/compartido/.test(tabla()));
  ok('10b. y el filtro de estados no ofrece "compartido"',
     ![...$('fEstado').options].map(o => o.value).includes('compartido'));
  eval('HAY_POOL = true;');

  // ============================================================
  // 11. QUITAR LA ASIGNACIÓN TAMBIÉN SACA EL «PREVISTO»
  // ============================================================
  window.__rpcs = []; window.__upd = [];
  eval(`
    misPlanes = [{pedido_id:5, repartidor_id:'r2'}];
    sb.from = () => ({
      update: (v) => { const o = {
        in: (c,ids)=>{ o.__ids=ids; return o; }, eq:(c,id)=>{ o.__ids=[id]; return o; },
        not: ()=>o, select: ()=>o,
        then: (f)=>{ window.__upd.push({v, ids:o.__ids||[]});
                     return Promise.resolve({data:(o.__ids||[]).map(id=>({id})), error:null}).then(f); } };
        return o; },
    });
    sb.rpc = async (n, a) => { window.__rpcs.push({n, a});
                               return { data:{sacados:(a&&a.p_ids||[]).length}, error:null }; };
    seleccion.clear(); seleccion.add(5);
    window.__quitarMasivo = () => document.getElementById('masivaDesasignar').onclick();
    window.__desasignar   = desasignar;
    window.__planes = () => misPlanes.length;
  `);
  window.cargarTodo = async () => {};
  window.toast = m => { window.__ultimoToast = m; };

  eval('fEstado=""; fRep=""; busq="";');
  window.__pintar();
  ok('11. antes de tocar nada, el compartido sale como previsto',
     /previsto/.test(tabla()));

  await window.__quitarMasivo();
  ok('11b. quitar la asignación a un compartido llama a desplanificar_pedidos',
     window.__rpcs.some(x => x.n === 'desplanificar_pedidos' && x.a.p_ids[0] === 5),
     JSON.stringify(window.__rpcs));
  ok('11c. y NO intenta escribir el repartidor en la tabla de pedidos',
     !window.__upd.some(u => (u.ids||[]).includes(5)),
     JSON.stringify(window.__upd));
  ok('11d. el plan se borra al toque, sin esperar la recarga',
     window.__planes() === 0, String(window.__planes()));
  window.__pintar();
  ok('11e. y el «previsto» desaparece de la tabla', !/previsto/.test(tabla()));
  ok('11f. el aviso lo dice con todas las letras',
     /previstos|previsto/.test(window.__ultimoToast || ''), window.__ultimoToast);

  // un pedido normal, que sí vive en la tabla pedidos
  window.__rpcs = []; window.__upd = [];
  eval('seleccion.clear(); seleccion.add(2);');
  await window.__quitarMasivo();
  ok('12. en un pedido propio sí se limpia la tabla de pedidos',
     window.__upd.some(u => (u.ids||[]).includes(2) && u.v.repartidor_id === null),
     JSON.stringify(window.__upd));
  ok('12b. y no se llama a desplanificar de gusto',
     !window.__rpcs.some(x => x.n === 'desplanificar_pedidos'),
     JSON.stringify(window.__rpcs));

  // desde la ficha del pedido, de a uno
  eval('misPlanes = [{pedido_id:5, repartidor_id:"r2"}];');
  window.__rpcs = [];
  await window.__desasignar(5);
  ok('13. desde la ficha del pedido pasa lo mismo',
     window.__rpcs.some(x => x.n === 'desplanificar_pedidos') && window.__planes() === 0,
     JSON.stringify(window.__rpcs));

  // ============================================================
  // 14. «MI CARGA»: un bulto cargado se tiene que poder mover
  // ============================================================
  window.__rpcs = []; window.__upd = [];
  eval(`
    poolPedidos = [
      { id:77, codigo:'ZAS-04000', envio_id:'47677019895', origen:'mercadolibre',
        cliente_nombre:'Constanza Vidal', direccion:'Aldunate 1064', comuna:'Santiago',
        estado:'asignado', cliente_id:1, empresa_reparto_id:1, repartidor_id:'r1',
        cargado_en:'2026-08-04T11:31:00Z', fecha_pedido:HOY },
      { id:78, codigo:'ZAS-04001', envio_id:'47677019896', origen:'mercadolibre',
        cliente_nombre:'Otro Cliente', direccion:'Bandera 55', comuna:'Santiago',
        estado:'asignado', cliente_id:1, empresa_reparto_id:1, repartidor_id:'r1',
        cargado_en:'2026-08-04T11:32:00Z', fecha_pedido:HOY },
    ];
    poolSel = new Set();
    window.__pintarPool = pintarPool;
    window.__porId = pedidoPorId;
    window.__verDetalle = verDetalle;
    window.__asignarPool = () => document.getElementById('poolAsignar').onclick();
    window.__quitarPool  = () => document.getElementById('poolDesasignar').onclick();
  `);
  window.__pintarPool();

  ok('14. un bulto de Mi carga se encuentra por su id',
     window.__porId(77) != null && window.__porId(77).cliente_nombre === 'Constanza Vidal');
  ok('14b. y los de Pedidos se siguen encontrando igual',
     window.__porId(1) != null && window.__porId(1).cliente_nombre === 'Patricia Morales');
  ok('14c. un id que no existe da null', window.__porId(999) === null);

  // la ficha se tiene que poder abrir: era lo que no pasaba
  eval(`sb.from = (t) => ({
    select: () => ({ eq: () => ({ order: () => Promise.resolve({data:[]}) }) }),
    update: (v) => { const o = { in:(c,ids)=>{o.__ids=ids;return o;}, eq:(c,id)=>{o.__ids=[id];return o;},
      not:()=>o, select:()=>o,
      then:(f)=>{ window.__upd.push({v, ids:o.__ids||[]});
        return Promise.resolve({data:(o.__ids||[]).map(id=>({id})),error:null}).then(f); } }; return o; },
  });`);
  $('mDetBody').innerHTML = '';
  await window.__verDetalle(77);
  ok('14d. hacer clic en la fila SÍ abre la ficha',
     $('mDetBody').innerHTML.length > 0 && /Constanza Vidal/.test($('mDetBody').innerHTML),
     $('mDetBody').textContent.slice(0, 60));
  ok('14e. y la ficha ofrece cambiarle el estado',
     /entregado|Entregado/.test($('mDetBody').innerHTML));

  // ---------- 15. acciones en lote dentro de Mi carga ----------
  const filasPool = () => [...$('tbodyPool').querySelectorAll('tr')]
      .filter(tr => !tr.querySelector('.empty'));
  ok('15. Mi carga muestra los 2 bultos', filasPool().length === 2, String(filasPool().length));
  ok('15b. y ahora cada fila tiene su casilla',
     $('tbodyPool').querySelectorAll('input[type="checkbox"]').length === 2);

  window.poolAlternar(77, true);
  window.poolAlternar(78, true);
  ok('15c. al marcar aparece la barra de acciones',
     $('poolBarra').style.display === 'flex', $('poolBarra').style.display);
  ok('15d. que dice cuántos hay marcados', /2 bultos marcados/.test($('poolSelN').textContent),
     $('poolSelN').textContent);

  window.__upd = [];
  $('poolRep').value = 'r2';
  await window.__asignarPool();
  ok('16. se puede reasignar en lote desde Mi carga',
     window.__upd.some(u => u.v.repartidor_id === 'r2' && u.ids.includes(77) && u.ids.includes(78)),
     JSON.stringify(window.__upd));

  window.poolAlternar(77, true);
  window.__upd = [];
  await window.__quitarPool();
  ok('16b. y quitarles la asignación',
     window.__upd.some(u => u.v.repartidor_id === null && u.ids.includes(77)),
     JSON.stringify(window.__upd));

  window.poolAlternar(77, true);
  window.__upd = [];
  window.confirm = () => true;
  $('poolEstado').value = 'entregado';
  await $('poolEstado').onchange({ target: $('poolEstado') });
  ok('17. se puede cerrar un bulto como entregado en lote',
     window.__upd.some(u => u.v.estado === 'entregado' && u.ids.includes(77)),
     JSON.stringify(window.__upd));
  ok('17b. y el desplegable vuelve a cero para no repetir sin querer',
     $('poolEstado').value === '', $('poolEstado').value);

  window.poolAlternar(78, true);
  window.__upd = [];
  await $('poolCancelar').onclick();
  ok('18. y cancelarlos', window.__upd.some(u => u.v.estado === 'cancelado' && u.ids.includes(78)),
     JSON.stringify(window.__upd));

  window.poolAlternar(77, true);
  window.poolLimpiarSel();
  ok('19. limpiar esconde la barra', $('poolBarra').style.display === 'none');

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
