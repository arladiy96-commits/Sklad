// Windows PWA domain logic. No network, framework or browser dependency.
export const SEED_CATALOG = [
  ['H00001955','Мука Тамерлан, 1 сорт, 25 кг',25],
  ['H00001950','Мука Тамерлан, высший сорт, 25 кг',25],
  ['H00001952','Мука Тамерлан, высший сорт, 10 кг',10],
  ['H00001957','Мука Тамерлан, 1 сорт, 5 кг',5],
  ['H00001953','Мука Тамерлан, высший сорт, 5 кг',5],
  ['H00003422','Мука Беляевская, высший сорт, 5 кг',5],
  ['H00003423','Мука Беляевская, высший сорт, 10 кг',10]
].map(([code,name,bagWeightKg]) => ({code,name,bagWeightKg,active:true,confirmedByWarehouse:false}));

export const initialState = () => ({
  version:1,
  catalog:structuredClone(SEED_CATALOG),
  invoices:[],
  batches:[],
  ledger:{schemaVersion:1,sequence:0,products:[],movements:[],counts:[]}
});
export const round = n => Math.round((Number(n) + Number.EPSILON) * 1000) / 1000;
export const number = n => {
  if (typeof n === 'number') return Number.isFinite(n) ? n : NaN;
  const s=String(n??'').trim().replace(/\s/g,'').replace(',','.');
  return /^\d+(?:\.\d{1,3})?$/.test(s) ? Number(s) : NaN;
};
export const fmt = n => new Intl.NumberFormat('ru-RU',{maximumFractionDigits:3}).format(n);
export const codeOf = raw => {
  const value=String(raw??'').toUpperCase().replace(/Н/g,'H').replace(/О/g,'0').replace(/[\s_-]/g,'');
  return value.startsWith('H') ? 'H'+value.slice(1).replace(/O/g,'0') : value;
};
export const uid = () => globalThis.crypto?.randomUUID?.() ?? String(Date.now())+String(Math.random());
const timestamp = () => new Date().toISOString();
const assert = (condition,message) => { if(!condition) throw Error(message); };
export const productByCode = (state,code) => state.catalog.find(p=>p.code===codeOf(code));
export const itemError = (item,state) => {
  const p=productByCode(state,item.code);
  if(!p)return 'Код не найден в справочнике';
  if(!p.active)return 'Товар отключён';
  if(!Number.isFinite(item.kg)||item.kg<=0)return 'Укажи количество в кг';
  if(!Number.isFinite(p.bagWeightKg)||p.bagWeightKg<=0)return 'Некорректная фасовка';
  const bags=item.kg/p.bagWeightKg;
  if(Math.abs(bags-Math.round(bags))>0.0001)return 'Вес не кратен фасовке';
  if(item.price!=null && item.amount!=null && Math.abs(item.kg*item.price-item.amount)>0.03)
    return 'Цена × количество не совпадает с суммой';
  return null;
};
export function invoiceLines(state,invoices=state.invoices) {
  const map=new Map();
  for(const inv of invoices)for(const item of inv.items){
    if(itemError(item,state))continue;
    const p=productByCode(state,item.code);
    const bags=Math.round(item.kg/p.bagWeightKg);
    if(!map.has(p.code))map.set(p.code,{product:p,additions:[],total:0});
    const line=map.get(p.code);line.additions.push(bags);line.total+=bags;
  }
  return [...map.values()].sort((a,b)=>a.product.name.localeCompare(b.product.name,'ru'));
}
export function validateInvoice(state,invoice,excludedId=null) {
  assert(invoice.items?.length>0,'Добавь хотя бы одну позицию');
  const num=String(invoice.number??'').trim();
  assert(num.length>0,'Укажи номер накладной');
  assert(!state.invoices.some(i=>i.id!==excludedId && i.number.trim().toLowerCase()===num.toLowerCase()),'Номер накладной уже существует в текущей сборке');
  invoice.items.forEach((item,index)=>{
    const problem=itemError(item,state);
    if(problem)throw Error('Строка '+(index+1)+': '+problem);
  });
}
export function parseOcrText(raw) {
  const text=String(raw||'');
  const numberMatch=text.toUpperCase().replace(/\s/g,'').match(/ТДБ\d{7,11}/);
  const items=[];
  // Never treat the digits of H00001955 as a quantity. OCR is only a draft.
  for(const line of text.split(/\r?\n/)){
    const normalized=line.toUpperCase().replace(/Н/g,'H').replace(/О/g,'0');
    const match=normalized.match(/H\d{8}/);
    if(!match)continue;
    const code=match[0];
    const suffix=normalized.slice(match.index+code.length);
    const possible=suffix.split(/[|;\t ]+/).map(v=>v.replace(/(кг|kg)$/i,'')).filter(Boolean);
    const kgCandidate=possible.find(v=>/^\d{1,5}(?:[.,]\d{1,2})?$/.test(v) && Number(v.replace(',','.'))>0);
    items.push({code,kg:kgCandidate?Number(kgCandidate.replace(',','.')):0,price:null,amount:null,raw:line});
  }
  return {number:numberMatch?.[0]||'',items};
}
export function setCatalogProduct(state,{oldCode,code,name,bagWeightKg,active=true,confirmedByWarehouse=false}) {
  code=codeOf(code);name=String(name??'').trim();bagWeightKg=Number(bagWeightKg);
  assert(/^H\d{8}$/.test(code),'Код должен выглядеть как H00001955');
  assert(name && name.length<=150,'Укажи название товара');
  assert(bagWeightKg>0 && Number.isFinite(bagWeightKg),'Укажи фасовку, кг');
  assert(!state.catalog.some(p=>p.code===code && p.code!==oldCode),'Код уже занят');
  if(oldCode && oldCode!==code) {
    assert(!state.invoices.some(i=>i.items.some(x=>codeOf(x.code)===oldCode)) &&
      !state.batches.some(b=>b.invoices.some(i=>i.items.some(x=>codeOf(x.code)===oldCode))),
      'Нельзя изменить код товара, использованный в накладных');
  }
  const product={code,name,bagWeightKg,active,confirmedByWarehouse};
  const index=state.catalog.findIndex(p=>p.code===oldCode);
  if(index<0)state.catalog.push(product);else state.catalog[index]=product;
}
export const balance = (ledger,id) => round(ledger.movements.filter(m=>m.productId===id).reduce((sum,m)=>sum+m.delta,0));
export const currentCount = ledger => ledger.counts.find(c=>!c.closedAt&&!c.cancelled);
export const byStockId = (ledger,id) => ledger.products.find(p=>p.id===id);
export const byStockCode = (ledger,raw) => ledger.products.find(p=>p.codes.includes(String(raw??'').trim()));
function nextId(ledger,prefix){ledger.sequence++;return prefix+'-'+String(ledger.sequence).padStart(6,'0');}
function checkStockCode(ledger,value,owner){
  const code=String(value??'').trim();
  assert(code.length>0 && code.length<=128 && !/[\x00-\x1f]/.test(code),'Неверный код товара');
  const duplicate=byStockCode(ledger,code);
  assert(!duplicate||duplicate.id===owner,'Код уже привязан к товару: '+duplicate?.name);
  return code;
}
export function addStockProduct(ledger,fields){
  const name=String(fields.name??'').trim(),unit=String(fields.unit??'').trim();
  assert(name.length>0 && name.length<=150 && unit,'Укажи название и единицу измерения');
  const code=fields.code ? checkStockCode(ledger,fields.code) : '';
  let id=nextId(ledger,'SK');
  while(byStockCode(ledger,id))id=nextId(ledger,'SK');
  const p={id,name,unit,location:String(fields.location??'').trim(),category:String(fields.category??'').trim(),codes:[id],active:true};
  if(code&&code!==id)p.codes.push(code);
  ledger.products.push(p);
  const current=currentCount(ledger);
  if(current)current.expected[id]=0;
  return p;
}
export function editStockProduct(ledger,id,fields) {
  const p=byStockId(ledger,id);
  assert(p,'Товар не найден');
  const name=String(fields.name??'').trim(),unit=String(fields.unit??'').trim();
  assert(name && unit,'Укажи название и единицу измерения');
  assert(p.unit===unit||!(ledger.movements.some(m=>m.productId===id)||ledger.counts.some(c=>Object.hasOwn(c.expected,id))),'Единицу товара с историей нельзя изменить');
  Object.assign(p,{name,unit,location:String(fields.location??'').trim(),category:String(fields.category??'').trim(),active:fields.active!==false});
  return p;
}
export function addStockCode(ledger,id,value) {
  const p=byStockId(ledger,id);
  assert(p,'Товар не найден');
  const code=checkStockCode(ledger,value,id);
  if(!p.codes.includes(code))p.codes.push(code);
}
export function removeStockCode(ledger,id,value) {
  const p=byStockId(ledger,id);assert(p,'Товар не найден');
  assert(value!==id,'Нельзя удалить внутренний код');
  p.codes=p.codes.filter(c=>c!==value);
}
export function moveStock(ledger,id,raw,receipt,note='') {
  assert(!currentCount(ledger),'Сначала заверши инвентаризацию');
  const p=byStockId(ledger,id);
  assert(p&&p.active,'Товар не найден или отключён');
  const qty=number(raw);
  assert(Number.isFinite(qty)&&qty>0&&qty<=1e9,'Количество должно быть больше нуля, максимум 3 знака после запятой');
  if(!receipt)assert(balance(ledger,id)+0.00001>=qty,'Недостаточно остатка');
  const m={id:nextId(ledger,'MV'),productId:id,kind:receipt?'receipt':'issue',timestamp:timestamp(),delta:receipt?qty:-qty,note:String(note??'').trim()};
  ledger.movements.push(m);return m;
}
export function startCount(ledger){
  assert(!currentCount(ledger),'Пересчёт уже открыт');
  const expected=Object.fromEntries(ledger.products.filter(p=>p.active).map(p=>[p.id,balance(ledger,p.id)]));
  assert(Object.keys(expected).length>0,'Сначала добавь товар');
  const c={id:nextId(ledger,'IV'),startedAt:timestamp(),closedAt:null,cancelled:false,expected,actual:{}};
  ledger.counts.unshift(c);return c;
}
export function setActual(ledger,id,raw){
  const c=currentCount(ledger);assert(c,'Нет открытой инвентаризации');
  assert(Object.hasOwn(c.expected,id),'Товар вне инвентаризации');
  const value=number(raw);
  assert(Number.isFinite(value)&&value>=0&&value<=1e9,'Введи количество от нуля, до 3 знаков после запятой');
  c.actual[id]=value;
}
export function finishCount(ledger,apply){
  const c=currentCount(ledger);assert(c,'Нет открытой инвентаризации');
  assert(Object.keys(c.actual).length>0,'Сначала проверь хотя бы один товар');
  if(apply)for(const [id,actual] of Object.entries(c.actual)){
    const delta=round(actual-balance(ledger,id));
    if(delta)ledger.movements.push({id:nextId(ledger,'MV'),productId:id,kind:'inventory',
      timestamp:timestamp(),delta,note:'Корректировка инвентаризации '+c.id});
  }
  c.closedAt=timestamp();return c;
}
export function cancelCount(ledger){
  const c=currentCount(ledger);assert(c,'Нет открытой инвентаризации');c.cancelled=true;
}
export function importCatalogToStock(state){
  let count=0;
  for(const p of state.catalog){
    if(byStockCode(state.ledger,p.code))continue;
    addStockProduct(state.ledger,{name:p.name,unit:'меш.',category:'Мука',code:p.code});
    count++;
  }
  return count;
}
export function verifyLedger(ledger){
  assert(ledger?.schemaVersion===1 && Array.isArray(ledger.products) &&
    Array.isArray(ledger.movements) && Array.isArray(ledger.counts) &&
    Number.isSafeInteger(ledger.sequence),'Неизвестный формат базы инвентаризации');
  const ids=new Set(),codes=new Set();
  for(const p of ledger.products){
    assert(typeof p.id==='string' && p.id.length && !ids.has(p.id)&&
      typeof p.name==='string'&&p.name.trim()&&Array.isArray(p.codes)&&p.codes.includes(p.id),'Повреждён каталог товаров');
    ids.add(p.id);
    for(const code of p.codes){
      assert(typeof code==='string'&&!codes.has(code),'Один код привязан к двум товарам');
      codes.add(code);
    }
  }
  for(const m of ledger.movements)assert(ids.has(m.productId)&&Number.isFinite(m.delta),'Повреждён журнал движений');
  assert(ledger.counts.filter(c=>!c.closedAt&&!c.cancelled).length<=1,'Несколько открытых инвентаризаций');
  for(const c of ledger.counts){
    assert(c.expected&&c.actual&&Object.keys(c.actual).every(id=>Object.hasOwn(c.expected,id)),'Повреждена инвентаризация');
  }
}
export function verifyState(state){
  assert(state?.version===1&&Array.isArray(state.catalog)&&Array.isArray(state.invoices)&&
    Array.isArray(state.batches),'Неподдерживаемая версия резервной копии');
  const seen=new Set();
  for(const p of state.catalog){
    assert(p.code&&typeof p.name==='string'&&Number(p.bagWeightKg)>0&&!seen.has(p.code),'Повреждён справочник');
    seen.add(p.code);
  }
  for(const inv of [...state.invoices,...state.batches.flatMap(b=>b.invoices||[])]){
    assert(typeof inv.id==='string'&&typeof inv.number==='string'&&Array.isArray(inv.items),'Повреждена накладная');
  }
  verifyLedger(state.ledger);
}
export function importBackup(json){
  const v=typeof json==='string'?JSON.parse(json):json;
  if(v?.schemaVersion===1&&!('version' in v)){
    verifyLedger(v);
    return {kind:'inventory',ledger:v};
  }
  verifyState(v);
  return {kind:'full',state:v};
}
export function csv(rows){
  return '\uFEFF'+rows.map(r=>r.map(v=>{
    let s=String(v??'');
    if(typeof v!=='number' && /^[\s]*[=+\-@]/.test(s))s="'"+s; // Preserve numeric negative quantities.
    return '"'+s.replaceAll('"','""')+'"';
  }).join(';')).join('\r\n');
}
