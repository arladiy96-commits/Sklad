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
  List<Map<String,dynamic>> history=[];
  Map<String,Product> get catalog=>{for(final p in products)codeOf(p.code):p};
  Future<void> load() async {
    final prefs=await SharedPreferences.getInstance();
    final raw=prefs.getString('products_v1') ??
        await rootBundle.loadString('assets/catalog/products.json');
    final parsed=jsonDecode(raw);
    final list=parsed is List?parsed:parsed['products'] as List;
    products=list.map((e)=>Product.fromJson(Map<String,dynamic>.from(e))).toList();
    final archived=prefs.getString('batches_v1');
    if(archived!=null)history=(jsonDecode(archived) as List)
      .map((e)=>Map<String,dynamic>.from(e as Map)).toList();
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
    await prefs.setString('batches_v1',jsonEncode(history));
  }
  void finishBatch(){
    if(invoices.isEmpty)return;
    history.insert(0,{'finishedAt':DateTime.now().toIso8601String(),
      'invoices':invoices.map((e)=>e.toJson()).toList()});
    invoices=[];
  }
  List<Invoice> batchInvoices(Map<String,dynamic> batch)=>(batch['invoices'] as List)
    .map((e)=>Invoice.fromJson(Map<String,dynamic>.from(e as Map))).toList();
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
/// Only a complete standalone number from the Quantity column is accepted.
/// H00001955 must NEVER be parsed as 1955 kilograms.
double? parseQuantityToken(String input) {
  final cleaned=input.trim().replaceAll(RegExp(r'\s+'),'')
      .replaceAll(RegExp(r'[|:]'),'')
      .replaceAll(RegExp(r'(кг|kg|kr)$',caseSensitive:false),'');
  if(!RegExp(r'^\d{1,5}(?:[.,]\d{1,2})?$').hasMatch(cleaned))return null;
  final result=double.tryParse(cleaned.replaceAll(',','.'));
  return result==null||result<=0?null:result;
}
class QuantityToken {
  final String text;
  final double x,y;
  const QuantityToken(this.text,this.x,this.y);
}

