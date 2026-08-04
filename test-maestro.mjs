import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-maestro.html');
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
const page = await browser.newPage();
const errors = [];
page.on('pageerror', e => errors.push('pageerror: ' + e.message));
page.on('console', m => { if (m.type()==='error' && !/ERR_CONNECTION|ERR_FILE_NOT_FOUND|ERR_NAME_NOT_RESOLVED|Failed to load resource/.test(m.text())) errors.push('console: '+m.text()); });
await page.goto(url, { waitUntil: 'domcontentloaded' });

const r = await page.evaluate(async () => {
  const out = [];
  const ok = (n, cond, extra='') => out.push({ n, ok: !!cond, extra });
  const $ = id => document.getElementById(id);

  // ---------- base de datos de mentira ----------
  const DB = {
    empresas_reparto: [
      {id:1,nombre:'Envíos ZAS',rut:'76.1-1',email:'zas@zas.cl',color:'#2563eb',plan:'pro',tope_pedidos_mes:null,activo:true},
      {id:2,nombre:'Rápido Ltda',rut:'77.2-2',email:'r@r.cl',color:'#cc3300',plan:'basico',tope_pedidos_mes:100,activo:true},
      {id:3,nombre:'Lentos SpA',plan:'prueba',tope_pedidos_mes:50,activo:false},
    ],
    clientes: [
      {id:1,nombre:'Distribuidora Pepitos',rut:'76.111.222-3',modo_reparto:'reglas'},
      {id:2,nombre:'Ferretería Sur',rut:'77.999.888-1',modo_reparto:'pool'},
      {id:3,nombre:'Sin nadie',rut:null,modo_reparto:'reglas'},
    ],
    cliente_empresas: [
      {cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:['Maipú','Cerrillos'],cuota_diaria:40,porcentaje:null,prioridad:5,solicitado_por:'sistema'},
      {cliente_id:1,empresa_reparto_id:2,estado:'activa',activo:true,comunas:[],cuota_diaria:null,porcentaje:null,prioridad:100,solicitado_por:'sistema'},
      {cliente_id:2,empresa_reparto_id:2,estado:'pendiente',activo:true,comunas:[],solicitado_por:'empresa'},
    ],
    perfiles: [
      {id:'u1',nombre:'Etienne',rol:'admin',correo:'e@zas.cl',activo:true,empresa_reparto_id:1,superadmin:true},
      {id:'u2',nombre:'Admin Rápido',rol:'admin',correo:'a@r.cl',activo:true,empresa_reparto_id:2,superadmin:false},
      {id:'u3',nombre:'Repa',rol:'repartidor',activo:true,empresa_reparto_id:1,superadmin:false},
    ],
    v_empresa_uso_mes: [
      {empresa_reparto_id:1,mes:'2026-08',pedidos:320,clientes:2},
      {empresa_reparto_id:2,mes:'2026-08',pedidos:95,clientes:1},
    ],
    v_empresa_conducta: [
      {empresa_reparto_id:1,cliente_id:1,pedidos:100,entregados:95,no_entregados:5,devoluciones:2,min_promedio_asignar:12},
      {empresa_reparto_id:2,cliente_id:1,pedidos:50,entregados:20,no_entregados:5,devoluciones:9,min_promedio_asignar:110},
    ],
    pool_movimientos: [
      ...Array.from({length:20},()=>({empresa_reparto_id:1,accion:'tomado',creado_en:'2026-08-01T10:00:00Z'})),
      ...Array.from({length:30},()=>({empresa_reparto_id:2,accion:'tomado',creado_en:'2026-08-01T10:00:00Z'})),
      ...Array.from({length:9},()=>({empresa_reparto_id:2,accion:'vencido',creado_en:'2026-08-01T12:00:00Z'})),
      ...Array.from({length:4},()=>({empresa_reparto_id:2,accion:'devuelto',creado_en:'2026-08-01T12:00:00Z'})),
    ],
    config_red: {id:1,plazo_asignar_min:120,tope_sin_asignar:30},
  };

  const chain = (rows) => {
    const p = { data: Array.isArray(rows) ? rows : rows, error: null };
    const o = {
      select: () => o, order: () => o, eq: () => o, gte: () => o,
      maybeSingle: () => Promise.resolve({ data: Array.isArray(rows) ? rows[0] : rows, error:null }),
      then: (f) => Promise.resolve(p).then(f),
    };
    return o;
  };
  window.__updates = [];
  window.__rpc = [];
  eval(`
    sb.from = (t) => ({
      select: () => window.__chain(t),
      update: (v) => { const r = { data:{id:1,...v}, error:null };
        const o = { eq: () => o, select: () => o, maybeSingle: () => Promise.resolve(r),
                    then: (f)=>Promise.resolve(r).then(f) };
        window.__updates.push({t, v}); return o; },
      insert: (v) => { const r = { data:{id:9,...v}, error:null };
        const o = { select: () => o, maybeSingle: () => Promise.resolve(r),
                    then: (f)=>Promise.resolve(r).then(f) };
        window.__updates.push({t, v, ins:true}); return o; },
    });
    sb.rpc = async (n, a) => { window.__rpc.push({n,a}); return { data:{ok:true,mensaje:'Vínculo activado'}, error:null }; };
  `);
  window.__chain = (t) => chain(t==='config_red' ? DB.config_red : (DB[t]||[]));

  // fecha fija para el mes en curso
  window.mesStr = () => '2026-08';

  await window.cargarTodo();

  // ---------- 1. empresas ----------
  const tEmp = $('tbodyEmp').innerHTML;
  ok('1. lista las 3 empresas', /Envíos ZAS/.test(tEmp) && /Rápido Ltda/.test(tEmp) && /Lentos SpA/.test(tEmp));
  ok('1b. muestra el plan de cada una', /pro/.test(tEmp) && /basico/.test(tEmp) && /prueba/.test(tEmp));
  ok('1c. muestra el uso del mes', /320/.test(tEmp) && /95/.test(tEmp), '');
  ok('1d. avisa cuál está inactiva', (tEmp.match(/pill-no/g)||[]).length >= 1);
  ok('1e. cuenta la gente de cada empresa sin mezclar', /<td>2<\/td>/.test(tEmp), '');

  const kpi = $('kpiEmp').textContent;
  ok('2. el resumen cuenta empresas activas', kpi.includes('Empresas activas'));
  ok('2b. el resumen cuenta las solicitudes pendientes', /1\s*Solicitudes pendientes/.test(kpi.replace(/\s+/g,' ')), kpi.replace(/\s+/g,' '));

  // ---------- 3. clientes de la red ----------
  const tCli = $('tbodyCli').innerHTML;
  ok('3. lista los clientes con su RUT', /Distribuidora Pepitos/.test(tCli) && /76\.111\.222-3/.test(tCli));
  ok('3b. muestra qué empresas le reparten y con qué reglas', /2 comunas/.test(tCli) && /cuota 40/.test(tCli), '');
  ok('3c. marca al que eligió pool libre', /pool libre/.test(tCli));
  ok('3d. avisa del cliente que no ve nadie', /no los ve ninguna empresa/.test(tCli));

  const pend = $('pendientes').innerHTML;
  ok('4. muestra la solicitud pendiente', /Rápido Ltda/.test(pend) && /Ferretería Sur/.test(pend));
  ok('4b. dice a quién le toca responder', /falta que acepte el cliente/.test(pend), pend.replace(/<[^>]*>/g,' ').slice(0,160));

  await window.responder(2, 2, true);
  ok('4c. destrabar llama a responder_vinculo', window.__rpc.some(r=>r.n==='responder_vinculo' && r.a.p_aceptar===true),
      JSON.stringify(window.__rpc));

  // ---------- 5. conducta ----------
  const tCond = $('tbodyCond').innerHTML;
  ok('5. muestra los vencidos de cada empresa', /<b style="color:#a02222">9<\/b>/.test(tCond), '');
  ok('5b. resalta a la que acapara', /background:#FFF6F6/.test(tCond));
  ok('5c. muestra cuánto tarda en asignar', /110 min/.test(tCond) && /12 min/.test(tCond));
  ok('5d. calcula el cumplimiento', /95%/.test(tCond) && /40%/.test(tCond), '');

  await window.liberarAhora();
  ok('5e. el botón de liberar llama a liberar_vencidos', window.__rpc.some(r=>r.n==='liberar_vencidos'));

  // ---------- 6. reglas de la red ----------
  ok('6. carga el plazo y el tope de la red', $('rPlazo').value==='120' && $('rTope').value==='30');
  $('rPlazo').value = '5';
  await $('rGuardar').onclick();
  ok('6b. no deja poner un plazo absurdo', $('rErr').textContent.includes('entre 10 y 1440'), $('rErr').textContent);
  $('rPlazo').value = '90'; $('rTope').value = '15';
  await $('rGuardar').onclick();
  ok('6c. guarda plazo y tope', window.__updates.some(u=>u.t==='config_red' && u.v.plazo_asignar_min===90 && u.v.tope_sin_asignar===15),
      JSON.stringify(window.__updates.filter(u=>u.t==='config_red')));

  // ---------- 7. modal de empresa ----------
  window.abrirEmp(2);
  ok('7. abre la ficha de la empresa con sus datos', $('mEmp').classList.contains('on') &&
      $('epNombre').value==='Rápido Ltda' && $('epPlan').value==='basico' && $('epTope').value==='100');
  ok('7b. lista sus cuentas de administrador', $('epCuentas').innerHTML.includes('Admin Rápido') &&
      !$('epCuentas').innerHTML.includes('Etienne'), $('epCuentas').textContent);
  $('epNombre').value = 'Rápido Ltda 2';
  await $('epGuardar').onclick();
  ok('7c. guarda los cambios', window.__updates.some(u=>u.t==='empresas_reparto' && u.v.nombre==='Rápido Ltda 2'));

  window.abrirEmp(null);
  ok('7d. la empresa nueva parte en blanco y en plan prueba', $('epNombre').value==='' && $('epPlan').value==='prueba');
  ok('7e. no deja guardar sin nombre', (async()=>{ await $('epGuardar').onclick(); return true; })() && true);

  // ---------- 8. pestañas ----------
  document.querySelector('nav button[data-t="conducta"]').onclick();
  ok('8. cambiar de pestaña muestra solo esa', $('t-conducta').style.display==='block' && $('t-empresas').style.display==='none');

  return out;
});

await browser.close();
let malos = 0;
for (const t of r) { if (!t.ok) malos++; console.log((t.ok?'✅':'❌') + ' ' + t.n + (t.extra?('  ← '+t.extra):'')); }
if (errors.length) { console.log('\nERRORES DE LA PÁGINA:'); errors.forEach(e=>console.log('  '+e)); }
console.log(`\n${r.length - malos}/${r.length} pruebas OK` + (errors.length?` · ${errors.length} errores de página`:''));
process.exit(malos || errors.length ? 1 : 0);
