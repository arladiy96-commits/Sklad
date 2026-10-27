import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

String codeOf(String s) {
  final n=s.toUpperCase().replaceAll('Н','H').replaceAll('О','0')
      .replaceAll(RegExp(r'[\s\-_]'),'');
  return n.startsWith('H') ? 'H'+n.substring(1).replaceAll('O','0') : n;
}
double? numeric(String s) => double.tryParse(s.replaceAll(RegExp(r'[^0-9,.\s]'),'').replaceAll(' ','').replaceAll(',','.'));
String qty(num n) => n==n.roundToDouble()?n.toInt().toString():n.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'),'').replaceFirst(RegExp(r'\.$'),'');

class Product {
  final String code,name;
  final double bag;
  final bool active,confirmed;
  Product(this.code,this.name,this.bag,{this.active=true,this.confirmed=false});
  factory Product.fromJson(Map<String,dynamic> j)=>Product(codeOf(j['code'] as String),
    j['name'] as String,(j['bagWeightKg'] as num).toDouble(),
    active:j['active']!=false,confirmed:j['confirmedByWarehouse']==true);
  Map<String,dynamic> toJson()=>{'code':code,'name':name,'bagWeightKg':bag,
    'active':active,'confirmedByWarehouse':confirmed};
}
class Item {
  String code;
  double kg;
  double? price,amount;
  String raw;
  Item(this.code,this.kg,{this.price,this.amount,this.raw=''});
  factory Item.fromJson(Map<String,dynamic> j)=>Item(codeOf(j['code'] as String),
    (j['kg'] as num).toDouble(),price:(j['price'] as num?)?.toDouble(),
    amount:(j['amount'] as num?)?.toDouble(),raw:j['raw'] as String? ?? '');
  Map<String,dynamic> toJson()=>{'code':code,'kg':kg,'price':price,'amount':amount,'raw':raw};
  double? bags(Map<String,Product> products) {
    final p=products[codeOf(code)];
    return p==null||p.bag<=0?null:kg/p.bag;
  }
  String? problem(Map<String,Product> products) {
    final p=products[codeOf(code)];
    if(p==null)return 'Код не найден в справочнике';
    if(!p.active)return 'Товар отключён';
    if(kg<=0)return 'Укажи количество в кг';
    final bags=kg/p.bag;
    if((bags-bags.round()).abs()>0.0001)return 'Вес не кратен фасовке';
    if(price!=null && amount!=null && (kg*price!-amount!).abs()>0.03)
      return 'Цена × количество не совпадает с суммой';
    return null;
  }
}
class Invoice {
  final String id,imagePath,createdAt;
  String number;
  List<Item> items;
  Invoice(this.id,this.number,this.imagePath,this.createdAt,this.items);
  factory Invoice.fromJson(Map<String,dynamic> j)=>Invoice(j['id'] as String,
    j['number'] as String,j['imagePath'] as String? ?? '',j['createdAt'] as String,
    (j['items'] as List).map((e)=>Item.fromJson(Map<String,dynamic>.from(e))).toList());
  Map<String,dynamic> toJson()=>{'id':id,'number':number,'imagePath':imagePath,
    'createdAt':createdAt,'items':items.map((e)=>e.toJson()).toList()};
}
class PickLine {
  final Product product;
  final List<int> additions;
  PickLine(this.product,this.additions);
  int get total=>additions.fold(0,(a,b)=>a+b);
}
List<PickLine> summary(List<Invoice> invoices,List<Product> products) {
  final catalog={for(final p in products)p.code:p};
  final result=<String,List<int>>{};
  for(final inv in invoices) {
    for(final item in inv.items) {
      final p=catalog[codeOf(item.code)];
      final bags=item.bags(catalog);
      if(p==null||bags==null||bags<=0||(bags-bags.round()).abs()>0.0001)continue;
      result.putIfAbsent(p.code,()=>[]).add(bags.round());
    }
  }
  return result.entries.map((e)=>PickLine(catalog[e.key]!,e.value)).toList()
    ..sort((a,b)=>a.product.name.compareTo(b.product.name));
}
class Warehouse {
  List<Product> products=[];
  List<Invoice> invoices=[];
  Map<String,Product> get catalog=>{for(final p in products)codeOf(p.code):p};
  Future<void> load() async {
    final prefs=await SharedPreferences.getInstance();
    final raw=prefs.getString('products_v1') ??
        await rootBundle.loadString('assets/catalog/products.json');
    final parsed=jsonDecode(raw);
    final list=parsed is List?parsed:parsed['products'] as List;
    products=list.map((e)=>Product.fromJson(Map<String,dynamic>.from(e))).toList();
    final invoicesRaw=prefs.getString('invoices_v1');
    if(invoicesRaw!=null) {
      invoices=(jsonDecode(invoicesRaw) as List)
          .map((e)=>Invoice.fromJson(Map<String,dynamic>.from(e))).toList();
    }
  }
  Future<void> save() async {
    final prefs=await SharedPreferences.getInstance();
    await prefs.setString('products_v1',jsonEncode(products.map((e)=>e.toJson()).toList()));
    await prefs.setString('invoices_v1',jsonEncode(invoices.map((e)=>e.toJson()).toList()));
  }
  bool duplicate(String number,String? excludeId)=>number.trim().isNotEmpty &&
    invoices.any((e)=>e.id!=excludeId &&
      e.number.trim().toLowerCase()==number.trim().toLowerCase());
  Future<String> keepPhoto(String source) async {
    final dir=Directory((await getApplicationDocumentsDirectory()).path+'/photos');
    await dir.create(recursive:true);
    final dst=await File(source).copy(dir.path+'/'+DateTime.now().microsecondsSinceEpoch.toString()+'.jpg');
    return dst.path;
  }
}