/// Never align by loose OCR text lines. Only use numbers physically located
/// in the quantity column, and only when we have exactly one per product row.
List<double>? matchQuantities(List<double> rowYs,List<QuantityToken> tokens,
    double left,double right,double top,double bottom) {
  if(rowYs.isEmpty)return null;
  final values=tokens.where((t)=>t.x>=left&&t.x<right&&
      t.y>=top&&t.y<=bottom&&parseQuantityToken(t.text)!=null).toList()
    ..sort((a,b)=>a.y.compareTo(b.y));
  if(values.length!=rowYs.length)return null;
  for(var i=1;i<values.length;i++){
    if((values[i].y-values[i-1].y).abs()<3)return null;
  }
  if(rowYs.length>1){
    final leftSpan=rowYs.last-rowYs.first;
    final rightSpan=values.last.y-values.first.y;
    final gap=leftSpan/(rowYs.length-1);
    if(gap<=0||(leftSpan-rightSpan).abs()>math.max(18.0,gap*0.8))return null;
  }
  return values.map((v)=>parseQuantityToken(v.text)!).toList();
}
class _CodeAnchor {
  final String code;
  final double y,height;
  const _CodeAnchor(this.code,this.y,this.height);
}
class Scanner {
  final recognizer=TextRecognizer(script:TextRecognitionScript.latin);
  Future<ScanData> scan(String path,Set<String> known) async {
    final decoded=img.decodeImage(await File(path).readAsBytes());
    if(decoded==null)throw const FormatException('Фотография повреждена');
    final original=img.bakeOrientation(decoded);
    final dir=await getTemporaryDirectory();
    ScanData best=ScanData('',[]);
    int score(ScanData s)=>s.items.length*10+
      s.items.where((i)=>known.contains(i.code)).length*25+
      s.items.where((i)=>i.kg>0).length*8;
    try{
      for(final angle in [0,90,270,180]){
        final photo=angle==0?original:img.copyRotate(original,angle:angle);
        final file=File(dir.path+'/sklad_full_'+angle.toString()+'.jpg');
        await file.writeAsBytes(img.encodeJpg(photo,quality:90));
        try{
          final full=await recognizer.processImage(InputImage.fromFilePath(file.path));
          final anchors=_readCodes(full);
          if(anchors.isEmpty)continue;
          final rows=await _readQuantityColumn(photo,full,anchors,known,dir);
          final number=RegExp(r'ТДБ[0-9]{7,11}').firstMatch(
              full.text.toUpperCase().replaceAll(RegExp(r'\s+'),''))?.group(0)??'';
          final result=ScanData(number,rows);
          if(score(result)>score(best))best=result;
          if(anchors.length>=2 && anchors.every((a)=>known.contains(a.code)))break;
        }finally{if(await file.exists())await file.delete();}
      }
    }finally{await recognizer.close();}
    return best;
  }
  List<_CodeAnchor> _readCodes(RecognizedText text){
    final anchors=<_CodeAnchor>[];
    for(final block in text.blocks){
      for(final line in block.lines){
        var foundInTokens=false;
        for(final e in line.elements){
          final match=RegExp(r'H[0-9]{8}').firstMatch(codeOf(e.text));
          if(match!=null){
            anchors.add(_CodeAnchor(match.group(0)!,
              e.boundingBox.center.dy,e.boundingBox.height.toDouble()));
            foundInTokens=true;
          }
        }
        if(!foundInTokens){
          final match=RegExp(r'H[0-9]{8}').firstMatch(codeOf(line.text));
          if(match!=null)anchors.add(_CodeAnchor(match.group(0)!,
            line.boundingBox.center.dy,line.boundingBox.height.toDouble()));
        }
      }
    }
    anchors.sort((a,b)=>a.y.compareTo(b.y));
    final distinct=<_CodeAnchor>[];
    for(final a in anchors){
      if(distinct.any((b)=>(b.y-a.y).abs()<math.max(5.0,a.height*0.4)))continue;
      distinct.add(a);
    }
    return distinct;
  }
  List<QuantityToken> _tokens(RecognizedText text,
      {double ox=0,double oy=0,double scale=1}) => [
    for(final b in text.blocks)
      for(final l in b.lines)
        for(final e in l.elements)
          QuantityToken(e.text,ox+e.boundingBox.center.dx/scale,
            oy+e.boundingBox.center.dy/scale)
  ];
  Future<List<Item>> _readQuantityColumn(img.Image photo,RecognizedText full,
      List<_CodeAnchor> anchors,Set<String> known,Directory dir) async {
    final ys=anchors.map((a)=>a.y).toList();
    final gap=ys.length>1?(ys.last-ys.first)/(ys.length-1):
      math.max(20.0,anchors.first.height*1.8);
    final padding=math.max(20.0,gap*1.7);
    // Fixed-format company invoices: Quantity around 69%-81% of page width.
    // This band deliberately excludes the SKU column and the Price column.
    final left=photo.width*0.685;
    final right=photo.width*0.818;
    final top=math.max(0.0,ys.first-padding);
    final bottom=math.min(photo.height.toDouble(),ys.last+2*padding);
    final base=matchQuantities(ys,_tokens(full),left,right,top,bottom);
    // Reconstruct the printed table width from the code cells and right-most
    // text, rather than assuming that every photo crops the page identically.
    var codeLeft=photo.width.toDouble();
    var pageRight=0.0;
    for(final block in full.blocks){
      for(final line in block.lines){
        for(final element in line.elements){
          pageRight=math.max(pageRight,element.boundingBox.right.toDouble());
          if(RegExp(r'H[0-9]{8}').hasMatch(codeOf(element.text))){
            codeLeft=math.min(codeLeft,element.boundingBox.left.toDouble());
          }
        }
      }
    }
    if(codeLeft==photo.width.toDouble())codeLeft=photo.width*0.08;
    if(pageRight<photo.width*0.7)pageRight=photo.width.toDouble();
    final tableLeft=math.max(0.0,codeLeft-35);
    final tableRight=math.min(photo.width.toDouble(),pageRight+12);
    final span=tableRight-tableLeft;
    // Keep only printed numbers, not the «кг» suffix or vertical grid.
    final digitLeft=tableLeft+span*0.728;
    final digitRight=tableLeft+span*0.794;
    final x0=digitLeft.floor().clamp(0,photo.width-1);
    final x1=digitRight.ceil().clamp(x0+1,photo.width);
    final y0=top.floor().clamp(0,photo.height-1);
    final y1=bottom.ceil().clamp(y0+1,photo.height);
    final cropped=img.copyCrop(photo,x:x0,y:y0,width:x1-x0,height:y1-y0);
    final large=img.copyResize(cropped,width:cropped.width*3,
      interpolation:img.Interpolation.cubic);
    final temp=File(dir.path+'/sklad_quantities.jpg');
    await temp.writeAsBytes(img.encodeJpg(large,quality:95));
    List<double>? enhanced;
    try{
      final croppedText=await recognizer.processImage(
        InputImage.fromFilePath(temp.path));
      enhanced=matchQuantities(ys,_tokens(croppedText,
        ox:x0.toDouble(),oy:y0.toDouble(),scale:3),
        digitLeft,digitRight,top,bottom);
    }finally{if(await temp.exists())await temp.delete();}
    // Conflicting reads indicate uncertainty: fail closed.
    var amounts=enhanced??base;
    if(enhanced!=null && base!=null){
      for(var i=0;i<base.length;i++){
        if((base[i]-enhanced[i]).abs()>0.001){amounts=null;break;}
      }
    }
    return [
      for(var i=0;i<anchors.length;i++)
        Item(anchors[i].code,
          known.contains(anchors[i].code) && amounts!=null ? amounts[i] : 0,
          raw:amounts==null?'Код найден; количество не прочитано, введи вручную':
            'Количество прочитано из отдельной колонки; проверь по фото'),
    ];
  }
}
