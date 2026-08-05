/* ============================================================
   RESPALDO Y LIMPIEZA DE FOTOS, DESDE EL PANEL
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

// JSZip y pdf-lib vienen de un CDN que acá no hay: se ponen de mentira
await page.evaluate(() => {
  window.__zipArchivos = {};
  window.JSZip = function () {
    const self = this;
    self.file = (n, c) => { window.__zipArchivos[n] = c; return self; };
    self.generateAsync = async () => new Blob(['zip-de-mentira']);
    return self;
  };
  window.__descargas = [];
  const crearReal = document.createElement.bind(document);
  document.createElement = (t) => {
    const el = crearReal(t);
    if (t === 'a') { const clic = () => window.__descargas.push(el.download); el.click = clic; }
    return el;
  };
  URL.createObjectURL = () => 'blob:falso';
  URL.revokeObjectURL = () => {};
});

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra = '') => out.push({ n, ok: !!cond, extra });
  const $ = id => document.getElementById(id);

  const FILAS = [
    { pedido_id: 1, n_envio: '47677019895', codigo: 'ZAS-04000', cliente: 'DISTRIBUIDORA PEPITO',
      cliente_final: 'Constanza Vidal', telefono: '999', direccion: 'Aldunate 1064',
      comuna: 'Santiago', repartidor: 'Hans Stuardo', estado: 'entregado',
      fecha_pedido: '2026-05-01', entregado_en: '2026-05-01T15:00:00Z',
      recibio: 'Constanza Vidal', rut_recibe: '11.111.111-1',
      motivo_no_entrega: null, nota_entrega: null,
      foto_domicilio: 'https://x/storage/v1/object/public/entregas/1/domicilio_1.jpg',
      foto_pedido:    'https://x/storage/v1/object/public/entregas/1/pedido_1.jpg',
      foto_receptor:  'https://x/storage/v1/object/public/entregas/1/receptor_1.jpg',
      foto_extra: null },
    { pedido_id: 2, n_envio: '82833', codigo: 'ZAS-04001', cliente: 'FERRETERÍA SUR',
      cliente_final: 'Michelle Cárcamo', telefono: '888', direccion: 'Eradio 10713',
      comuna: 'La Pintana', repartidor: 'Martin Lagos', estado: 'no_entregado',
      fecha_pedido: '2026-05-02', entregado_en: null,
      recibio: null, rut_recibe: null,
      motivo_no_entrega: 'nadie en el domicilio', nota_entrega: 'reagendar',
      foto_domicilio: 'https://x/storage/v1/object/public/entregas/2/domicilio_1.jpg',
      foto_pedido: null, foto_receptor: null, foto_extra: null },
    // uno sin fotos: entra en la planilla igual
    { pedido_id: 3, n_envio: '82834', codigo: 'ZAS-04002', cliente: 'DISTRIBUIDORA PEPITO',
      cliente_final: 'Sin Fotos', telefono: '', direccion: 'Calle 1', comuna: 'Maipú',
      repartidor: 'Hans Stuardo', estado: 'pendiente', fecha_pedido: '2026-05-03',
      entregado_en: null, recibio: null, rut_recibe: null,
      motivo_no_entrega: null, nota_entrega: null,
      foto_domicilio: null, foto_pedido: null, foto_receptor: null, foto_extra: null },
  ];
  const USO = [
    { mes: '2026-05', pedidos: 7700, fotos: 23100, mb_estimados: 4060.5, respaldado: true,  borrable: true },
    { mes: '2026-07', pedidos: 7100, fotos: 21300, mb_estimados: 3744.1, respaldado: false, borrable: false },
    { mes: '2026-08', pedidos: 258,  fotos: 0,     mb_estimados: 0,      respaldado: false, borrable: false },
  ];

  window.__F = FILAS; window.__U = USO;
  window.__rpcs = []; window.__quitados = []; window.__fallaRpc = null;
  window.__loteBorrar = [
    { pedido_id: 1, ruta: '1/domicilio_1.jpg' },
    { pedido_id: 1, ruta: '1/pedido_1.jpg' },
    { pedido_id: 2, ruta: '2/domicilio_1.jpg' },
  ];

  eval(`
    sb.rpc = async (n, a) => {
      window.__rpcs.push({ n, a });
      if (window.__fallaRpc && window.__fallaRpc === n)
        return { data: null, error: { message: 'Could not find the function public.' + n } };
      if (n === 'reporte_periodo')   return { data: window.__F, error: null };
      if (n === 'uso_fotos')         return { data: window.__U, error: null };
      if (n === 'marcar_respaldado') return { data: { ok: true }, error: null };
      if (n === 'fotos_para_borrar') {
        const l = window.__loteBorrar; window.__loteBorrar = []; return { data: l, error: null }; }
      if (n === 'olvidar_fotos')     return { data: { limpiados: (a.p_pedidos||[]).length }, error: null };
      return { data: null, error: null };
    };
    sb.storage = { from: () => ({ remove: async (rutas) => {
      window.__quitados.push(...rutas); return { error: null }; } }) };
    window.__rango    = arRango;
    window.__planilla = arPlanilla;
    window.__fotosDe  = arFotosDe;
    window.__pintarUso = arPintarUso;
  `);
  window.fetch = async () => ({ ok: true, blob: async () => new Blob(['foto']),
                                arrayBuffer: async () => new ArrayBuffer(8) });
  window.cargarTodo = async () => {};
  window.toast = m => { window.__toast = m; };
  window.confirm = () => true;

  // ---------- 1. el período ----------
  ok('1. la sección de respaldo existe', !!$('arZip') && !!$('arLimpiar'));
  $('arPeriodo').value = '7'; $('arPeriodo').onchange();
  const r7 = window.__rango();
  ok('1b. «Semana» pone 7 días',
     r7 && (new Date(r7.hasta) - new Date(r7.desde)) / 86400000 === 6,
     JSON.stringify(r7));
  $('arPeriodo').value = '30'; $('arPeriodo').onchange();
  const r30 = window.__rango();
  ok('1c. «Mes» pone 30 días',
     (new Date(r30.hasta) - new Date(r30.desde)) / 86400000 === 29,
     JSON.stringify(r30));
  ok('1d. y el período termina AYER, no hoy',
     new Date(r30.hasta) < new Date(new Date().toLocaleDateString('en-CA')),
     r30.hasta);

  $('arDesde').value = '2026-05-31'; $('arHasta').value = '2026-05-01';
  ok('1e. un período al revés no se acepta', window.__rango() === null);
  $('arDesde').value = '2026-05-01'; $('arHasta').value = '2026-05-31';
  ok('1f. y uno bien puesto sí', window.__rango() !== null);

  // ---------- 2. la vista previa ----------
  await $('arVerPrevio').onclick();
  const av = $('arAviso').textContent;
  ok('2. la vista previa dice cuántos pedidos y fotos', /3 pedidos/.test(av) && /4 fotos/.test(av), av);
  ok('2b. y no descarga nada todavía', window.__descargas.length === 0);

  // ---------- 3. la planilla ----------
  const csv = window.__planilla(FILAS);
  ok('3. la planilla lleva el n° de envío', /47677019895/.test(csv));
  ok('3b. y quién recibió con su RUT', /Constanza Vidal/.test(csv) && /11\.111\.111-1/.test(csv));
  ok('3c. y el motivo de la no entrega', /nadie en el domicilio/.test(csv));
  ok('3d. dice en qué carpeta están las fotos de cada uno', /fotos\/47677019895/.test(csv));
  ok('3e. y marca al que no tiene fotos', /sin fotos/.test(csv));
  ok('3f. abre bien en Excel: BOM y punto y coma', csv.startsWith('﻿') && csv.includes(';'));
  ok('3g. una fila por pedido más el encabezado', csv.split('\n').length === 4,
     String(csv.split('\n').length));

  // ---------- 4. el ZIP ----------
  window.__zipArchivos = {}; window.__descargas = []; window.__rpcs = [];
  await $('arZip').onclick();
  const nombres = Object.keys(window.__zipArchivos);
  ok('4. el ZIP lleva la planilla', nombres.includes('pedidos.csv'), nombres.join(', '));
  ok('4b. y un LEEME que explica qué es', nombres.includes('LEEME.txt'));
  ok('4c. las fotos van en una carpeta por pedido',
     nombres.includes('fotos/47677019895/domicilio.jpg') &&
     nombres.includes('fotos/47677019895/receptor.jpg') &&
     nombres.includes('fotos/82833/domicilio.jpg'),
     nombres.filter(n => n.startsWith('fotos/')).join(', '));
  ok('4d. las 4 fotos y nada más',
     nombres.filter(n => n.startsWith('fotos/')).length === 4,
     String(nombres.filter(n => n.startsWith('fotos/')).length));
  ok('4e. el archivo se descarga con el período en el nombre',
     /respaldo-zas_2026-05-01_a_2026-05-31\.zip/.test(window.__descargas.join(',')),
     window.__descargas.join(','));

  // ---------- 5. queda anotado el respaldo ----------
  const marca = window.__rpcs.find(x => x.n === 'marcar_respaldado');
  ok('5. se anota el respaldo en la base', !!marca, JSON.stringify(window.__rpcs.map(x => x.n)));
  ok('5b. con el período exacto que se bajó',
     marca?.a.p_desde === '2026-05-01' && marca?.a.p_hasta === '2026-05-31',
     JSON.stringify(marca?.a));
  ok('5c. y con cuántas fotos entraron de verdad', marca?.a.p_fotos === 4,
     String(marca?.a.p_fotos));
  ok('5d. el aviso confirma lo que se bajó',
     /4 fotos/.test($('arAviso').textContent), $('arAviso').textContent);

  // ---------- 6. si el ZIP falla, NO se marca como respaldado ----------
  window.__rpcs = [];
  window.__fallaRpc = 'reporte_periodo';
  await $('arZip').onclick();
  ok('6. si no se puede leer el período, no se marca nada',
     !window.__rpcs.some(x => x.n === 'marcar_respaldado'),
     JSON.stringify(window.__rpcs.map(x => x.n)));
  ok('6b. y dice qué migración falta',
     /migracion-archivo-fotos/.test($('arAviso').innerHTML), $('arAviso').textContent);
  window.__fallaRpc = null;

  // ---------- 7. el cuadro de espacio ----------
  await window.__pintarUso();
  const tabla = $('tbodyUso').innerHTML;
  ok('7. muestra los meses con lo que ocupan', /2026-05/.test(tabla) && /2026-07/.test(tabla));
  ok('7b. los GB se muestran en GB, no en miles de MB', /3\.97 GB/.test(tabla), tabla.replace(/<[^>]*>/g,' ').slice(0,160));
  ok('7c. marca cuál está respaldado y cuál no',
     /✅ sí/.test(tabla) && /<span style="color:#a11">no<\/span>/.test(tabla));
  ok('7d. y cuál se puede liberar', /se puede liberar/.test(tabla));
  ok('7e. el botón de liberar dice cuánto espacio hay',
     /1 mes\(es\)/.test($('arLimpiarTxt').textContent) && /GB/.test($('arLimpiarTxt').textContent),
     $('arLimpiarTxt').textContent);

  // ---------- 8. liberar el espacio ----------
  window.__quitados = []; window.__rpcs = [];
  window.__loteBorrar = [
    { pedido_id: 1, ruta: '1/domicilio_1.jpg' },
    { pedido_id: 1, ruta: '1/pedido_1.jpg' },
    { pedido_id: 2, ruta: '2/domicilio_1.jpg' },
  ];
  await $('arLimpiar').onclick();
  ok('8. borra los archivos del almacenamiento',
     window.__quitados.length === 3, JSON.stringify(window.__quitados));
  ok('8b. usa las rutas del bucket, no las URL enteras',
     window.__quitados.every(x => !/^https?:/.test(x)), JSON.stringify(window.__quitados));
  ok('8c. y después limpia los links en la base',
     window.__rpcs.some(x => x.n === 'olvidar_fotos' &&
                        x.a.p_pedidos.length === 2 &&
                        x.a.p_pedidos.includes(1) && x.a.p_pedidos.includes(2)),
     JSON.stringify(window.__rpcs.filter(x => x.n === 'olvidar_fotos')));
  ok('8d. pide los 90 días, no menos',
     window.__rpcs.find(x => x.n === 'fotos_para_borrar')?.a.p_dias === 90,
     JSON.stringify(window.__rpcs.find(x => x.n === 'fotos_para_borrar')?.a));
  ok('8e. sigue pidiendo lotes hasta que no queda nada',
     window.__rpcs.filter(x => x.n === 'fotos_para_borrar').length === 2,
     String(window.__rpcs.filter(x => x.n === 'fotos_para_borrar').length));
  ok('8f. y avisa cuántas liberó', /3 fotos/.test($('arAviso').innerHTML), $('arAviso').textContent);

  // ---------- 9. si el borrado falla a la mitad, se dice ----------
  window.__loteBorrar = [{ pedido_id: 9, ruta: '9/a.jpg' }];
  window.__fallaRpc = 'olvidar_fotos';
  await $('arLimpiar').onclick();
  ok('9. si algo falla, lo dice en vez de quedarse callado',
     /cort/.test($('arAviso').textContent), $('arAviso').textContent);
  window.__fallaRpc = null;

  // ---------- 10. no se puede pisar un trabajo con otro ----------
  ok('10. el botón de cancelar aparece solo mientras trabaja',
     $('arCancelar').style.display === 'none', $('arCancelar').style.display);

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