class ScanData {
  final String number;
  final List<Item> items;
  ScanData(this.number,this.items);
}
class Scanner {
  final recognizer=TextRecognizer(script:TextRecognitionScript.latin);
  Future<ScanData> scan(String path,Set<String> known) async {
    final decoded=img.decodeImage(await File(path).readAsBytes());
    if(decoded==null)throw const FormatException('Фотография повреждена');
    final original=img.bakeOrientation(decoded);
    final dir=await getTemporaryDirectory();
    ScanData best=ScanData('',[]);
    int score(ScanData d)=>d.items.length*10+
      d.items.where((e)=>known.contains(e.code)&&e.kg>0).length*25;
    try{
      for(final angle in [0,90,270,180]) {
        final rotated=angle==0?original:img.copyRotate(original,angle:angle);
        final tmp=File(dir.path+'/ocr_'+angle.toString()+'.jpg');
        await tmp.writeAsBytes(img.encodeJpg(rotated,quality:86));
        try{
          final text=await recognizer.processImage(InputImage.fromFilePath(tmp.path));
          final result=_extract(text);
          if(score(result)>score(best))best=result;
          if(result.items.isNotEmpty &&
            result.items.every((e)=>known.contains(e.code)&&e.kg>0))break;
        }finally{if(await tmp.exists())await tmp.delete();}
      }
    }finally{await recognizer.close();}
    return best;
  }

  ScanData _extract(RecognizedText text) {
    final lines=text.blocks.expand((b)=>b.lines).toList();
    final elements=lines.expand((l)=>l.elements).toList();
    final raw=text.text.toUpperCase().replaceAll(' ','');
    final number=RegExp(r'ТДБ[0-9]{7,11}').firstMatch(raw)?.group(0)??'';
    if(elements.isEmpty)return ScanData(number,[]);
    final edge=elements.fold<double>(1,(v,e)=>math.max(v,e.boundingBox.right.toDouble()));
    double headerX(String key,double fraction) {
      for(final l in lines) {
        if(l.text.toLowerCase().contains(key))return l.boundingBox.left.toDouble()-10;
      }
      return edge*fraction;
    }
    final qX=headerX('количество',.70);
    final pX=headerX('цена',.81);
    final sX=headerX('сумма',.90);
    final anchors=<(TextLine,String)>[];
    for(final l in lines){
      final code=RegExp(r'H[0-9]{8}').firstMatch(codeOf(l.text))?.group(0);
      if(code!=null)anchors.add((l,code));
    }
    anchors.sort((a,b)=>a.$1.boundingBox.center.dy.compareTo(b.$1.boundingBox.center.dy));
    final items=<Item>[];
    for(var i=0;i<anchors.length;i++){
      final line=anchors[i].$1;
      final y=line.boundingBox.center.dy;
      final tolerance=math.max(12.0,line.boundingBox.height*1.1);
      final before=i==0?double.negativeInfinity:
        (anchors[i-1].$1.boundingBox.center.dy+y)/2;
      final after=i==anchors.length-1?double.infinity:
        (anchors[i+1].$1.boundingBox.center.dy+y)/2;
      final row=elements.where((e){
        final cy=e.boundingBox.center.dy;
        return cy>before&&cy<after&&(cy-y).abs()<=tolerance;
      }).toList()..sort((a,b)=>a.boundingBox.left.compareTo(b.boundingBox.left));
      double? col(double from,double to){
        if(to<=from)return null;
        final value=row.where((e)=>e.boundingBox.center.dx>=from &&
          e.boundingBox.center.dx<to).map((e)=>e.text).join(' ');
        return numeric(value);
      }
      items.add(Item(anchors[i].$2,col(qX,pX)??0,
        price:col(pX,sX),amount:col(sX,edge+10),
        raw:row.map((e)=>e.text).join(' ')));
    }
    return ScanData(number,items);
  }
}
