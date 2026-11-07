import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

String cleanScan(String value) => value.trim();
double roundStock(num n) => (n*1000).roundToDouble()/1000;
String stockText(num value) {
  final n=roundStock(value);
  return n==n.roundToDouble()?n.toInt().toString()
      :n.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'),'').replaceFirst(RegExp(r'\.$'),'');
}
double? readStockQty(String raw) {
  final s=raw.trim().replaceAll(' ','').replaceAll(',','.');
  if(!RegExp(r'^\d+(?:\.\d{1,3})?$').hasMatch(s))return null;
  final n=double.tryParse(s);
  return n!=null&&n.isFinite&&n>=0&&n<=1000000000?roundStock(n):null;
}

class StockProduct {
  final String id;
  String name,unit,location,category;
  bool active;
  final List<String> codes;
  StockProduct(this.id,this.name,this.unit,this.location,this.category,this.codes,{this.active=true});
  factory StockProduct.fromJson(Map<String,dynamic> j)=>StockProduct(
    j['id'] as String,j['name'] as String,j['unit'] as String,
    j['location'] as String? ?? '',j['category'] as String? ?? '',
    (j['codes'] as List).cast<String>().toList(),active:j['active']!=false);
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'unit':unit,'location':location,
    'category':category,'codes':codes,'active':active};
}
class StockMove {
  final String id,productId,kind,timestamp,note;
  final double delta;
  StockMove(this.id,this.productId,this.kind,this.timestamp,this.delta,this.note);
  factory StockMove.fromJson(Map<String,dynamic> j)=>StockMove(j['id'] as String,
    j['productId'] as String,j['kind'] as String,j['timestamp'] as String,
    (j['delta'] as num).toDouble(),j['note'] as String? ?? '');
  Map<String,dynamic> toJson()=>{'id':id,'productId':productId,'kind':kind,
    'timestamp':timestamp,'delta':delta,'note':note};
}
class StockCount {
  final String id,startedAt;
  String? closedAt;
  bool cancelled;
  final Map<String,double> expected,actual;
  StockCount(this.id,this.startedAt,this.expected,
      {Map<String,double>? actual,this.closedAt,this.cancelled=false})
      :actual=actual??{};
  bool get isOpen=>closedAt==null&&!cancelled;
  factory StockCount.fromJson(Map<String,dynamic> j)=>StockCount(j['id'] as String,
    j['startedAt'] as String,(j['expected'] as Map).map((k,v)=>
      MapEntry(k.toString(),(v as num).toDouble())),
    actual:(j['actual'] as Map).map((k,v)=>
      MapEntry(k.toString(),(v as num).toDouble())),
    closedAt:j['closedAt'] as String?,cancelled:j['cancelled']==true);
  Map<String,dynamic> toJson()=>{'id':id,'startedAt':startedAt,'closedAt':closedAt,
    'cancelled':cancelled,'expected':expected,'actual':actual};
  int get checked=>actual.length;
  double difference(String id)=>roundStock((actual[id]??expected[id]??0)-(expected[id]??0));
}

class StockLedger {
  final List<StockProduct> products;
  final List<StockMove> movements;
  final List<StockCount> counts;
  int sequence;
  StockLedger({List<StockProduct>? products,List<StockMove>? movements,
    List<StockCount>? counts,this.sequence=0})
      :products=products??[],movements=movements??[],counts=counts??[];
  static const schemaVersion=1;
  static const fileName='sklad_inventory_v1.json';
  static StockLedger decode(String source){
    final j=jsonDecode(source) as Map<String,dynamic>;
    if(j['schemaVersion']!=schemaVersion)throw const FormatException('Неизвестная версия складских данных');
    final result=StockLedger(sequence:j['sequence'] as int? ??0,
      products:(j['products'] as List).map((e)=>StockProduct.fromJson(Map<String,dynamic>.from(e as Map))).toList(),
      movements:(j['movements'] as List).map((e)=>StockMove.fromJson(Map<String,dynamic>.from(e as Map))).toList(),
      counts:(j['counts'] as List).map((e)=>StockCount.fromJson(Map<String,dynamic>.from(e as Map))).toList());
    result.verify();return result;
  }
  Map<String,dynamic> toJson()=>{'schemaVersion':schemaVersion,'sequence':sequence,
    'products':products.map((e)=>e.toJson()).toList(),
    'movements':movements.map((e)=>e.toJson()).toList(),
    'counts':counts.map((e)=>e.toJson()).toList()};
  String encode()=>const JsonEncoder.withIndent('  ').convert(toJson());
  static Future<File> storageFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$fileName');
  static Future<StockLedger> open() async{
    final file=await storageFile();
    if(!await file.exists())return StockLedger();
    return StockLedger.decode(await file.readAsString());
  }
  Future<void> save() async{
    verify();
    final file=await storageFile(),tmp=File('${file.path}.tmp');
    await tmp.writeAsString(encode(),flush:true);
    await tmp.rename(file.path);
  }

  String _id(String prefix)=>'$prefix-${(++sequence).toString().padLeft(6,'0')}';
  String get _now=>DateTime.now().toIso8601String();
  StockProduct? byId(String id) {
    for(final p in products){if(p.id==id)return p;}return null;
  }
  StockProduct? byCode(String code){
    final c=cleanScan(code);
    for(final p in products){if(p.codes.contains(c))return p;}return null;
  }
  StockCount? get current{
    for(final c in counts){if(c.isOpen)return c;}return null;
  }
  double balance(String id)=>roundStock(movements.where((e)=>e.productId==id)
      .fold<double>(0,(sum,e)=>sum+e.delta));

