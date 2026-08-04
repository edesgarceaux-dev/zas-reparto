import { chromium } from 'playwright';
import path from 'path';

const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });

/* ---------- 1 y 2. panel de la empresa: pool y portal del cliente ---------- */
const p1 = await browser.newPage({ viewport:{width:1440,height:1000} });
await p1.goto('file://'+path.resolve('panel/panel-zas.html'), { waitUntil:'domcontentloaded' });
await p1.evaluate(() => {
  const enMin = m => new Date(Date.now()+m*60000).toISOString();
  const mk = (id,comuna,motivo) => ({ id, codigo:'ZAS-'+String(id).padStart(5,'0'),
    cliente_nombre:['Marta Ruiz','José Pinto','Carla Soto','Luis Vera','Ana Díaz','Pedro Lagos'][id%6],
    direccion:'Av. Siempreviva '+(100+id*7), comuna, cliente_id:1, estado:'pendiente',
    empresa_reparto_id:null, asignacion_motivo:motivo, origen: id%3===0?'jumpseller':'manual',
    creado_en:new Date(Date.now()-id*900000).toISOString(), fecha_pedido:'2026-08-03' });
  eval(`
    HAY_POOL = true; soySuper = true; miEmpresa = 1;
    configRed = { plazo_asignar_min:120, tope_sin_asignar:20 };
    empresas = [{id:1,nombre:'Envíos ZAS',activo:true},{id:2,nombre:'Rápido Ltda',activo:true}];
    clientes = [{id:1,nombre:'Distribuidora Pepitos',activo:true,modo_reparto:'reglas'},{id:5,nombre:'Ferretería Sur'}];
    habilitaciones = [
      {cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:['Maipú','Cerrillos'],cuota_diaria:40,prioridad:5},
      {cliente_id:1,empresa_reparto_id:2,estado:'activa',activo:true,comunas:[],prioridad:100},
      {cliente_id:5,empresa_reparto_id:1,estado:'pendiente',activo:true,solicitado_por:'cliente'}
    ];
    perfiles = [{id:'u1',nombre:'Etienne',rol:'admin',activo:true,empresa_reparto_id:1,superadmin:true}];
    poolPedidos = ${JSON.stringify([
      mk(1,'Providencia','ninguna empresa cubre Providencia o todas llegaron a su cuota del día'),
      mk(2,'Las Condes','ninguna empresa cubre Las Condes o todas llegaron a su cuota del día'),
      mk(3,'Maipú','2 empresas calzan parejo: lo decide el pool'),
      mk(4,'Ñuñoa','volvió al pool: venció el plazo para asignar repartidor'),
      mk(5,'La Florida','el cliente eligió pool libre'),
    ])};
    pedidos = [{id:99,cliente_id:1,estado:'pendiente',repartidor_id:null,vence_asignacion_en:'${enMin(18)}',
                codigo:'ZAS-00099',cliente_nombre:'x',direccion:'y',fecha_pedido:'2026-08-03',creado_en:'2026-08-03T09:00:00Z'}];
    poolSel = new Set();
  `);
  document.getElementById('login').style.display='none';
  document.getElementById('app').style.display='block';
  document.getElementById('navPool').style.display='';
  document.getElementById('navMaestro').style.display='';
  document.getElementById('who').textContent='Etienne';
  ['resumen','pedidos','pool','empresas','clientes','repartidores','mapa','reportes']
    .forEach(t=>{ const s=document.getElementById('t-'+t); if(s) s.style.display = t==='pool'?'block':'none'; });
  document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('on', b.dataset.t==='pool'));
  window.pintarPool(); window.pintarReloj(); window.pintarVinculosPendientes();
});
await p1.screenshot({ path:'red-1-pool.png', fullPage:false });

