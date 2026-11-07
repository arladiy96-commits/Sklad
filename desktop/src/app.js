import QRCode from 'qrcode';
import JsBarcode from 'jsbarcode';
import {
  initialState,verifyState,importBackup,uid,fmt,number,codeOf,productByCode,itemError,
  invoiceLines,validateInvoice,setCatalogProduct,balance,currentCount,byStockId,byStockCode,
  addStockProduct,editStockProduct,addStockCode,removeStockCode,moveStock,startCount,
  setActual,finishCount,cancelCount,importCatalogToStock,parseOcrText,csv
} from './core.js';
import './style.css';

const DB='sklad-desktop-v1';
const $=q=>document.querySelector(q);
const esc=v=>String(v??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
const date=v=>v?new Date(v).toLocaleString('ru-RU',{day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit'}):'—';
const money=n=>fmt(n);
const icons={
  home:'<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  file:'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M8 13h8M8 17h8"/>',
  report:'<path d="M8 2h8l4 4v16H4V2z"/><path d="M8 10h8M8 14h8M8 18h5"/>',
  box:'<path d="m12 2 9 5-9 5-9-5 9-5zM3 7v10l9 5 9-5V7M12 12v10"/>',
  scan:'<path d="M4 8V4h4M16 4h4v4M20 16v4h-4M8 20H4v-4M4 12h16M8 9v6M12 9v6M16 9v6"/>',
  clock:'<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 3"/>',
  backup:'<path d="M12 3v12m-4-4 4 4 4-4M4 17v4h16v-4"/>',
  plus:'<path d="M12 5v14M5 12h14"/>',
  search:'<circle cx="11" cy="11" r="7"/><path d="m16 16 5 5"/>',
  print:'<path d="M6 9V3h12v6M6 18H4V9h16v9h-2M6 14h12v8H6z"/>',
  check:'<path d="m4 12 5 5L20 6"/>',
  menu:'<path d="M4 6h16M4 12h16M4 18h16"/>'
};
const ico=(name,cls='')=>'<svg class="ico '+cls+'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+(icons[name]||icons.box)+'</svg>';
const navItems=[
  ['home','Обзор','home'],['invoices','Накладные','file'],['report','Ведомость','report'],
  ['catalog','Справочник','box'],['stock','Инвентаризация','scan'],['history','История','clock'],
  ['settings','Данные и копии','backup']
];
let db,state,page='home',filter='',draft=null,imageUrl=null,camera=null,scanning=false;
const title={home:'Обзор склада',invoices:'Накладные',report:'Сборочная ведомость',
  catalog:'Справочник товаров',stock:'Инвентаризация',history:'История сборок',settings:'Данные и резервные копии'};

function dbOpen(){
  return new Promise((resolve,reject)=>{
    const req=indexedDB.open(DB,1);
    req.onupgradeneeded=()=>{const database=req.result;database.createObjectStore('state');database.createObjectStore('photos');};
    req.onsuccess=()=>resolve(req.result);
    req.onerror=()=>reject(req.error);
  });
}
function readStore(name,key) {
  return new Promise((resolve,reject)=>{
    const req=db.transaction(name,'readonly').objectStore(name).get(key);
    req.onsuccess=()=>resolve(req.result);
    req.onerror=()=>reject(req.error);
  });
}
function writeState(value,photo=null,deletePhotos=false){
  return new Promise((resolve,reject)=>{
    const tx=db.transaction(['state','photos'],'readwrite');
    tx.objectStore('state').put(value,'current');
    if(deletePhotos)tx.objectStore('photos').clear();
    if(photo)tx.objectStore('photos').put(photo.file,photo.id);
    tx.oncomplete=resolve;
    tx.onerror=()=>reject(tx.error);
    tx.onabort=()=>reject(tx.error||Error('Операция сохранения отменена'));
  });
}
let pendingMutation=Promise.resolve();
function change(callback,photo=null){
  const op=pendingMutation.then(async()=>{
    const candidate=structuredClone(state);
    const result=callback(candidate);
    verifyState(candidate);
    await writeState(candidate,photo);
    state=candidate;render();return result;
  });
  pendingMutation=op.catch(()=>{});
  return op;
}
function alertUser(message,fail=false){
  const root=$('#toast');
  root.textContent=message;root.classList.toggle('error',fail);root.classList.add('show');
  clearTimeout(alertUser.timeout);
  alertUser.timeout=setTimeout(()=>root.classList.remove('show'),3700);
}
const button=(caption,action,cls='btn',extra='')=>'<button type="button" class="'+cls+'" data-act="'+action+'" '+extra+'>'+caption+'</button>';
const empty=(head,desc,action,caption)=>'<div class="empty">'+ico('box')+'<h3>'+head+'</h3><p>'+desc+'</p>'+(action?button(caption,action,'btn primary'):'')+'</div>';
const metric=(label,value,foot)=>'<div class="metric"><span>'+esc(label)+'</span><strong>'+esc(value)+'</strong><small>'+esc(foot)+'</small></div>';
function nav(){
  return '<aside class="sidebar"><div class="brand"><div class="brand-icon">'+ico('box')+'</div><div>СКЛАД<small>DESKTOP / OFFLINE</small></div></div>'+
    '<div class="nav-label">РАБОЧЕЕ МЕСТО</div><nav>'+navItems.map(([key,name,ic])=>
      '<button class="nav-link '+(key===page?'selected':'')+'" data-act="nav" data-page="'+key+'">'+ico(ic)+'<span>'+name+'</span></button>').join('')+'</nav>'+
    '<div class="sidebar-bottom"><span class="status-dot"></span> Локальная база на этом ПК<br><small>Сервер не используется</small></div></aside>';
}
function header(){
  return '<header class="topbar"><div class="breadcrumb">СКЛАД <span>/</span> '+esc(title[page])+'</div>'+
    '<div class="topright"><span class="offline">'+ico('check')+' Данные на устройстве</span>'+
    '<span class="today">'+new Date().toLocaleDateString('ru-RU',{day:'numeric',month:'long',year:'numeric'})+'</span></div></header>';
}
function pageHeader(sub,actions=''){
  return '<div class="pagehead"><div><h1>'+esc(title[page])+'</h1><p>'+sub+'</p></div><div class="actions">'+actions+'</div></div>';
}
function rootView(){
  const pages={home:homeView,invoices:invoiceView,report:reportView,catalog:catalogView,
    stock:stockView,history:historyView,settings:settingsView};
  return pages[page]();
}
function render(){
  $('#app').innerHTML=nav()+'<main class="workspace">'+header()+'<div class="content">'+rootView()+'</div></main>';
}
function homeView(){
  const lines=invoiceLines(state),bags=lines.reduce((a,l)=>a+l.total,0);
  const active=currentCount(state.ledger);
  return pageHeader('Сводка текущей сборки и быстрые действия',
    button(ico('plus')+' Новая накладная','new-invoice','btn primary'))+
    '<div class="hero"><div><span class="eyebrow">ТЕКУЩАЯ СБОРКА</span><h2>'+bags+' <small>мешков к сборке</small></h2>'+
    '<p>По '+state.invoices.length+' накладным · '+lines.length+' наименований</p></div>'+
    '<div class="hero-actions">'+button('Открыть ведомость','goto-report','btn light')+
    button('Завершить сборку','finish-batch','btn outline-light')+'</div></div>'+
    '<div class="metrics">'+metric('Накладных',state.invoices.length,'В текущей сборке')+
    metric('Позиций',state.invoices.reduce((sum,i)=>sum+i.items.length,0),'Строк по всем накладным')+
    metric('Товаров на учёте',state.ledger.products.length,'Карточки инвентаризации')+
    metric('Пересчёт',active?'В работе':'Не открыт',active?Object.keys(active.actual).length+' проверено':'Остатки доступны')+'</div>'+
    '<div class="columns"><section class="panel"><div class="panelhead"><h3>Последние накладные</h3>'+
    button('Все накладные','goto-invoices','textbtn')+'</div>'+
    (state.invoices.length?'<div class="compact-list">'+[...state.invoices].reverse().slice(0,5).map(i=>
      '<button class="compact-item" data-act="edit-invoice" data-id="'+esc(i.id)+'">'+
      '<span class="icon-square">'+ico('file')+'</span><span><b>'+esc(i.number)+'</b><small>'+date(i.createdAt)+'</small></span>'+
      '<strong>'+i.items.length+' поз.</strong></button>').join('')+'</div>':
    empty('Пока нет накладных','Начни новую сборку с первой накладной','new-invoice','Создать'))+
    '</section><section class="panel"><div class="panelhead"><h3>Инвентаризация</h3>'+button('Перейти','goto-stock','textbtn')+'</div>'+
    '<div class="quick-stat"><span>Номенклатура</span><strong>'+state.ledger.products.length+'</strong></div>'+
    '<div class="quick-stat"><span>Движений товара</span><strong>'+state.ledger.movements.length+'</strong></div>'+
    '<div class="quick-stat"><span>Пересчётов</span><strong>'+state.ledger.counts.length+'</strong></div>'+
    '<p class="info">Накладные не списывают остатки автоматически. Учёт и сборка ведутся отдельно, как в Android-версии.</p></section></div>';
}
function invoiceView(){
  return pageHeader('Создавай накладные вручную или загружай фото для распознавания',
    button(ico('plus')+' Добавить накладную','new-invoice','btn primary'))+
    '<section class="panel"><div class="panelhead"><h3>Текущая сборка · '+state.invoices.length+'</h3>'+
    button('Завершить и в историю','finish-batch','btn ghost')+'</div>'+
    (state.invoices.length?'<div class="table-scroll"><table><thead><tr><th>Номер</th><th>Дата</th><th>Позиций</th><th>Мешков</th><th>Действия</th></tr></thead><tbody>'+
      [...state.invoices].reverse().map(i=>'<tr><td><b>'+esc(i.number)+'</b></td><td>'+date(i.createdAt)+'</td><td>'+i.items.length+'</td>'+
      '<td><strong>'+invoiceLines(state,[i]).reduce((sum,l)=>sum+l.total,0)+'</strong></td><td class="table-actions">'+
      button('Изменить','edit-invoice','btn mini','data-id="'+esc(i.id)+'"')+
      button('Удалить','delete-invoice','btn mini danger','data-id="'+esc(i.id)+'"')+'</td></tr>').join('')+
      '</tbody></table></div>':empty('Накладных пока нет','Можно внести строки вручную или добавить фотографию','new-invoice','Добавить накладную'))+
    '</section><div class="under-note">Повторяющиеся номера проверяются. Перед сохранением нужно подтвердить все строки.</div>';
}
function reportView(){
  const lines=invoiceLines(state),total=lines.reduce((sum,l)=>sum+l.total,0);
  return pageHeader('Сумма по каждой позиции со всеми слагаемыми',
    button(ico('print')+' Печать / PDF','print-report','btn primary')+
    button('CSV для Excel','csv-report','btn ghost'))+
    '<section class="panel print-area"><div class="sheet-header"><div class="sheet-tag">СКЛАД · ВЕДОМОСТЬ</div>'+
    '<h2>Сборочная ведомость</h2><p>Сформировано '+date(new Date().toISOString())+' · Накладных: '+state.invoices.length+'</p></div>'+
    (lines.length?'<div class="table-scroll"><table class="report-table"><thead><tr><th>№</th><th>Товар</th><th>Расчёт</th><th>Итого, меш.</th></tr></thead><tbody>'+
      lines.map((l,k)=>'<tr><td>'+(k+1)+'</td><td><b>'+esc(l.product.name)+'</b><small>'+esc(l.product.code)+'</small></td>'+
      '<td>'+l.additions.join(' + ')+'</td><td><strong>'+l.total+'</strong></td></tr>').join('')+
      '</tbody></table></div><div class="report-total"><span>ИТОГО МЕШКОВ</span><strong>'+total+'</strong></div>'+
      '<p class="signatures">Собрано: _____________________ &nbsp;&nbsp;&nbsp; Проверено: _____________________</p>':
      empty('Ведомость пустая','Добавь накладные, и таблица соберётся автоматически','new-invoice','Добавить накладную'))+
    '</section>';
}
function catalogView(){
  const list=[...state.catalog].filter(p=>(p.code+' '+p.name).toLowerCase().includes(filter.toLowerCase())).sort((a,b)=>a.name.localeCompare(b.name,'ru'));
  return pageHeader('Коды из накладных и вес одной упаковки',
    button(ico('plus')+' Добавить товар','add-catalog','btn primary'))+
    '<section class="panel"><div class="panelhead"><h3>Справочник · '+state.catalog.length+'</h3>'+
    '<label class="search">'+ico('search')+'<input id="catalog-search" placeholder="Название или код..." value="'+esc(filter)+'"></label></div>'+
    '<div class="table-scroll"><table><thead><tr><th>Код</th><th>Наименование</th><th>Фасовка</th><th>Состояние</th><th></th></tr></thead><tbody>'+
    list.map(p=>'<tr><td class="mono">'+esc(p.code)+'</td><td><b>'+esc(p.name)+'</b></td>'+
      '<td>'+fmt(p.bagWeightKg)+' кг</td><td><span class="pill '+(p.active?'good':'')+'">'+(p.active?'Активен':'Отключён')+'</span></td>'+
      '<td>'+button('Редактировать','edit-catalog','btn mini','data-id="'+esc(p.code)+'"')+'</td></tr>').join('')+
    '</tbody></table></div></section>';
}
function stockView(){
  const ledger=state.ledger,c=currentCount(ledger);
  const products=ledger.products.filter(p=>(p.name+' '+p.id+' '+p.codes.join(' ')).toLowerCase().includes(filter.toLowerCase()));
  return pageHeader('Карточки, заводские коды, остатки и пересчёт',
    button(ico('plus')+' Новый товар','add-stock','btn primary')+
    button('Скопировать из накладных','copy-catalog','btn ghost'))+
    '<div class="stock-banner '+(c?'active-count':'')+'"><div><b>'+(c?'Пересчёт '+esc(c.id)+' открыт':'Инвентаризация')+'</b>'+
    '<span>'+(c?'Проверено '+Object.keys(c.actual).length+' из '+Object.keys(c.expected).length+'. Приход и расход временно заблокированы.':'Открой пересчёт, чтобы сверить фактические остатки. Можно использовать USB-сканер.')+'</span></div>'+
    '<div class="actions">'+(c?button('Завершить пересчёт','finish-count','btn primary')+button('Отменить','cancel-count','btn ghost'):
      button('Начать пересчёт','start-count','btn primary'))+'</div></div>'+
    '<section class="panel"><div class="panelhead"><h3>Остатки · '+ledger.products.length+'</h3><div class="toolbar">'+
    '<label class="search">'+ico('scan')+'<input id="scan-input" placeholder="Сканируй или введи код ↵" autocomplete="off"></label>'+
    button('Камера','camera','btn ghost')+'</div></div>'+
    '<div class="panelpad smallpad"><label class="search wide">'+ico('search')+'<input id="stock-search" placeholder="Фильтр по товару, коду или месту..." value="'+esc(filter)+'"></label></div>'+
    (products.length?'<div class="table-scroll"><table><thead><tr><th>Карточка</th><th>Код</th><th>Остаток</th><th>Место</th><th>Действия</th></tr></thead><tbody>'+
    products.map(p=>'<tr><td><b>'+esc(p.name)+'</b><small>'+esc(p.category||'Без категории')+'</small></td>'+
    '<td class="mono">'+esc(p.id)+'</td><td><strong>'+fmt(balance(ledger,p.id))+' '+esc(p.unit)+'</strong>'+
    (c&&Object.hasOwn(c.expected,p.id)?'<small class="'+(Object.hasOwn(c.actual,p.id)?'success':'warn')+'">'+
    (Object.hasOwn(c.actual,p.id)?'Факт: '+fmt(c.actual[p.id]):'Не проверено')+'</small>':'')+'</td>'+
    '<td>'+esc(p.location||'—')+'</td><td class="table-actions">'+
    button(c?'Факт':'Приход / расход',c?'actual':'stock-move','btn mini','data-id="'+esc(p.id)+'"')+
    button('Карточка','stock-card','btn mini','data-id="'+esc(p.id)+'"')+'</td></tr>').join('')+
    '</tbody></table></div>':empty('Товары не найдены','Создай первую карточку или импортируй ассортимент накладных','add-stock','Добавить товар'))+
    '</section><section class="panel below"><div class="panelhead"><h3>Последние движения</h3></div>'+
    (ledger.movements.length?'<div class="table-scroll"><table><thead><tr><th>Дата</th><th>Товар</th><th>Операция</th><th>Количество</th><th>Комментарий</th></tr></thead><tbody>'+
    [...ledger.movements].reverse().slice(0,15).map(m=>'<tr><td>'+date(m.timestamp)+'</td><td>'+esc(byStockId(ledger,m.productId)?.name||m.productId)+'</td>'+
    '<td>'+esc(m.kind==='receipt'?'Приход':m.kind==='issue'?'Расход':'Корректировка')+'</td>'+
    '<td class="'+(m.delta>=0?'success':'warn')+'"><b>'+(m.delta>0?'+':'')+fmt(m.delta)+'</b></td><td>'+esc(m.note)+'</td></tr>').join('')+
    '</tbody></table></div>':'<p class="muted panelpad">Движений ещё нет</p>')+'</section>';
}
function historyView(){
  return pageHeader('Завершённые сборки и результаты инвентаризаций')+
    '<div class="columns"><section class="panel"><div class="panelhead"><h3>Сборки · '+state.batches.length+'</h3></div>'+
    (state.batches.length?state.batches.map((b,k)=>'<div class="history-row"><div><b>'+date(b.finishedAt)+'</b>'+
    '<small>'+b.invoices.length+' накладных · '+invoiceLines(state,b.invoices).reduce((sum,l)=>sum+l.total,0)+' мешков</small></div>'+
    button('Вернуть','restore-batch','btn mini','data-index="'+k+'"')+'</div>').join(''):
    '<p class="muted panelpad">Завершённых сборок нет</p>')+'</section>'+
    '<section class="panel"><div class="panelhead"><h3>Пересчёты · '+state.ledger.counts.length+'</h3></div>'+
    (state.ledger.counts.length?state.ledger.counts.map(c=>'<div class="history-row"><div><b>'+esc(c.id)+'</b>'+
    '<small>'+date(c.startedAt)+' · '+(c.cancelled?'Отменён':c.closedAt?'Завершён':'В работе')+
    ' · '+Object.keys(c.actual).length+' проверено</small></div>'+
    button('Отчёт CSV','csv-count','btn mini','data-id="'+esc(c.id)+'"')+'</div>').join(''):
    '<p class="muted panelpad">Пересчётов нет</p>')+'</section></div>';
}
function settingsView(){
  return pageHeader('Вся база хранится в браузере этого компьютера. Регулярно сохраняй копии.')+
    '<div class="columns"><section class="panel settings-card"><div class="panelhead"><h3>Полная резервная копия</h3></div>'+
    '<p>Каталог накладных, текущая сборка, история, инвентаризация и сохранённые фото. Один JSON-файл.</p>'+
    button(ico('backup')+' Скачать JSON','backup','btn primary')+
    '<label class="btn ghost file-label">Восстановить из JSON<input type="file" id="backup-input" accept=".json,application/json" hidden></label>'+
    '<p class="warning-note">Восстановление заменит существующую локальную базу. Операция требует подтверждения.</p></section>'+
    '<section class="panel settings-card"><div class="panelhead"><h3>Совместимость с Android</h3></div>'+
    '<p>Инвентаризация использует такой же формат <code>schemaVersion: 1</code>, как Android-приложение.</p>'+
    button('Скачать копию инвентаризации','backup-stock','btn ghost')+
    '<p class="info">Можно импортировать JSON-копию инвентаризации Android. Накладные и фото между устройствами автоматически не передаются.</p></section></div>'+
    '<div class="safety-note">'+ico('backup')+' Не очищай данные браузера и не удаляй PWA без копии. Локальная база браузера не равна отдельному файлу на диске. Для надёжного хранения регулярно экспортируй JSON.</div>';
}
function modal(html,wide=false){
  $('#modal').innerHTML='<div class="veil" data-act="close-modal"></div><section class="dialog '+(wide?'dialog-wide':'')+'">'+
    html+'</section>';
  $('#modal').classList.add('visible');
}
function closeModal(){
  stopCamera();
  $('#modal').classList.remove('visible');$('#modal').innerHTML='';
  if(imageUrl){URL.revokeObjectURL(imageUrl);imageUrl=null;}
  draft=null;
}
function modalHeader(heading,sub=''){
  return '<div class="dialog-head"><div><h2>'+esc(heading)+'</h2><p>'+esc(sub)+'</p></div>'+
    '<button type="button" class="close" data-act="close-modal">×</button></div>';
}
function modalFooter(label='Сохранить'){
  return '<div class="dialog-foot">'+button('Отмена','close-modal','btn ghost')+
    '<button class="btn primary" type="submit">'+label+'</button></div>';
}
function openInvoice(id){
  const old=id?state.invoices.find(i=>i.id===id):null;
  draft=old?structuredClone(old):{id:uid(),number:'',items:[],createdAt:new Date().toISOString()};
  draft.newPhoto=null;draft.verified=false;
  invoiceEditor();
  if(old)readStore('photos',old.id).then(blob=>{
    if(!blob||!draft||draft.id!==old.id)return;
    imageUrl=URL.createObjectURL(blob);
    const photo=$('#invoice-photo-preview');if(photo)photo.src=imageUrl;
  });
}
function invoiceEditor(){
  const content=modalHeader(draft.saved?'Редактировать накладную':state.invoices.some(i=>i.id===draft.id)?'Редактировать накладную':'Новая накладная',
    'Проверяй каждую строку по оригиналу — OCR может ошибиться')+
    '<form id="invoice-form"><div class="dialog-body"><div class="row two">'+
    '<label class="field">Номер накладной<input name="number" value="'+esc(draft.number)+'" placeholder="ТДБ..." required></label>'+
    '<label class="field">Фото накладной (JPG/PNG)<input id="invoice-photo" type="file" accept="image/png,image/jpeg,image/webp"></label></div>'+
    '<div class="photo-strip"><img id="invoice-photo-preview" '+(imageUrl?'src="'+imageUrl+'"':'')+' alt="Фото для сверки">'+
    '<div><b>Сканирование на компьютере</b><p>Загрузи снимок, затем попробуй локальное распознавание. Результат — черновик для ручной проверки.</p>'+
    button('Распознать фото','ocr','btn ghost',''+(!draft.newPhoto?'disabled':''))+'</div></div>'+
    '<div class="editor-row-head"><h3>Позиции · '+draft.items.length+'</h3>'+button(ico('plus')+' Добавить строку','add-row','btn mini')+'</div>'+
    '<div class="invoice-rows">'+draft.items.map((it,i)=>'<div class="invoice-line" data-index="'+i+'">'+
    '<div class="rowline"><span class="rownum">'+(i+1)+'</span>'+
    '<label class="field grow">Товар<select data-field="code" data-index="'+i+'">'+
    '<option value="">Выбери товар</option>'+state.catalog.filter(p=>p.active||p.code===it.code).map(p=>
    '<option value="'+esc(p.code)+'" '+(p.code===it.code?'selected':'')+'>'+esc(p.name)+' · '+esc(p.code)+'</option>').join('')+
    '</select></label>'+
    '<label class="field narrow">Кг<input data-field="kg" data-index="'+i+'" type="text" inputmode="decimal" value="'+esc(it.kg||'')+'"></label>'+
    '<span class="rowbag">'+(itemError(it,state)?'—':fmt(it.kg/productByCode(state,it.code).bagWeightKg)+' меш.')+'</span>'+
    button('×','remove-row','btn icon-danger','data-index="'+i+'"')+'</div>'+
    '<div class="row secondary-fields"><label class="field">Цена за кг<input data-field="price" data-index="'+i+'" value="'+esc(it.price??'')+'"></label>'+
    '<label class="field">Сумма<input data-field="amount" data-index="'+i+'" value="'+esc(it.amount??'')+'"></label>'+
    '<span class="line-hint">'+esc(itemError(it,state)||it.raw||'Проверено после заполнения')+'</span></div></div>').join('')+'</div>'+
    '<label class="checkboxline"><input id="verified" type="checkbox" '+(draft.verified?'checked':'')+'><span>Я сверил все позиции с бумажной накладной</span></label>'+
    '</div>'+modalFooter('Подтвердить и сохранить')+'</form>';
  modal(content,true);
}
function syncInvoice(){
  if(!draft)return;
  draft.number=$('#invoice-form [name=number]')?.value??draft.number;
  draft.verified=$('#verified')?.checked??false;
  document.querySelectorAll('.invoice-line').forEach(row=>{
    const i=Number(row.dataset.index);
    for(const el of row.querySelectorAll('[data-field]')){
      const key=el.dataset.field;
      draft.items[i][key]=key==='code'?codeOf(el.value):el.value.trim()===''?null:Number(String(el.value).replace(',','.'));
      if((key==='kg'||key==='price'||key==='amount') && !Number.isFinite(draft.items[i][key]))draft.items[i][key]=null;
    }
  });
}
function catalogModal(code=''){
  const p=state.catalog.find(v=>v.code===code);
  modal(modalHeader(p?'Изменить товар':'Новый товар','Справочник сборочных накладных')+
    '<form id="catalog-form" data-old="'+esc(code)+'"><div class="dialog-body">'+
    '<label class="field">Код H00000000<input required name="code" value="'+esc(p?.code||'')+'" placeholder="H00001955"></label>'+
    '<label class="field">Название<input required name="name" value="'+esc(p?.name||'')+'"></label>'+
    '<label class="field">Фасовка, кг<input required name="weight" value="'+esc(p?.bagWeightKg||'')+'" inputmode="decimal"></label>'+
    '<label class="checkboxline"><input type="checkbox" name="active" '+(p?.active===false?'':'checked')+'>Активный товар</label>'+
    '<label class="checkboxline"><input type="checkbox" name="confirmed" '+(p?.confirmedByWarehouse?'checked':'')+'>Код подтверждён складом</label>'+
    '</div>'+modalFooter()+'</form>');
}
function stockModal(id=''){
  const p=byStockId(state.ledger,id);
  modal(modalHeader(p?'Карточка товара':'Новая карточка',p?p.id:'Новый внутренний код назначится автоматически')+
    '<form id="stock-form" data-id="'+esc(id)+'"><div class="dialog-body">'+
    '<label class="field">Наименование<input required name="name" value="'+esc(p?.name||'')+'"></label>'+
    '<div class="row two"><label class="field">Единица измерения<select name="unit">'+
    ['шт.','кг','меш.','упак.','л'].map(v=>'<option '+(p?.unit===v?'selected':'')+'>'+v+'</option>').join('')+'</select></label>'+
    '<label class="field">Категория<input name="category" value="'+esc(p?.category||'')+'"></label></div>'+
    '<label class="field">Место хранения<input name="location" value="'+esc(p?.location||'')+'" placeholder="Склад, стеллаж..."></label>'+
    (p?'<label class="checkboxline"><input type="checkbox" name="active" '+(p.active?'checked':'')+'>Товар активен</label>':
      '<label class="field">Заводской штрихкод / QR (необязательно)<input name="code" placeholder="Сканируй USB-сканером"></label>')+
    (p?'<div class="codegroup"><b>Привязанные коды</b>'+p.codes.map(c=>
      '<div><span class="mono">'+esc(c)+'</span>'+(c===p.id?' · внутренний':
      button('Убрать','remove-code','btn mini danger','data-id="'+esc(p.id)+'" data-code="'+esc(c)+'"'))+'</div>').join('')+
      button('Привязать ещё код','add-code','btn ghost','data-id="'+esc(p.id)+'"')+
      button('Показать QR и штрихкод','label','btn ghost','data-id="'+esc(p.id)+'"')+'</div>':'')+
    '</div>'+modalFooter()+'</form>');
}
function movementModal(id){
  const p=byStockId(state.ledger,id);if(!p)return;
  modal(modalHeader('Движение товара',p.name+' · Остаток: '+fmt(balance(state.ledger,id))+' '+p.unit)+
    '<form id="move-form" data-id="'+esc(id)+'"><div class="dialog-body">'+
    '<label class="field">Операция<select name="kind"><option value="receipt">Приход</option>'+
    '<option value="issue">Расход</option></select></label>'+
    '<label class="field">Количество<input required autofocus name="qty" inputmode="decimal" placeholder="0"></label>'+
    '<label class="field">Примечание<input name="note" placeholder="Необязательно"></label></div>'+modalFooter('Провести')+'</form>');
}
function actualModal(id){
  const p=byStockId(state.ledger,id),c=currentCount(state.ledger);if(!p||!c)return;
  modal(modalHeader('Фактическое количество',p.name+' · Учёт: '+fmt(c.expected[id]??0)+' '+p.unit)+
    '<form id="actual-form" data-id="'+esc(id)+'"><div class="dialog-body">'+
    '<label class="field">Фактически <input required autofocus name="qty" inputmode="decimal" value="'+esc(c.actual[id]??'')+'" placeholder="0"></label>'+
    '<p class="info">Повторный ввод заменяет значение, а не прибавляет его. Непроверенные позиции не считаются нулевыми.</p>'+
    '</div>'+modalFooter('Записать факт')+'</form>');
}
function addCodeModal(id){
  const p=byStockId(state.ledger,id);if(!p)return;
  modal(modalHeader('Привязать код',p.name)+'<form id="code-form" data-id="'+esc(id)+'"><div class="dialog-body">'+
    '<label class="field">Штрихкод / QR<input autofocus required name="code" placeholder="Сканируй USB-сканером"></label></div>'+
    modalFooter('Привязать')+'</form>');
}
async function labelModal(id) {
  const p=byStockId(state.ledger,id);if(!p)return;
  modal(modalHeader('Этикетка товара',p.name)+'<div class="dialog-body label-box"><div id="label-print" class="label-print">'+
    '<h3>'+esc(p.name)+'</h3><canvas id="qr-canvas"></canvas><canvas id="bar-canvas"></canvas><b>'+esc(p.id)+'</b><span>'+esc(p.location)+'</span></div></div>'+
    '<div class="dialog-foot">'+button('Закрыть','close-modal','btn ghost')+button(ico('print')+' Печать этикетки','print-label','btn primary')+'</div>');
  try{
    await QRCode.toCanvas($('#qr-canvas'),p.id,{width:148,margin:1,color:{dark:'#132738',light:'#ffffff'}});
    JsBarcode('#bar-canvas',p.id,{format:'CODE128',displayValue:false,width:2,height:58,margin:3,lineColor:'#132738'});
  }catch(e){alertUser('Не удалось создать код: '+e.message,true);}
}
async function showPhoto(file){
  if(imageUrl)URL.revokeObjectURL(imageUrl);
  imageUrl=URL.createObjectURL(file);
  const preview=$('#invoice-photo-preview');if(preview)preview.src=imageUrl;
}
function fileDownload(name,content,type='application/json'){
  const url=URL.createObjectURL(new Blob([content],{type}));
  const link=document.createElement('a');link.href=url;link.download=name;document.body.append(link);link.click();link.remove();
  setTimeout(()=>URL.revokeObjectURL(url),1500);
}
async function allPhotos(){
  return new Promise((resolve,reject)=>{
    const tx=db.transaction('photos','readonly'),store=tx.objectStore('photos');
    const keys=store.getAllKeys(),values=store.getAll();
    tx.oncomplete=()=>resolve(keys.result.map((id,i)=>({id,blob:values.result[i]})));
    tx.onerror=()=>reject(tx.error);
  });
}
function blobDataURL(blob){return new Promise((resolve,reject)=>{
  const reader=new FileReader();reader.onload=()=>resolve(reader.result);
  reader.onerror=()=>reject(reader.error);reader.readAsDataURL(blob);
});}
async function restorePhotos(photos){
  if(!Array.isArray(photos)||!photos.length)return;
  await new Promise((resolve,reject)=>{
    const tx=db.transaction('photos','readwrite'),store=tx.objectStore('photos');
    for(const p of photos){
      if(typeof p.id!=='string'||typeof p.data!=='string'||!/^data:image\/(jpeg|png|webp);base64,/.test(p.data))continue;
      const [meta,encoded]=p.data.split(',');
      const raw=atob(encoded),bytes=new Uint8Array(raw.length);
      for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);
      store.put(new Blob([bytes],{type:meta.match(/data:(.*);base64/)[1]}),p.id);
    }
    tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);
  });
}
async function exportBackup(stockOnly){
  if(stockOnly){fileDownload('sklad_inventory_v1.json',JSON.stringify(state.ledger,null,2));return;}
  const photos=await allPhotos();
  const encoded=[];
  for(const p of photos)encoded.push({id:p.id,data:await blobDataURL(p.blob)});
  fileDownload('Sklad-Windows-backup-'+new Date().toISOString().slice(0,10)+'.json',
    JSON.stringify({...state,photos:encoded},null,2));
}
async function importFile(file){
  if(!file)return;
  const raw=await file.text();
  const parsed=JSON.parse(raw);
  const payload=importBackup(parsed);
  if(!confirm('Восстановить данные из копии? Существующая локальная база будет заменена.'))return;
  const candidate=payload.kind==='inventory'?{...state,ledger:payload.ledger}:
    Object.fromEntries(Object.entries(payload.state).filter(([key])=>key!=='photos'));
  verifyState(candidate);
  await writeState(candidate,null,payload.kind==='full');
  if(payload.kind==='full')await restorePhotos(parsed.photos);
  state=candidate;page='home';filter='';render();alertUser('Резервная копия восстановлена');
}
async function recognize(){
  if(!draft?.newPhoto)return alertUser('Сначала выбери фото накладной',true);
  syncInvoice();
  const source=draft.newPhoto;
  const buttonOCR=document.querySelector('[data-act=ocr]');
  if(buttonOCR){buttonOCR.disabled=true;buttonOCR.textContent='Распознаём на компьютере…';}
  try{
    const {createWorker}=await import('tesseract.js');
    const path=import.meta.env.BASE_URL+'ocr/';
    const worker=await createWorker('eng+rus',1,{langPath:path,workerPath:path+'worker.min.js',corePath:path,gzip:true});
    let result;
    try{result=await worker.recognize(source);}finally{await worker.terminate();}
    const parsed=parseOcrText(result.data.text);
    if(parsed.number&&!draft.number)draft.number=parsed.number;
    if(parsed.items.length)draft.items=parsed.items;
    alertUser(parsed.items.length?'Найдено строк: '+parsed.items.length+'. Проверь количество!':'Коды не найдены. Добавь строки вручную.',!parsed.items.length);
    invoiceEditor();
    if(imageUrl)$('#invoice-photo-preview').src=imageUrl;
  }catch(e){alertUser('OCR не сработал: '+e.message+'. Введи позиции вручную.',true);}
}
async function scanCode(raw){
  const code=String(raw??'').trim();if(!code)return;
  const p=byStockCode(state.ledger,code);
  if(p){currentCount(state.ledger)?actualModal(p.id):stockModal(p.id);}
  else{
    if(confirm('Код '+code+' не найден. Создать новый товар с этим кодом?')){
      stockModal();
      const field=$('#stock-form [name=code]');if(field)field.value=code;
    }
  }
}
async function startCamera(){
  if(!('BarcodeDetector' in window)){alertUser('В этом браузере камера для кодов недоступна. Используй USB-сканер или ввод кода.',true);return;}
  modal(modalHeader('Сканер', 'QR, Code 128 и EAN через камеру компьютера')+
    '<div class="dialog-body"><video class="video" id="camera-video" autoplay playsinline muted></video>'+
    '<p class="muted">Наведи камеру на код</p></div><div class="dialog-foot">'+button('Закрыть','close-modal','btn ghost')+'</div>');
  try{
    const formats=await BarcodeDetector.getSupportedFormats();
    const supported=['qr_code','code_128','ean_13','ean_8','upc_a'].filter(v=>formats.includes(v));
    if(!supported.length)throw Error('Браузер не поддерживает нужные форматы');
    const detector=new BarcodeDetector({formats:supported});
    const stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'}});
    camera={stream,timer:null};$('#camera-video').srcObject=stream;
    camera.timer=setInterval(async()=>{
      if(scanning||!camera)return;scanning=true;
      try{
        const video=$('#camera-video');
        if(video?.readyState>=2){
          const detected=await detector.detect(video);
          if(detected.length){
            const raw=detected[0].rawValue;closeModal();await scanCode(raw);
          }
        }
      }catch(e){/* Keep scanning until a readable frame is available. */}
      finally{scanning=false;}
    },330);
  }catch(e){closeModal();alertUser('Камера недоступна: '+e.message,true);}
}
function stopCamera(){
  if(camera){clearInterval(camera.timer);camera.stream?.getTracks().forEach(t=>t.stop());camera=null;}
}
async function handleAction(target){
  const action=target.dataset.act,id=target.dataset.id;
  switch(action){
    case 'nav':page=target.dataset.page;filter='';render();break;
    case 'goto-invoices':page='invoices';render();break;
    case 'goto-report':page='report';render();break;
    case 'goto-stock':page='stock';render();break;
    case 'new-invoice':openInvoice();break;
    case 'edit-invoice':openInvoice(id);break;
    case 'delete-invoice':
      if(confirm('Удалить накладную из текущей сборки?'))await change(s=>{s.invoices=s.invoices.filter(v=>v.id!==id);});
      break;
    case 'add-row':syncInvoice();draft.items.push({code:'',kg:0,price:null,amount:null,raw:''});invoiceEditor();if(imageUrl)$('#invoice-photo-preview').src=imageUrl;break;
    case 'remove-row':syncInvoice();draft.items.splice(Number(target.dataset.index),1);invoiceEditor();if(imageUrl)$('#invoice-photo-preview').src=imageUrl;break;
    case 'finish-batch':
      if(!state.invoices.length)return alertUser('Нет накладных для завершения',true);
      if(confirm('Завершить текущую сборку? Накладные перейдут в историю.'))await change(s=>{
        s.batches.unshift({finishedAt:new Date().toISOString(),invoices:s.invoices});
        s.invoices=[];
      });break;
    case 'restore-batch':
      if(state.invoices.length)return alertUser('Сначала заверши текущую сборку',true);
      await change(s=>{const b=s.batches.splice(Number(target.dataset.index),1)[0];s.invoices=b.invoices;});
      page='invoices';render();break;
    case 'add-catalog':catalogModal();break;
    case 'edit-catalog':catalogModal(id);break;
    case 'add-stock':stockModal();break;
    case 'stock-card':stockModal(id);break;
    case 'stock-move':movementModal(id);break;
    case 'actual':actualModal(id);break;
    case 'copy-catalog':{
      const count=await change(s=>importCatalogToStock(s));
      alertUser('Добавлено карточек: '+count);break;
    }
    case 'add-code':addCodeModal(id);break;
    case 'remove-code':
      if(confirm('Убрать привязку '+target.dataset.code+'?')){
        await change(s=>removeStockCode(s.ledger,id,target.dataset.code));stockModal(id);
      }break;
    case 'label':await labelModal(id);break;
    case 'print-label':window.print();break;
    case 'print-report':window.print();break;
    case 'csv-report':{
      const lines=invoiceLines(state);
      fileDownload('sklad-vedomost.csv',csv([['Код','Товар','Слагаемые, меш.','Итого, меш.'],
        ...lines.map(l=>[l.product.code,l.product.name,l.additions.join(' + '),l.total])]),'text/csv;charset=utf-8');break;
    }
    case 'csv-count':{
      const c=state.ledger.counts.find(v=>v.id===id);if(!c)return;
      fileDownload('inventory-'+c.id+'.csv',csv([['Товар','Код','Ед.','Учёт','Факт','Разница','Место'],
        ...Object.entries(c.actual).map(([p,v])=>{
          const item=byStockId(state.ledger,p);
          return [item?.name||'',p,item?.unit||'',c.expected[p],v,v-c.expected[p],item?.location||''];
        })]),'text/csv;charset=utf-8');break;
    }
    case 'start-count':await change(s=>startCount(s.ledger));break;
    case 'cancel-count':
      if(confirm('Отменить пересчёт? Остатки не изменятся.'))await change(s=>cancelCount(s.ledger));break;
    case 'finish-count':
      if(!currentCount(state.ledger)?.actual||Object.keys(currentCount(state.ledger).actual).length===0){
        return alertUser('Сначала проверь хотя бы один товар',true);
      }
      modal(modalHeader('Завершить пересчёт','Выбери, что сделать с расхождениями')+
        '<div class="dialog-body"><p>Проверено: '+Object.keys(currentCount(state.ledger).actual).length+' позиций. Непроверенные товары останутся без изменений.</p>'+
        '<div class="end-buttons">'+button('Применить фактические остатки','apply-count','btn primary')+
        button('Завершить только с отчётом','report-count','btn ghost')+'</div></div>');break;
    case 'apply-count':await change(s=>finishCount(s.ledger,true));closeModal();alertUser('Остатки скорректированы');break;
    case 'report-count':await change(s=>finishCount(s.ledger,false));closeModal();alertUser('Пересчёт закрыт без изменения остатков');break;
    case 'backup':await exportBackup(false);alertUser('Копия скачана — сохрани её отдельно');break;
    case 'backup-stock':await exportBackup(true);alertUser('JSON инвентаризации скачан');break;
    case 'camera':await startCamera();break;
    case 'close-modal':closeModal();break;
    case 'ocr':await recognize();break;
  }
}
async function handleSubmit(form){
  const fd=new FormData(form);
  switch(form.id){
    case 'invoice-form':{
      syncInvoice();
      if(!draft.verified)throw Error('Сначала отметь подтверждение всех строк');
      const invoice={id:draft.id,number:draft.number.trim(),createdAt:draft.createdAt,items:draft.items};
      validateInvoice(state,invoice,draft.id);
      const file=draft.newPhoto;
      await change(s=>{
        s.invoices=s.invoices.filter(i=>i.id!==invoice.id);
        s.invoices.push(invoice);
      },file?{id:invoice.id,file}:null);
      closeModal();alertUser('Накладная сохранена');break;
    }
    case 'catalog-form':{
      await change(s=>setCatalogProduct(s,{oldCode:form.dataset.old||undefined,code:fd.get('code'),
        name:fd.get('name'),bagWeightKg:Number(String(fd.get('weight')).replace(',','.')),
        active:fd.has('active'),confirmedByWarehouse:fd.has('confirmed')}));
      closeModal();alertUser('Справочник обновлён');break;
    }
    case 'stock-form':{
      const fields={name:fd.get('name'),unit:fd.get('unit'),location:fd.get('location'),
        category:fd.get('category'),code:fd.get('code'),active:fd.has('active')};
      await change(s=>{
        if(form.dataset.id)editStockProduct(s.ledger,form.dataset.id,fields);
        else addStockProduct(s.ledger,fields);
      });
      closeModal();alertUser('Карточка сохранена');break;
    }
    case 'move-form':
      await change(s=>moveStock(s.ledger,form.dataset.id,fd.get('qty'),fd.get('kind')==='receipt',fd.get('note')));
      closeModal();alertUser('Движение записано');break;
    case 'actual-form':
      await change(s=>setActual(s.ledger,form.dataset.id,fd.get('qty')));
      closeModal();alertUser('Факт записан');break;
    case 'code-form':
      await change(s=>addStockCode(s.ledger,form.dataset.id,fd.get('code')));
      closeModal();alertUser('Код привязан');break;
  }
}
document.addEventListener('click',async event=>{
  const target=event.target.closest('[data-act]');if(!target)return;
  if(target.disabled)return;
  // Overlay click closes the dialog; controls in dialog do not bubble to the overlay.
  try{await handleAction(target);}catch(error){alertUser(error.message||String(error),true);console.error(error);}
});
document.addEventListener('submit',async event=>{
  if(!event.target.id)return;
  event.preventDefault();
  const submit=event.target.querySelector('[type=submit]');if(submit)submit.disabled=true;
  try{await handleSubmit(event.target);}catch(error){alertUser(error.message||String(error),true);}
  finally{if(submit?.isConnected)submit.disabled=false;}
});
document.addEventListener('input',event=>{
  if(event.target.id==='catalog-search'||event.target.id==='stock-search'){
    filter=event.target.value;
    const inputId=event.target.id,pos=event.target.selectionStart;
    render();const el=document.getElementById(inputId);el?.focus();el?.setSelectionRange(pos,pos);
  }
});
document.addEventListener('change',async event=>{
  if(event.target.id==='invoice-photo'){
    const file=event.target.files[0];if(!file)return;
    if(!file.type.startsWith('image/'))return alertUser('Выбери изображение',true);
    if(file.size>25*1024*1024)return alertUser('Фото больше 25 МБ',true);
    draft.newPhoto=file;await showPhoto(file);
    const buttonOCR=document.querySelector('[data-act=ocr]');if(buttonOCR)buttonOCR.disabled=false;
  }
  if(event.target.id==='backup-input'){
    try{await importFile(event.target.files[0]);}catch(e){alertUser('Ошибка восстановления: '+e.message,true);}
    event.target.value='';
  }
});
document.addEventListener('keydown',async event=>{
  if(event.target.id!=='scan-input'||event.key!=='Enter')return;
  event.preventDefault();
  const code=event.target.value;event.target.value='';
  try{await scanCode(code);}catch(e){alertUser(e.message,true);}
});
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&$('#modal').classList.contains('visible'))closeModal();
});
async function init(){
  try{
    db=await dbOpen();
    state=await readStore('state','current')||initialState();
    verifyState(state);
    if(navigator.storage?.persist)navigator.storage.persist().catch(()=>{});
    render();
  }catch(error){
    document.querySelector('#app').innerHTML='<div class="fatal"><h2>Не удалось открыть базу Склада</h2><p>'+esc(error.message)+'</p>'+
      '<p>Данные не удалены. Не очищай браузер и не переустанавливай приложение без резервной копии.</p></div>';
  }
}
init();
