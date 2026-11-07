import test from 'node:test';
import assert from 'node:assert/strict';
import {initialState,validateInvoice,invoiceLines,addStockProduct,moveStock,startCount,
  setActual,finishCount,balance,addStockCode,verifyState,importBackup,parseOcrText} from '../src/core.js';

test('invoice converts kilograms into bags and detects duplicates',()=>{
  const s=initialState();
  const inv={id:'1',number:'ТДБ123',items:[{code:'Н00001955',kg:50}]};
  validateInvoice(s,inv);
  s.invoices.push({...inv,items:[{code:'H00001955',kg:50}]});
  assert.equal(invoiceLines(s)[0].total,2);
  assert.throws(()=>validateInvoice(s,{...inv,id:'2'}),/существует/);
  assert.throws(()=>validateInvoice(s,{id:'3',number:'3',items:[{code:'H00001955',kg:43}]}),/не кратен/);
});
test('inventory receives, issues, blocks during count and reconciles',()=>{
  const s=initialState(),l=s.ledger;
  const p=addStockProduct(l,{name:'Товар',unit:'шт.',code:'4601234567890'});
  addStockCode(l,p.id,'QR-CODE');
  assert.equal(p.codes.length,3);
  moveStock(l,p.id,'10',true,'Приход');
  moveStock(l,p.id,'2',false,'Выдача');
  assert.equal(balance(l,p.id),8);
  startCount(l);
  assert.throws(()=>moveStock(l,p.id,1,false),/заверши/);
  setActual(l,p.id,'6,5');
  finishCount(l,true);
  assert.equal(balance(l,p.id),6.5);
  verifyState(s);
  assert.equal(importBackup(JSON.stringify(l)).kind,'inventory');
});
test('count only corrects scanned lines',()=>{
  const l=initialState().ledger;
  const a=addStockProduct(l,{name:'A',unit:'шт.'});
  const b=addStockProduct(l,{name:'B',unit:'шт.'});
  moveStock(l,a.id,10,true);moveStock(l,b.id,7,true);
  startCount(l);setActual(l,a.id,8);finishCount(l,true);
  assert.equal(balance(l,a.id),8);
  assert.equal(balance(l,b.id),7);
});
test('OCR never reads the product code as kilograms',()=>{
  const parsed=parseOcrText('ТДБ123456789\nH00001955   50   150   7500\nH00001950');
  assert.equal(parsed.items.length,2);
  assert.equal(parsed.items[0].kg,50);
  assert.equal(parsed.items[1].kg,0);
});
