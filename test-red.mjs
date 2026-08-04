import { chromium } from 'playwright';
import path from 'path';

const url = 'file://' + path.resolve('panel/panel-zas.html');
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
  const enMin = m => new Date(Date.now() + m*60000).toISOString();

  window.__rpc = []; window.__upd = []; window.__del = []; window.__ins = []; window.__insErr = null;
  eval(`
    sb.rpc = async (n,a) => {
      window.__rpc.push({n,a});
      if(n==='buscar_cliente_red'){
        const r = String(a.p_rut).replace(/[^0-9kK]/g,'');
        if(r==='761112223') return {data:{existe:true,id:7,nombre:'Panadería Doña Eli',comuna:'Maipú',vinculo:'sin_vinculo'},error:null};
        if(r==='777777777') return {data:{existe:true,id:8,nombre:'Ya Trabajamos',vinculo:'activa'},error:null};
        if(r==='888888888') return {data:{existe:true,id:9,nombre:'Esperando',vinculo:'pendiente'},error:null};
        return {data:{existe:false},error:null};
      }
      if(n==='planificar_pedidos') return { data:{planificados:(a.p_ids||[]).length}, error:null };
      return { data:{ok:true, mensaje:'Solicitud enviada. El cliente tiene que aceptarla desde su panel.'}, error:null };
    };
    sb.from = (t) => ({
      select: () => { const o = { eq:()=>o, order:()=>o, limit:()=>o,
        maybeSingle:()=>Promise.resolve({data:window.__sel(t)[0]||null,error:null}),
        gte:()=>o, not:()=>o, in:()=>o,
        then:(f)=>Promise.resolve({data:window.__sel(t),error:null}).then(f) }; return o; },
      update: (v) => { const o = { eq: ()=>o, in: (c,ids)=>{ o.__ids=ids; return o; }, not: ()=>o, select: ()=>o,
        then:(f)=>{ window.__upd.push({t,v}); return Promise.resolve({data:(o.__ids||[]).map(id=>({id})), error:null}).then(f); } }; return o; },
      delete: () => { const o = { eq: ()=>o, then:(f)=>{ window.__del.push({t}); return Promise.resolve({error:null}).then(f); } }; return o; },
      insert: (v) => ({ then:(f)=>{ window.__ins.push({t,v}); return Promise.resolve(window.__insErr||{error:null}).then(f); } }),
    });
  `);
  window.__sel = () => [];

  // ---------- 0. una empresa RECIÉN CREADA, sin un solo pedido ----------
  // Bug de v1.35: el panel decidía si la migración estaba corrida mirando
  // si algún pedido traía la columna nueva. Sin pedidos, decía que no y le
  // escondía el Pool, el botón de sumar clientes y las invitaciones.
  window.__sel = (t) => t === 'empresas_reparto' ? [{id:9,nombre:'Rapiditos 360',activo:true}]
                      : t === 'config_red'       ? [{plazo_asignar_min:120,tope_sin_asignar:30}]
                      : t === 'cliente_empresas' ? [{cliente_id:1,empresa_reparto_id:9,estado:'pendiente',activo:true,solicitado_por:'cliente'}]
                      : [];
  eval("soySuper = false; miEmpresa = 9;");
  await window.cargarTodo();
  ok('0. empresa nueva sin pedidos: igual reconoce que la migración está corrida',
      eval("HAY_POOL") === true, 'HAY_POOL=' + eval("HAY_POOL"));
  ok('0b. le muestra la pestaña Mi carga', $('navPool').style.display !== 'none');
  ok('0c. le muestra el botón de sumar clientes de la red', $('btnSumarRed').style.display !== 'none');
  ok('0d. y ve la invitación que le mandaron', /Te invitaron a repartir/.test($('avisoVinculos').textContent),
      $('avisoVinculos').textContent.slice(0,80));
  ok('0e. la tabla vacía le explica los tres caminos',
      /Sumar cliente de la red/.test($('tbodyCli') ? $('tbodyCli').innerHTML : document.querySelector('#t-clientes tbody').innerHTML),
      '');
  // ---------- 0f. el dueño entra al panel de UNA empresa ----------
  // La base le deja ver todo, pero el panel de empresa tiene que mostrarle
  // solo lo de esa empresa: si no, le aparecen los repartidores y los
  // pedidos de las otras.
  window.__sel = (t) =>
      t === 'empresas_reparto' ? [{id:1,nombre:'Envíos ZAS',activo:true},{id:9,nombre:'Rapiditos 360',activo:true}]
    : t === 'config_red'       ? [{plazo_asignar_min:120,tope_sin_asignar:30}]
    : t === 'cliente_empresas' ? [{cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:[]},
                                  {cliente_id:2,empresa_reparto_id:9,estado:'activa',activo:true,comunas:[]}]
    : t === 'clientes'         ? [{id:1,nombre:'Mi Cliente'},{id:2,nombre:'Cliente de la otra'}]
    : t === 'perfiles'         ? [{id:'u1',nombre:'Repa ZAS',rol:'repartidor',activo:true,empresa_reparto_id:1},
                                  {id:'u9',nombre:'Repa Rapiditos',rol:'repartidor',activo:true,empresa_reparto_id:9}]
    : t === 'pedidos'          ? [{id:1,codigo:'A',cliente_id:1,empresa_reparto_id:1,estado:'pendiente',cliente_nombre:'x',direccion:'y',fecha_pedido:'2026-08-04',creado_en:'2026-08-04T09:00:00Z'},
                                  {id:2,codigo:'B',cliente_id:2,empresa_reparto_id:9,estado:'pendiente',cliente_nombre:'x',direccion:'y',fecha_pedido:'2026-08-04',creado_en:'2026-08-04T09:00:00Z'},
                                  {id:3,codigo:'C',cliente_id:2,empresa_reparto_id:null,estado:'pendiente',cliente_nombre:'x',direccion:'y',fecha_pedido:'2026-08-04',creado_en:'2026-08-04T09:00:00Z'}]
    : [];
  eval("soySuper = true; miEmpresa = 1;");
  await window.cargarTodo();
  ok('0f. el dueño NO ve repartidores de otra empresa en el panel de ZAS',
      !eval("perfiles").some(p=>p.nombre==='Repa Rapiditos'), eval("JSON.stringify(perfiles.map(p=>p.nombre))"));
  ok('0g. tampoco los clientes de la otra', !eval("clientes").some(c=>c.nombre==='Cliente de la otra'),
      eval("JSON.stringify(clientes.map(c=>c.nombre))"));
  ok('0h. ni sus pedidos', eval("pedidos.filter(p=>p.codigo==='B').length")===0,
      eval("JSON.stringify(pedidos.map(p=>p.codigo))"));
  ok('0i. ni los pedidos compartidos de un cliente que no es suyo',
      !eval("pedidos").some(p=>p.codigo==='C'), eval("JSON.stringify(pedidos.map(p=>p.codigo))"));
  ok('0j. le avisa qué empresa está mirando',
      $('avisoEmpresa').style.display==='block' && /Envíos ZAS/.test($('avisoEmpresa').textContent),
      $('avisoEmpresa').textContent.slice(0,90));

  window.__sel = () => [];

  // =====================================================================
  //  PANEL DE LA EMPRESA DE REPARTO
  // =====================================================================
  const mkPool = (id, comuna, motivo) => ({ id, codigo:'ZAS-'+String(id).padStart(5,'0'),
    cliente_nombre:'Don '+id, direccion:'Calle '+id, comuna, cliente_id:1, estado:'pendiente',
    empresa_reparto_id:null, asignacion_motivo:motivo, creado_en:'2026-08-03T10:00:00Z', fecha_pedido:'2026-08-03' });

  eval(`
    HAY_POOL = true; soySuper = true; miEmpresa = 1;
    configRed = { plazo_asignar_min:120, tope_sin_asignar:5 };
    empresas = [{id:1,nombre:'Envíos ZAS',activo:true},{id:2,nombre:'Rápido Ltda',activo:true}];
    clientes = [{id:1,nombre:'Distribuidora Pepitos',activo:true,modo_reparto:'reglas',plazo_asignar_min:null,tope_sin_asignar:null}];
    habilitaciones = [
      {cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:['Maipú','Cerrillos'],cuota_diaria:40,porcentaje:null,prioridad:5},
      {cliente_id:1,empresa_reparto_id:2,estado:'activa',activo:true,comunas:[],cuota_diaria:null,porcentaje:null,prioridad:100},
      {cliente_id:5,empresa_reparto_id:1,estado:'pendiente',activo:true,solicitado_por:'cliente'},
      {cliente_id:6,empresa_reparto_id:1,estado:'pendiente',activo:true,solicitado_por:'empresa'}
    ];
    clientes.push({id:5,nombre:'Me invitó'},{id:6,nombre:'Le pedí yo'});
    perfiles = [{id:'u1',nombre:'Etienne',rol:'admin',activo:true,empresa_reparto_id:1,superadmin:true}];
    poolPedidos = ${JSON.stringify([
      mkPool(1,'Providencia','ninguna empresa cubre Providencia o todas llegaron a su cuota del día'),
      mkPool(2,'Maipú','2 empresas calzan parejo: lo decide el pool'),
      mkPool(3,'Ñuñoa','volvió al pool: venció el plazo para asignar repartidor'),
    ])};
    pedidos = [];
    poolSel = new Set();
  `);

  // ---------- 2. los compartidos viven dentro de Pedidos ----------
  eval(`
    misPlanes = [{pedido_id:2, empresa_reparto_id:1, repartidor_id:'u1'}];
    perfiles = [{id:'u1',nombre:'Repa ZAS',rol:'repartidor',activo:true,empresa_reparto_id:1}];
    pedidos = [
      {id:1,codigo:'MIO',cliente_id:1,empresa_reparto_id:1,repartidor_id:'u1',estado:'asignado',
       cliente_nombre:'a',direccion:'x',comuna:'Maipú',fecha_pedido:'2026-08-04',creado_en:'2026-08-04T09:00:00Z'},
      {id:2,codigo:'COMP',cliente_id:1,empresa_reparto_id:null,repartidor_id:null,estado:'pendiente',
       cliente_nombre:'b',direccion:'y',comuna:'Ñuñoa',fecha_pedido:'2026-08-04',creado_en:'2026-08-04T09:00:00Z'}];
    filtro='todos'; busq='';
  `);
  window.pintarPedidos();
  const tped = $('tbodyPed').innerHTML;
  ok('2. los compartidos aparecen en Pedidos junto con los míos',
      /MIO/.test(tped) && /COMP/.test(tped), '');
  ok('2b. el compartido se marca como tal', /compartido/.test(tped), '');
  ok('2c. y muestra el repartidor previsto del plan propio',
      /Repa ZAS <span class="cod">\(previsto\)/.test(tped), '');

  // ---------- 2d. asignar reparte según sea mío o compartido ----------
  window.__upd = []; window.__rpc = [];
  eval("seleccion.clear(); seleccion.add(1); seleccion.add(2);");
  $('masivaRep').innerHTML = '<option value="u1">Repa ZAS</option>';
  $('masivaRep').value = 'u1';
  await $('masivaAsignar').onclick();
  ok('2d. el mío se asigna escribiendo el pedido',
      window.__upd.some(u=>u.t==='pedidos' && u.v.repartidor_id==='u1'), JSON.stringify(window.__upd));
  ok('2e. el compartido va a plan_reparto, no al pedido',
      window.__rpc.some(r=>r.n==='planificar_pedidos' && r.a.p_ids.length===1 && r.a.p_ids[0]===2),
      JSON.stringify(window.__rpc.filter(r=>r.n==='planificar_pedidos')));

  // ---------- 2f. avisos de lo que se perdió ----------
  eval("avisosRed = [{id:1,texto:'El pedido ZAS-1 (Maipú) lo cargó Rapiditos 360: salió de tu ruta.'}];");
  window.pintarAvisos();
  ok('2f. avisa los pedidos que se le escaparon',
      $('avisosRed').style.display==='block' && /lo cargó Rapiditos 360/.test($('avisosRed').textContent),
      $('avisosRed').textContent.slice(0,90));
  await window.marcarAvisosVistos();
  ok('2g. se pueden dar por vistos',
      $('avisosRed').style.display==='none' && window.__upd.some(u=>u.t==='avisos_red' && u.v.visto===true));

  // ---------- 2h. Mi carga ----------
  eval(`poolPedidos = [{id:9,codigo:'CARGADO',cliente_id:1,empresa_reparto_id:1,repartidor_id:'u1',
        estado:'asignado',cliente_nombre:'c',direccion:'z',comuna:'Maipú',
        cargado_en:'2026-08-04T11:00:00Z',creado_en:'2026-08-04T09:00:00Z'}];
        poolComunaSel=''; poolBusq='';`);
  window.pintarPool();
  ok('2h. Mi carga muestra lo ya escaneado', /CARGADO/.test($('tbodyPool').innerHTML), '');
  ok('2i. y dice cuántos bultos son', /1 bulto cargado/.test($('carRes').textContent), $('carRes').textContent);

  // reponemos el escenario para las pruebas que siguen
  eval(`
    misPlanes = []; avisosRed = [];
    perfiles = [{id:'u1',nombre:'Etienne',rol:'admin',activo:true,empresa_reparto_id:1,superadmin:true}];
    clientes = [{id:1,nombre:'Distribuidora Pepitos',activo:true,modo_reparto:'reglas',plazo_asignar_min:null,tope_sin_asignar:null},
                {id:5,nombre:'Me invitó'},{id:6,nombre:'Le pedí yo'}];
    habilitaciones = [
      {cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:['Maipú','Cerrillos'],cuota_diaria:40,porcentaje:null,prioridad:5},
      {cliente_id:1,empresa_reparto_id:2,estado:'activa',activo:true,comunas:[],cuota_diaria:null,porcentaje:null,prioridad:100},
      {cliente_id:5,empresa_reparto_id:1,estado:'pendiente',activo:true,solicitado_por:'cliente'},
      {cliente_id:6,empresa_reparto_id:1,estado:'pendiente',activo:true,solicitado_por:'empresa'}];
    empresas = [{id:1,nombre:'Envíos ZAS',activo:true},{id:2,nombre:'Rápido Ltda',activo:true}];
    seleccion.clear();
  `);

  // ---------- 3. el reloj para asignar repartidor ----------
  eval(`pedidos = [
    {id:201,cliente_id:1,estado:'pendiente',repartidor_id:null,vence_asignacion_en:'${enMin(15)}',codigo:'A',cliente_nombre:'x',direccion:'y',fecha_pedido:'2026-08-03',creado_en:'2026-08-03T09:00:00Z'},
    {id:202,cliente_id:1,estado:'pendiente',repartidor_id:null,vence_asignacion_en:'${enMin(90)}',codigo:'B',cliente_nombre:'x',direccion:'y',fecha_pedido:'2026-08-03',creado_en:'2026-08-03T09:00:00Z'}
  ];`);
  window.pintarReloj();
  ok('3. avisa cuáles están por vencerse', /1 pedido está por vencerse/.test($('avisoReloj').textContent), $('avisoReloj').textContent);

  eval(`pedidos[0].vence_asignacion_en = '${enMin(-5)}';`);
  window.pintarReloj();
  ok('3b. avisa cuando alguno ya volvió al pool', /volvió al pool/.test($('avisoReloj').textContent), $('avisoReloj').textContent);

  eval(`pedidos = [{id:203,cliente_id:1,estado:'asignado',repartidor_id:'r1',codigo:'C',cliente_nombre:'x',direccion:'y',fecha_pedido:'2026-08-03',creado_en:'2026-08-03T09:00:00Z'}];`);
  window.pintarReloj();
  ok('3c. si están todos asignados no molesta con avisos', $('avisoReloj').style.display==='none');

  // ---------- 4. solicitudes de vínculo ----------
  window.pintarVinculosPendientes();
  const av = $('avisoVinculos');
  ok('4. muestra la invitación que le toca responder', /Te invitaron a repartir/.test(av.textContent) && /Me invitó/.test(av.textContent), av.textContent.slice(0,140));
  ok('4b. y la que está esperando respuesta del cliente', /Esperando que acepte/.test(av.textContent) && /Le pedí yo/.test(av.textContent), av.textContent.slice(0,200));

  ok('4d. el globito del menú Clientes marca la que espera respuesta',
      $('cliN').style.display==='inline-block' && $('cliN').textContent==='1',
      'display='+$('cliN').style.display+' n='+$('cliN').textContent);

  window.cargarTodo = async ()=>{};
  await window.responderVinculo(5, true);
  ok('4c. aceptar llama a responder_vinculo con mi empresa',
      window.__rpc.some(r=>r.n==='responder_vinculo' && r.a.p_cliente_id===5 && r.a.p_empresa_id===1 && r.a.p_aceptar===true),
      JSON.stringify(window.__rpc.filter(r=>r.n==='responder_vinculo')));

  // ---------- 5. sumar un cliente de la red ----------
  window.abrirSumarRed();
  ok('5. abre el buscador por RUT', $('mSumarRed').classList.contains('on'));
  $('srRut').value = '76.111.222-3';
  await window.buscarEnLaRed();
  ok('5b. encuentra al cliente y ofrece pedírselo', /Panadería Doña Eli/.test($('srResultado').innerHTML) && /Pedirle trabajar/.test($('srResultado').innerHTML));

  await window.pedirCliente(7);
  ok('5c. mandar la solicitud llama a solicitar_cliente',
      window.__rpc.some(r=>r.n==='solicitar_cliente' && r.a.p_cliente_id===7));
  ok('5d. avisa que ahora decide el cliente', /tiene que aceptarla/.test($('srResultado').textContent), $('srResultado').textContent);

  $('srRut').value = '77.777.777-7'; await window.buscarEnLaRed();
  ok('5e. si ya trabajás con él, no ofrece pedirlo de nuevo',
      /Ya trabajás con este cliente/.test($('srResultado').textContent) && !/Pedirle trabajar/.test($('srResultado').innerHTML));
  $('srRut').value = '88.888.888-8'; await window.buscarEnLaRed();
  ok('5f. si ya le pediste, dice que está esperando', /Falta que la acepte|falta que la acepte/i.test($('srResultado').textContent), $('srResultado').textContent);
  $('srRut').value = '11.111.111-1'; await window.buscarEnLaRed();
  ok('5g. si no está en la red, manda a crearlo como nuevo', /no está en la red/.test($('srResultado').textContent));
  $('srRut').value = ''; await window.buscarEnLaRed();
  ok('5h. sin RUT pide el RUT', $('srErr').textContent.includes('Escribí el RUT'));

  // ---------- 6. las reglas del cliente, en su ficha ----------
  eval("clienteEditando = 1");
  window.pintarEmpresasDelCliente();
  const rc = $('cReglasCliente').textContent;
  ok('6. la ficha del cliente muestra sus reglas', /Maipú, Cerrillos/.test(rc) && /máx\. 40 al día/.test(rc), rc.slice(0,200));
  ok('6b. dice en qué modo está', /por reglas/.test(rc));
  ok('6c. muestra los frenos que le corresponden', /hasta 5 pedidos tomados sin repartidor y 120 min/.test(rc), rc);
  ok('6d. aclara que eso lo decide el cliente', /Esto lo cambia el cliente desde su portal/.test(rc));

  // =====================================================================
  //  PORTAL DEL CLIENTE
  // =====================================================================
  const DBC = {
    empresas_reparto: [
      {id:1,nombre:'Envíos ZAS',color:'#2563eb',activo:true},
      {id:2,nombre:'Rápido Ltda',color:'#cc3300',activo:true},
      {id:3,nombre:'Nueva SpA',color:'#00aa88',activo:true},
    ],
    cliente_empresas: [
      {cliente_id:1,empresa_reparto_id:1,estado:'activa',activo:true,comunas:['Maipú'],cuota_diaria:30,porcentaje:70,prioridad:5},
      {cliente_id:1,empresa_reparto_id:2,estado:'activa',activo:false,comunas:[],cuota_diaria:null,porcentaje:30,prioridad:100},
      {cliente_id:1,empresa_reparto_id:3,estado:'pendiente',activo:true,solicitado_por:'empresa'},
    ],
    clientes: [{id:1,nombre:'Distribuidora Pepitos',modo_reparto:'reglas',plazo_asignar_min:999,tope_sin_asignar:2}],
    config_red: [{plazo_asignar_min:120,tope_sin_asignar:30}],
    v_empresa_conducta: [
      {empresa_reparto_id:1,cliente_id:1,pedidos:80,entregados:78,no_entregados:2,devoluciones:1,min_promedio_asignar:10},
      {empresa_reparto_id:2,cliente_id:1,pedidos:40,entregados:15,no_entregados:5,devoluciones:12,min_promedio_asignar:115},
    ],
  };
  window.__sel = (t) => DBC[t] || [];
  eval("empCliId = 1");

  window.empTab('empresas');
  await new Promise(r=>setTimeout(r,60));
  ok('7. el cliente tiene su pestaña de empresas', $('empVistaEmpresas').style.display==='block' && $('empVistaPedidos').style.display==='none');

  const vc = $('empVistaEmpresas');
  ok('7b. lista sus empresas con las reglas cargadas',
      vc.querySelector('#reg-com-1').value==='Maipú' && vc.querySelector('#reg-cuo-1').value==='30' &&
      vc.querySelector('#reg-pct-1').value==='70' && vc.querySelector('#reg-pri-1').value==='5');
  ok('7c. marca la que está en pausa', /en pausa/.test(vc.textContent) && /Reanudar/.test(vc.textContent));
  ok('7d. muestra la solicitud que le mandaron', /Nueva SpA/.test(vc.textContent) && /te mandó una solicitud/.test(vc.textContent));
  ok('7e. deja elegir el modo de reparto', vc.querySelectorAll('input[name="modoRep"]').length===2 &&
      vc.querySelector('input[name="modoRep"][value="reglas"]').checked);

  ok('8. le recorta el plazo al piso de la red', $('empPlazo').value==='120', 'valor='+$('empPlazo').value);
  ok('8b. pero le respeta el tope más estricto que puso él', $('empTope').value==='2', 'valor='+$('empTope').value);
  ok('8c. le dice cuál es el máximo permitido', /Máximo permitido: 120/.test(vc.textContent) && /Máximo permitido: 30/.test(vc.textContent));

  ok('9. muestra cómo se porta cada empresa con sus pedidos', /115 min/.test(vc.textContent) && /10 min/.test(vc.textContent));

  // guardar reglas
  $('reg-com-1').value = 'Maipú, Ñuñoa , Cerrillos';
  $('reg-cuo-1').value = ''; $('reg-pct-1').value = '60'; $('reg-pri-1').value = '2';
  await window.empGuardarReglas(1);
  const u = window.__upd.filter(x=>x.t==='cliente_empresas').pop();
  ok('10. guarda las comunas separadas y limpias', JSON.stringify(u.v.comunas)===JSON.stringify(['Maipú','Ñuñoa','Cerrillos']), JSON.stringify(u.v));
  ok('10b. una cuota vacía queda sin tope', u.v.cuota_diaria===null);
  ok('10c. guarda porcentaje y prioridad', u.v.porcentaje===60 && u.v.prioridad===2);

  await window.empGuardarModo('pool');
  ok('11. cambiar a pool libre se guarda en su ficha',
      window.__upd.some(x=>x.t==='clientes' && x.v.modo_reparto==='pool'));

  $('empPlazo').value='45'; $('empTope').value='3';
  await window.empGuardarFrenos();
  ok('11b. guarda sus propios frenos',
      window.__upd.some(x=>x.t==='clientes' && x.v.plazo_asignar_min===45 && x.v.tope_sin_asignar===3),
      JSON.stringify(window.__upd.filter(x=>x.t==='clientes')));

  await window.empResponder(3, true);
  ok('12. aceptar la solicitud llama a responder_vinculo',
      window.__rpc.some(r=>r.n==='responder_vinculo' && r.a.p_empresa_id===3 && r.a.p_cliente_id===1));

  await window.empPausar(2, true);
  ok('12b. reanudar una empresa la vuelve a activar',
      window.__upd.some(x=>x.t==='cliente_empresas' && x.v.activo===true));

  window.confirm = () => true;
  await window.empSacar(2);
  ok('12c. sacar una empresa la borra del vínculo', window.__del.some(d=>d.t==='cliente_empresas'));

  window.empTab('pedidos');
  ok('13. vuelve a sus pedidos sin perder nada', $('empVistaPedidos').style.display==='block' && $('empVistaEmpresas').style.display==='none');

  // ---------- 14. sin la migración corrida ----------
  eval("HAY_POOL = false; poolPedidos = []; pedidos = [{id:5,codigo:'ZAS-5',estado:'pendiente',cliente_nombre:'v',direccion:'x',fecha_pedido:'2026-08-03',creado_en:'2026-08-03T09:00:00Z'}];");
  eval("repartirPedidos([{id:7,codigo:'ZAS-7',estado:'pendiente'}])");
  ok('14. sin la migración, ningún pedido se va al pool por error', eval("pedidos.length===1 && poolPedidos.length===0"));

  // ---------- 15. RUT que ya está en la red ----------
  eval("clienteEditando = null; HAY_POOL = true;");
  document.getElementById('cNombre').value = 'Distribuidora Pepitos';
  document.getElementById('cRut').value    = '76.111.222-3';
  window.__insErr = { error:{ message:'duplicate key value violates unique constraint "idx_clientes_rut_unico"' } };
  await document.getElementById('cGuardar').onclick();
  const ce = document.getElementById('cErr');
  ok('15. si el RUT ya está en la red, no muestra el error de Postgres',
      !/duplicate key|idx_clientes_rut_unico/.test(ce.textContent), ce.textContent.slice(0,120));
  ok('15b. dice de quién es ese RUT', /Panader/.test(ce.textContent), ce.textContent.slice(0,140));
  ok('15c. explica que no hay que crearlo de nuevo', /No hay que crearlo de nuevo/.test(ce.textContent));
  ok('15d. ofrece el botón para pedírselo', /Pedirle trabajar con él/.test(ce.innerHTML));

  await window.pedirClienteDesdeFicha(7);
  ok('15e. el botón manda la solicitud', window.__rpc.filter(r=>r.n==='solicitar_cliente').length >= 2);
  ok('15f. y confirma que ahora decide el cliente', /tiene que aceptarla/.test(ce.textContent), ce.textContent);

  window.__insErr = { error:{ message:'duplicate key value violates unique constraint "idx_clientes_rut_unico"' } };
  document.getElementById('cRut').value = '77.777.777-7';   // ese ya es tuyo
  await document.getElementById('cGuardar').onclick();
  ok('15g. si ya es cliente tuyo, lo dice sin drama', /ya está en tu lista/.test(ce.textContent), ce.textContent.slice(0,120));

  window.__insErr = { error:{ message:'duplicate key value violates unique constraint "idx_clientes_rut_unico"' } };
  document.getElementById('cRut').value = '99.999.999-9';   // no está en la red
  await document.getElementById('cGuardar').onclick();
  ok('15h. si el RUT choca pero no aparece, avisa que lo revise',
      /Ya hay otro cliente con ese RUT/.test(ce.textContent), ce.textContent.slice(0,120));

  window.__insErr = null;

  return out;
});

await browser.close();
let malos = 0;
for (const t of r) { if (!t.ok) malos++; console.log((t.ok?'✅':'❌') + ' ' + t.n + (t.extra?('  ← '+t.extra):'')); }
if (errors.length) { console.log('\nERRORES DE LA PÁGINA:'); errors.forEach(e=>console.log('  '+e)); }
console.log(`\n${r.length - malos}/${r.length} pruebas OK` + (errors.length?` · ${errors.length} errores de página`:''));
process.exit(malos || errors.length ? 1 : 0);