await p1.evaluate(async () => {
  const DBC = {
    empresas_reparto:[{id:1,nombre:'Envíos ZAS',color:'#2563eb',activo:true},
                      {id:2,nombre:'Rápido Ltda',color:'#cc3300',activo:true},
                      {id:3,nombre:'Nueva SpA',color:'#00aa88',activo:true}],
    cliente_empresas:[
      {cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:['Maipú','Cerrillos','Estación Central'],cuota_diaria:40,porcentaje:null,prioridad:5},
      {cliente_id:1,empresa_reparto_id:2,estado:'activa',activo:true,comunas:['Ñuñoa','Providencia'],cuota_diaria:null,porcentaje:null,prioridad:10},
      {cliente_id:1,empresa_reparto_id:3,estado:'pendiente',activo:true,solicitado_por:'empresa'}],
    clientes:[{id:1,nombre:'Distribuidora Pepitos',modo_reparto:'reglas',plazo_asignar_min:90,tope_sin_asignar:15}],
    config_red:[{plazo_asignar_min:120,tope_sin_asignar:30}],
    v_empresa_conducta:[
      {empresa_reparto_id:1,cliente_id:1,pedidos:412,entregados:401,no_entregados:11,devoluciones:3,min_promedio_asignar:9},
      {empresa_reparto_id:2,cliente_id:1,pedidos:180,entregados:132,no_entregados:14,devoluciones:24,min_promedio_asignar:104}],
  };
  window.__sel = t => DBC[t]||[];
  eval(`
    sb.from = (t) => ({ select: () => { const o = { eq:()=>o, order:()=>o, limit:()=>o,
      maybeSingle:()=>Promise.resolve({data:window.__sel(t)[0]||null,error:null}),
      then:(f)=>Promise.resolve({data:window.__sel(t),error:null}).then(f) }; return o; } });
    empCliId = 1; empNombre = 'Distribuidora Pepitos';
  `);
  document.getElementById('app').style.display='none';
  document.getElementById('empApp').style.display='block';
  document.getElementById('empTitulo').textContent='Pedidos de Distribuidora Pepitos';
  await window.empTab('empresas');
  await new Promise(r=>setTimeout(r,150));
});
await p1.screenshot({ path:'red-2-cliente.png', fullPage:false });

