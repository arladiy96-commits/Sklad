import 'package:flutter_test/flutter_test.dart';
import 'package:sklad/core.dart';

void main() {
  test('Cyrillic and Latin H resolve to the same SKU', () {
    expect(codeOf('Н00001955'), 'H00001955');
    expect(codeOf('H00001955'), 'H00001955');
    expect(codeOf(' Н00001955 '), 'H00001955');
  });

  test('KG conversion and arithmetic validation', () {
    final product=Product('H00001955','Тамерлан 25 кг',25);
    final products={product.code:product};
    expect(Item('Н00001955',250,price:171,amount:42750).bags(products),10);
    expect(Item('H00001955',250,price:171,amount:42750).problem(products),isNull);
    expect(Item('H00001955',255).problem(products),isNotNull);
    expect(Item('H00001955',250,price:171,amount:42000).problem(products),isNotNull);
  });

  test('Merges repeated SKUs but leaves different bag sizes separate', () {
    final p25=Product('H00001955','Тамерлан 25 кг',25);
    final p10=Product('H00001952','Тамерлан 10 кг',10);
    final invoices=[
      Invoice('1','101','','2026-10-26',[Item(p25.code,250),Item(p10.code,100)]),
      Invoice('2','102','','2026-10-26',[Item(p25.code,50)]),
    ];
    final lines=summary(invoices,[p25,p10]);
    expect(lines.length,2);
    expect(lines.firstWhere((e)=>e.product.code==p25.code).total,12);
    expect(lines.firstWhere((e)=>e.product.code==p10.code).total,10);
  });
  test('OCR never treats the product SKU as kilograms', () {
    expect(parseQuantityToken('H00001950'),isNull);
    expect(parseQuantityToken('H00001955'),isNull);
    expect(parseQuantityToken('H00001952'),isNull);
    expect(parseQuantityToken('250 кг'),250);
    expect(parseQuantityToken('100'),100);
    expect(parseQuantityToken('171,00'),171);
  });

  test('Quantity column ignores codes and sums outside its X boundaries', () {
    const tokens=[
      QuantityToken('H00001950',80,100),
      QuantityToken('H00001955',80,120),
      QuantityToken('H00001952',80,140),
      QuantityToken('250 кг',1095,119),
      QuantityToken('250 кг',1095,139),
      QuantityToken('100 кг',1095,159),
      QuantityToken('171',1250,119),
      QuantityToken('46000',1360,139),
    ];
    expect(matchQuantities([100,120,140],tokens,1030,1190,80,180),
      [250,250,100]);
  });

  test('Unclear row count yields blank quantities rather than guessing', () {
    const tokens=[
      QuantityToken('250',1100,120),
      QuantityToken('100',1100,160),
    ];
    expect(matchQuantities([100,120,140],tokens,1030,1190,80,180),isNull);
    expect(matchQuantities([100],[
      QuantityToken('H00001955',1100,100)
    ],1030,1190,80,180),isNull);
  });

}