  void _validCode(String code,{String? owner}){
    final c=cleanScan(code);
    if(c.isEmpty||c.length>128||c.contains(RegExp(r'[\x00-\x1f]'))){
      throw const FormatException('Пустой или слишком длинный код');
    }
    final p=byCode(c);
    if(p!=null&&p.id!=owner)throw StateError('Код уже привязан к товару: ${p.name}');
  }
  StockProduct addProduct({required String name,required String unit,
    String location='',String category='',String? scannedCode}){
    final title=name.trim();
    if(title.isEmpty||title.length>150||unit.trim().isEmpty)throw const FormatException('Укажи название и единицу измерения');
    if(scannedCode!=null&&scannedCode.trim().isNotEmpty)_validCode(scannedCode);
    var id=_id('SK');
    // A scanned factory barcode may accidentally equal a future internal ID.
    while(byCode(id)!=null){id=_id('SK');}
    final codes=[id];
    if(scannedCode!=null&&scannedCode.trim().isNotEmpty&&cleanScan(scannedCode)!=id){
      codes.add(cleanScan(scannedCode));
    }
    final p=StockProduct(id,title,unit.trim(),location.trim(),category.trim(),codes);
    products.add(p);
    current?.expected[id]=0;
    return p;
  }
  void updateProduct(String id,{required String name,required String unit,
    required String location,required String category,required bool active}){
    final p=byId(id)??(throw StateError('Товар не найден'));
    if(name.trim().isEmpty||unit.trim().isEmpty)throw const FormatException('Название и единица измерения обязательны');
    if(p.unit!=unit.trim()&&(movements.any((m)=>m.productId==id)||
       counts.any((c)=>c.expected.containsKey(id)))){
      throw StateError('Единицу товара с историей менять нельзя');
    }
    p.name=name.trim();p.unit=unit.trim();p.location=location.trim();
    p.category=category.trim();p.active=active;
  }
  void addCode(String id,String code){
    final p=byId(id)??(throw StateError('Товар не найден'));
    _validCode(code,owner:id);
    final c=cleanScan(code);
    if(!p.codes.contains(c))p.codes.add(c);
  }
  void removeCode(String id,String code){
    final p=byId(id)??(throw StateError('Товар не найден'));
    if(code==id)throw StateError('Внутренний код удалять нельзя');
    p.codes.remove(code);
  }
  StockMove move(String id,double amount,{required bool receipt,String note=''}) {
    if(current!=null)throw StateError('Сначала заверши инвентаризацию');
    final p=byId(id)??(throw StateError('Товар не найден'));
    if(!p.active)throw StateError('Товар отключён');
    if(!amount.isFinite||amount<=0||amount>1000000000||roundStock(amount)!=amount){
      throw const FormatException('Количество должно быть больше нуля, до 3 знаков после запятой');
    }
    if(!receipt&&balance(id)+0.00001<amount)throw StateError('Недостаточно остатка');
    final m=StockMove(_id('MV'),id,receipt?'receipt':'issue',_now,
      receipt?amount:-amount,note.trim());
    movements.add(m);return m;
  }
  StockCount startCount(){
    if(current!=null)throw StateError('Инвентаризация уже открыта');
    final expected={for(final p in products.where((p)=>p.active))p.id:balance(p.id)};
    final c=StockCount(_id('IV'),_now,expected);
    counts.insert(0,c);return c;
  }
  void setActual(String id,double value){
    final c=current??(throw StateError('Нет открытой инвентаризации'));
    if(!c.expected.containsKey(id))throw StateError('Товар вне инвентаризации');
    if(!value.isFinite||value<0||readStockQty(stockText(value))!=value)throw const FormatException('Некорректное количество');
    c.actual[id]=value;
  }
  void finishCount({required bool apply}){
    final c=current??(throw StateError('Нет открытой инвентаризации'));
    if(c.actual.isEmpty)throw StateError('Сначала посчитай хотя бы один товар');
    for(final row in c.actual.entries){
      final difference=roundStock(row.value-balance(row.key));
      if(apply&&difference!=0){
        movements.add(StockMove(_id('MV'),row.key,'inventory',_now,difference,
          'Корректировка инвентаризации ${c.id}'));
      }
    }
    c.closedAt=_now;
  }
  void cancelCount(){
    final c=current??(throw StateError('Нет открытой инвентаризации'));
    c.cancelled=true;
  }
  void verify(){
    final ids=<String>{},codes=<String>{};
    for(final p in products){
      if(!ids.add(p.id)||!p.codes.contains(p.id)||p.name.trim().isEmpty){
        throw const FormatException('Повреждён каталог инвентаризации');
      }
      for(final code in p.codes){
        if(!codes.add(code))throw const FormatException('Один код привязан к двум товарам');
      }
    }
    for(final m in movements){
      if(!ids.contains(m.productId)||!m.delta.isFinite)throw const FormatException('Повреждён журнал движений');
    }
    if(counts.where((c)=>c.isOpen).length>1)throw const FormatException('Несколько активных инвентаризаций');
    for(final c in counts){
      if(c.actual.keys.any((k)=>!c.expected.containsKey(k))){
        throw const FormatException('Повреждена инвентаризация');
      }
    }
  }
}
