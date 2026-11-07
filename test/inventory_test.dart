import 'package:flutter_test/flutter_test.dart';
import 'package:sklad/inventory_model.dart';

void main(){
  test('An existing factory barcode and our QR resolve to one product',(){
    final stock=StockLedger();
    final item=stock.addProduct(name:'Подшипник 6205',unit:'шт',
      category:'Запчасти',location:'Стеллаж 2',scannedCode:'4871234567890');
    expect(stock.byCode('4871234567890')?.id,item.id);
    expect(stock.byCode(item.id)?.id,item.id);
    stock.addCode(item.id,'FACTORY-6205');
    expect(stock.byCode('FACTORY-6205')?.id,item.id);
    expect(()=>stock.addProduct(name:'Дубликат',unit:'шт',
      scannedCode:'4871234567890'),throwsStateError);
    expect(()=>stock.addCode(item.id,'FACTORY-6205'),returnsNormally);
    expect(stock.products.length,1);
  });
  test('Receipts and issues create an audit trail and block negative stock',(){
    final stock=StockLedger();
    final item=stock.addProduct(name:'Ремень',unit:'шт');
    stock.move(item.id,12,receipt:true,note:'Приёмка');
    stock.move(item.id,5,receipt:false,note:'Выдали инженеру');
    expect(stock.balance(item.id),7);
    expect(stock.movements.length,2);
    expect(stock.movements.last.note,'Выдали инженеру');
    expect(()=>stock.move(item.id,8,receipt:false),throwsStateError);
    expect(()=>stock.move(item.id,0,receipt:true),throwsFormatException);
    expect(stock.balance(item.id),7);
  });
  test('Count snapshot, scanned quantities and apply adjustments',(){
    final stock=StockLedger();
    final a=stock.addProduct(name:'Подшипник',unit:'шт');
    final b=stock.addProduct(name:'Мешки',unit:'шт');
    stock.move(a.id,20,receipt:true);
    stock.move(b.id,10,receipt:true);
    final count=stock.startCount();
    expect(count.expected[a.id],20);
    expect(count.expected[b.id],10);
    expect(()=>stock.move(a.id,1,receipt:false),throwsStateError);
    stock.setActual(a.id,17);
    stock.setActual(a.id,18); // repeat scan does not increment
    expect(count.checked,1);
    stock.finishCount(apply:true);
    expect(stock.current,isNull);
    expect(stock.balance(a.id),18);
    expect(stock.balance(b.id),10); // unscanned goods untouched
    expect(count.difference(a.id),-2);
    expect(stock.movements.last.kind,'inventory');
  });
  test('Count can close without applying discrepancies',(){
    final stock=StockLedger();
    final item=stock.addProduct(name:'Тара',unit:'шт');
    stock.move(item.id,7,receipt:true);
    final count=stock.startCount();
    stock.setActual(item.id,2);
    stock.finishCount(apply:false);
    expect(stock.balance(item.id),7);
    expect(count.difference(item.id),-5);
    expect(count.closedAt,isNotNull);
  });
  test('Cancelled count preserves ledger, permits fresh counts',(){
    final stock=StockLedger();
    final p=stock.addProduct(name:'Плёнка',unit:'кг');
    final count=stock.startCount();
    stock.setActual(p.id,0);
    stock.cancelCount();
    expect(count.cancelled,isTrue);
    expect(stock.current,isNull);
    expect(stock.startCount().isOpen,isTrue);
  });
  test('Snapshot and barcodes survive export/import without loss',(){
    final stock=StockLedger();
    final p=stock.addProduct(name:'Мука',unit:'меш.',
      scannedCode:'4600123456789');
    stock.move(p.id,10.5,receipt:true);
    final count=stock.startCount();
    stock.setActual(p.id,10);
    stock.finishCount(apply:true);
    final restored=StockLedger.decode(stock.encode());
    expect(restored.byCode('4600123456789')?.name,'Мука');
    expect(restored.balance(p.id),10);
    expect(restored.counts.single.actual[p.id],10);
    final second=restored.addProduct(name:'Отруби',unit:'меш.');
    expect(second.id,isNot(p.id));
    expect(restored.movements.where((m)=>m.kind=='inventory').length,1);
  });
  test('Do not silently recover a corrupted backup as empty data',(){
    expect(()=>StockLedger.decode('{"schemaVersion":999}'),throwsFormatException);
    expect(()=>StockLedger.decode('not json'),throwsFormatException);
  });
  test('Quantity parsing supports zero and fractions but never negatives',(){
    expect(readStockQty('0'),0);
    expect(readStockQty('12,345'),12.345);
    expect(readStockQty('12.3456'),isNull);
    expect(readStockQty('-1'),isNull);
    expect(stockText(-2.5),'-2.5');
  });
}
