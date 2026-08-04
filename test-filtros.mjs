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
  const $ = id => document.getElementById(id);

  const PEDIDOS = [
    // MercadoLibre Flex con n° de envío: es el que va en la etiqueta
    { id:1, codigo:'ZAS-03833', externo_id:'ML-2000123', envio_id:'44001122333',
      origen:'mercadolibre', cliente_nombre:'Patricia Morales', direccion:'Estacion carampangue 0735',
      comuna:'Puente Alto', estado:'pendiente', fecha_pedido:'2026-08-04', cliente_id:1,
      repartidor_id:null, empresa_reparto_id:1 },
    // MercadoLibre al que todavía le falta el n° de envío
    { id:2, codigo:'ZAS-03834', externo_id:'ML-2000124', envio_id:null,
      origen:'mercadolibre', cliente_nombre:'Rosa Díaz', direccion:'Los Aromos 12',
      comuna:'Maipú', estado:'asignado', fecha_pedido:'2026-08-04', cliente_id:1,
      repartidor_id:'r1', empresa_reparto_id:1 },
    // Jumpseller
    { id:3, codigo:'ZAS-03835', externo_id:'82652', envio_id:null,
      origen:'jumpseller', cliente_nombre:'Luis Soto', direccion:'Gran Avenida 900',
      comuna:'La Cisterna', estado:'en_camino', fecha_pedido:'2026-08-04', cliente_id:1,
      repartidor_id:'r2', empresa_reparto_id:1 },
    // cargado a mano, sin ningún número de tienda
    { id:4, codigo:'ZAS-03836', externo_id:null, envio_id:null,
      origen:'manual', cliente_nombre:'Ana Rojas', direccion:'Sucre 44',
      comuna:'Ñuñoa', estado:'entregado', fecha_pedido:'2026-08-04', cliente_id:1,
      repartidor_id:'r1', empresa_reparto_id:1 },
    // compartido: todavía no es de nadie
    { id:5, codigo:'ZAS-03837', externo_id:'82999', envio_id:null,
      origen:'jumpseller', cliente_nombre:'Mario Pino', direccion:'Vicuña 10',
      comuna:'Recoleta', estado:'pendiente', fecha_pedido:'2026-08-04', cliente_id:1,
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