/* ---------- 3. panel maestro ---------- */
const p2 = await browser.newPage({ viewport:{width:1440,height:1000} });
await p2.goto('file://'+path.resolve('panel/panel-maestro.html'), { waitUntil:'domcontentloaded' });
await p2.evaluate(async () => {
  const DB = {
    empresas_reparto:[
      {id:1,nombre:'Envíos ZAS',rut:'76.111.222-3',email:'hola@zas.cl',telefono:'+56 9 1111 1111',color:'#2563eb',plan:'pro',tope_pedidos_mes:null,activo:true},
      {id:2,nombre:'Rápido Ltda',rut:'77.444.555-6',email:'contacto@rapido.cl',telefono:'+56 9 2222 2222',color:'#cc3300',plan:'basico',tope_pedidos_mes:500,activo:true},
      {id:3,nombre:'Andes Express',rut:'78.777.888-9',email:'ops@andes.cl',color:'#00aa88',plan:'prueba',tope_pedidos_mes:100,activo:true}],
    clientes:[
      {id:1,nombre:'Distribuidora Pepitos',rut:'76.111.222-3',modo_reparto:'reglas'},
      {id:2,nombre:'Ferretería Sur',rut:'77.999.888-1',modo_reparto:'pool'},
      {id:3,nombre:'Vinos del Valle',rut:'79.222.333-4',modo_reparto:'reglas'}],
    cliente_empresas:[
      {cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:['Maipú','Cerrillos','Estación Central'],cuota_diaria:40,prioridad:5},
      {cliente_id:1,empresa_reparto_id:2,estado:'activa',activo:true,comunas:['Ñuñoa','Providencia'],prioridad:10},
      {cliente_id:2,empresa_reparto_id:2,estado:'activa',activo:true,comunas:[],porcentaje:60},
      {cliente_id:2,empresa_reparto_id:3,estado:'activa',activo:true,comunas:[],porcentaje:40},
      {cliente_id:3,empresa_reparto_id:3,estado:'pendiente',activo:true,solicitado_por:'empresa'}],
    perfiles:[
      {id:'u1',nombre:'Etienne',rol:'admin',correo:'etienne@zas.cl',activo:true,empresa_reparto_id:1,superadmin:true},
      {id:'u2',nombre:'Admin Rápido',rol:'admin',correo:'admin@rapido.cl',activo:true,empresa_reparto_id:2},
      {id:'u3',nombre:'Repartidor 1',rol:'repartidor',activo:true,empresa_reparto_id:1},
      {id:'u4',nombre:'Repartidor 2',rol:'repartidor',activo:true,empresa_reparto_id:1},
      {id:'u5',nombre:'Admin Andes',rol:'admin',correo:'ops@andes.cl',activo:true,empresa_reparto_id:3}],
    v_empresa_uso_mes:[
      {empresa_reparto_id:1,mes:'2026-08',pedidos:1240,clientes:1},
      {empresa_reparto_id:2,mes:'2026-08',pedidos:436,clientes:2},
      {empresa_reparto_id:3,mes:'2026-08',pedidos:92,clientes:1}],
    v_empresa_conducta:[
      {empresa_reparto_id:1,cliente_id:1,pedidos:1240,entregados:1201,no_entregados:39,devoluciones:6,min_promedio_asignar:9},
      {empresa_reparto_id:2,cliente_id:1,pedidos:436,entregados:322,no_entregados:41,devoluciones:38,min_promedio_asignar:97},
      {empresa_reparto_id:3,cliente_id:2,pedidos:92,entregados:88,no_entregados:4,devoluciones:1,min_promedio_asignar:21}],
    pool_movimientos:[
      ...Array.from({length:210},()=>({empresa_reparto_id:1,accion:'tomado'})),
      ...Array.from({length:6},()=>({empresa_reparto_id:1,accion:'devuelto'})),
      ...Array.from({length:180},()=>({empresa_reparto_id:2,accion:'tomado'})),
      ...Array.from({length:38},()=>({empresa_reparto_id:2,accion:'devuelto'})),
      ...Array.from({length:47},()=>({empresa_reparto_id:2,accion:'vencido'})),
      ...Array.from({length:40},()=>({empresa_reparto_id:3,accion:'tomado'})),
      ...Array.from({length:2},()=>({empresa_reparto_id:3,accion:'vencido'}))],
    config_red:{id:1,plazo_asignar_min:120,tope_sin_asignar:30},
  };
  const chain = rows => { const o = { select:()=>o, order:()=>o, eq:()=>o, gte:()=>o,
    maybeSingle:()=>Promise.resolve({data:Array.isArray(rows)?rows[0]:rows,error:null}),
    then:f=>Promise.resolve({data:rows,error:null}).then(f) }; return o; };
  eval(`sb.from = t => ({ select: () => window.__c(t) }); sb.rpc = async () => ({data:null,error:null});`);
  window.__c = t => chain(t==='config_red' ? DB.config_red : (DB[t]||[]));
  window.mesStr = () => '2026-08';
  document.getElementById('login').style.display='none';
  document.getElementById('app').style.display='block';
  document.getElementById('contenido').style.display='block';
  document.getElementById('who').textContent='Etienne · maestro v1.0';
  await window.cargarTodo();
});
await p2.screenshot({ path:'red-3-maestro.png', fullPage:false });

await p2.evaluate(()=>{ document.querySelector('nav button[data-t="conducta"]').onclick(); });
await p2.screenshot({ path:'red-4-conducta.png', fullPage:false });

await browser.close();
console.log('listas: red-1-pool.png · red-2-cliente.png · red-3-maestro.png · red-4-conducta.png');
