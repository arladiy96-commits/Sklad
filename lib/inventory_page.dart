import 'package:flutter/material.dart';
import 'core.dart' show Product;
import 'inventory_model.dart';
import 'inventory_product_page.dart';
import 'inventory_reports.dart';
import 'inventory_scanner.dart';

const _navy=Color(0xFF192C39);
const _amber=Color(0xFFE8A12A);

class InventoryPage extends StatefulWidget {
  final List<Product> invoiceProducts;
  const InventoryPage({super.key,required this.invoiceProducts});
  @override State<InventoryPage> createState()=>_InventoryPageState();
}
class _InventoryPageState extends State<InventoryPage> {
  StockLedger? ledger;
  String? error;
  String query='';
  int screen=0;
  bool writing=false;
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    try{
      final data=await StockLedger.open();
      if(mounted)setState(()=>ledger=data);
    }catch(e){
      if(mounted)setState(()=>error=e.toString());
    }
  }
  void notice(String value) {
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text(value.replaceFirst('Bad state: ','')
        .replaceFirst('FormatException: ',''))));
  }
  Future<bool> commit(void Function() change) async {
    if(writing||ledger==null)return false;
    final before=ledger!.encode();
    setState(()=>writing=true);
    try{
      change();
      await ledger!.save();
      if(mounted)setState((){});
      return true;
    }catch(e){
      ledger=StockLedger.decode(before);
      notice(e.toString());
      return false;
    }finally{
      if(mounted)setState(()=>writing=false);
    }
  }
  Future<bool> ask(String title,String body,String label) async =>
    await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(title),content:Text(body),actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Отмена')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:Text(label)),
      ]))??false;
  Future<StockProduct?> create({String? scannedCode}) async{
    final draft=await stockProductForm(context);
    if(draft==null||!mounted)return null;
    String? id;
    final ok=await commit((){
      id=ledger!.addProduct(name:draft.name,unit:draft.unit,
        location:draft.location,category:draft.category,
        scannedCode:scannedCode).id;
    });
    if(ok&&id!=null){notice('Товар добавлен');return ledger!.byId(id!);}
    return null;
  }
  Future<void> openProduct(StockProduct p) async {
    await Navigator.push<void>(context,MaterialPageRoute(
      builder:(_)=>StockProductPage(id:p.id,ledger:()=>ledger!,commit:commit)));
    if(mounted)setState((){});
  }
  Future<void> lookup({bool counting=false,String? code}) async {
    final scanned=code??await requestCode(context);
    if(scanned==null||!mounted)return;
    var p=ledger!.byCode(scanned);
    if(p==null){
      if(!await ask('Неизвестный код',
        'Код: '+scanned+'\nСоздать новую карточку товара?', 'Создать'))return;
      p=await create(scannedCode:scanned);
      if(p==null||!mounted)return;
    }
    if(counting&&ledger!.current!=null){await countItem(p);}
    else{await openProduct(p);}
  }
  Future<void> lookupManual({bool counting=false}) async{
    final code=await enterCode(context);
    if(code!=null&&mounted)await lookup(counting:counting,code:code);
  }
  Future<void> importInvoiceProducts() async {
    final available=widget.invoiceProducts.where((p)=>
      ledger!.byCode(p.code)==null).toList();
    if(available.isEmpty){notice('Все коды из накладных уже добавлены');return;}
    if(!await ask('Импортировать товары?',
      'Добавить '+available.length.toString()+' позиций из справочника накладных? '
      'Остатки будут 0. Накладные не изменятся.', 'Добавить'))return;
    if(await commit((){
      for(final p in available) {
        ledger!.addProduct(name:p.name,unit:'меш.',
          category:'Готовая продукция',scannedCode:p.code);
      }
    }))notice('Добавлено: '+available.length.toString());
  }
  Future<void> countItem(StockProduct p) async {
    final c=ledger!.current;
    if(c==null){notice('Сначала начни инвентаризацию');return;}
    final initial=c.actual.containsKey(p.id)?stockText(c.actual[p.id]!):'';
    final controller=TextEditingController(text:initial);
    final result=await showDialog<double>(context:context,builder:(ctx)=>AlertDialog(
      title:Text('Пересчёт: '+p.name),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        Text('По учёту: '+stockText(c.expected[p.id]??0)+' '+p.unit),
        const SizedBox(height:12),
        TextField(controller:controller,autofocus:true,
          keyboardType:const TextInputType.numberWithOptions(decimal:true),
          decoration:InputDecoration(labelText:'Фактически ('+p.unit+')',
            helperText:'0 — если товара нет')),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Отмена')),
        FilledButton(onPressed:(){
          final v=readStockQty(controller.text);
          if(v==null){
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content:Text('Введи неотрицательное количество, максимум 3 знака после запятой')));
            return;
          }
          Navigator.pop(ctx,v);
        },child:const Text('Сохранить факт')),
      ],
    ));
    controller.dispose();
    if(result!=null&&mounted)await commit(()=>ledger!.setActual(p.id,result));
  }
  Future<void> finishCount() async {
    final c=ledger!.current;
    if(c==null)return;
    if(c.checked==0){notice('Нужно посчитать хотя бы один товар');return;}
    final apply=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Завершить пересчёт?'),
      content:Text('Проверено '+c.checked.toString()+' из '+c.expected.length.toString()+
        ' товаров.\nНепроверенные товары не изменятся.\n\n'
        'Применить найденные расхождения к остаткам?'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Назад')),
        OutlinedButton(onPressed:()=>Navigator.pop(ctx,false),
          child:const Text('Только отчёт')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),
          child:const Text('Применить')),
      ],
    ));
    if(apply==null)return;
    if(await commit(()=>ledger!.finishCount(apply:apply))){
      notice(apply?'Инвентаризация закрыта, остатки обновлены':
        'Инвентаризация закрыта без изменения остатков');
      setState(()=>screen=2);
    }
  }
  Future<void> backup() async {
    try{await exportInventoryBackup(ledger!);}
    catch(e){notice('Ошибка резервной копии: $e');}
  }
  Future<void> csv(StockCount count) async {
    try{await exportInventoryCsv(ledger!,count);}
    catch(e){notice('Ошибка отчёта: $e');}
  }
  Widget heading(String title,String subtitle)=>Padding(
    padding:const EdgeInsets.only(bottom:12),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(title,style:const TextStyle(fontSize:21,
        fontWeight:FontWeight.w900,color:_navy)),
      Text(subtitle,style:const TextStyle(fontSize:12,color:Colors.black54)),
    ]));
  Widget catalog(){
    final items=[...ledger!.products]..sort((a,b)=>a.name.compareTo(b.name));
    final filtered=items.where((p)=>
      (p.name+' '+p.category+' '+p.location+' '+p.codes.join(' '))
        .toLowerCase().contains(query.toLowerCase())).toList();
    return ListView(padding:const EdgeInsets.all(14),children:[
      heading('Товары и остатки','Отдельный складской учёт · всё хранится на этом телефоне'),
      Container(padding:const EdgeInsets.all(16),
        decoration:BoxDecoration(color:_navy,borderRadius:BorderRadius.circular(18)),
        child:Row(children:[
          const Icon(Icons.inventory_2_outlined,color:_amber,size:28),
          const SizedBox(width:12),
          Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(items.length.toString()+' товаров',
              style:const TextStyle(color:Colors.white,fontSize:20,
                fontWeight:FontWeight.bold)),
            Text(ledger!.movements.length.toString()+' операций',
              style:const TextStyle(color:Colors.white70)),
          ]),
        ])),
      const SizedBox(height:12),
      Row(children:[
        Expanded(child:FilledButton.icon(
          onPressed:()=>lookup(),icon:const Icon(Icons.qr_code_scanner),
          label:const Text('Сканировать'))),
        const SizedBox(width:8),
        Expanded(child:OutlinedButton.icon(onPressed:()=>create(),
          icon:const Icon(Icons.add),label:const Text('Новый товар'))),
      ]),
      const SizedBox(height:6),
      OutlinedButton.icon(onPressed:lookupManual,icon:const Icon(Icons.keyboard),
        label:const Text('Ввести код вручную')),
      TextField(onChanged:(value)=>setState(()=>query=value),
        decoration:const InputDecoration(prefixIcon:Icon(Icons.search),
          hintText:'Поиск по имени, коду или складу')),
      const SizedBox(height:8),
      if(items.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(22),
        child:Text('Пока пусто. Отсканируй заводской штрихкод или создай первый товар.'))),
      for(final p in filtered)Card(child:ListTile(
        leading:CircleAvatar(backgroundColor:const Color(0xFFE9EFF0),
          child:Icon(p.active?Icons.inventory_2_outlined:Icons.inventory_2,color:_navy)),
        title:Text(p.name,style:const TextStyle(fontWeight:FontWeight.bold)),
        subtitle:Text(p.id+' · '+(p.location.isEmpty?'Без места хранения':p.location)+
          (p.active?'':' · отключён')),
        trailing:Column(mainAxisAlignment:MainAxisAlignment.center,
          crossAxisAlignment:CrossAxisAlignment.end,children:[
            Text(stockText(ledger!.balance(p.id)),
              style:const TextStyle(fontWeight:FontWeight.w800,fontSize:20,color:_navy)),
            Text(p.unit,style:const TextStyle(fontSize:11)),
          ]),
        onTap:()=>openProduct(p),
      )),
      TextButton.icon(onPressed:importInvoiceProducts,
        icon:const Icon(Icons.copy_all),label:const Text('Добавить из каталога накладных')),
      OutlinedButton.icon(onPressed:backup,icon:const Icon(Icons.backup_outlined),
        label:const Text('Сохранить резервную копию (JSON)')),
      const SizedBox(height:16),
    ]);
  }
  Widget counting(){
    final c=ledger!.current;
    return ListView(padding:const EdgeInsets.all(14),children:[
      heading('Инвентаризация','Сканируй товары и сверяй фактические остатки'),
      if(c==null)
        Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(children:[
          const Icon(Icons.fact_check_outlined,size:42,color:_navy),
          const SizedBox(height:9),
          const Text('Нет открытого пересчёта',
            style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
          const SizedBox(height:8),
          const Text('Зафиксируем учётные остатки. Пока идёт проверка, '
            'приход и расход заблокированы.',textAlign:TextAlign.center),
          const SizedBox(height:12),
          FilledButton.icon(
            onPressed:ledger!.products.any((p)=>p.active)?
              () async {await commit(()=>ledger!.startCount());}:null,
            icon:const Icon(Icons.play_arrow),label:const Text('Начать пересчёт')),
        ])))
      else ...[
        Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(c.id,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
            const SizedBox(height:5),
            Text('Проверено '+c.checked.toString()+' из '+c.expected.length.toString()),
            const SizedBox(height:10),
            LinearProgressIndicator(value:c.expected.isEmpty?0:c.checked/c.expected.length),
            const SizedBox(height:12),
            FilledButton.icon(onPressed:()=>lookup(counting:true),
              icon:const Icon(Icons.qr_code_scanner),label:const Text('Сканировать товар')),
            OutlinedButton.icon(onPressed:()=>lookupManual(counting:true),
              icon:const Icon(Icons.keyboard),label:const Text('Ввести код')),
          ]))),
        const SizedBox(height:8),
        for(final id in c.expected.keys)
          if(ledger!.byId(id)!=null)
            Card(child:ListTile(
              title:Text(ledger!.byId(id)!.name),
              subtitle:Text('Учёт: '+stockText(c.expected[id]!)+' '+ledger!.byId(id)!.unit),
              trailing:Column(mainAxisAlignment:MainAxisAlignment.center,
                crossAxisAlignment:CrossAxisAlignment.end,children:[
                  Text(c.actual.containsKey(id)?
                    stockText(c.actual[id]!)+' '+ledger!.byId(id)!.unit:'Не проверено',
                    style:TextStyle(fontWeight:FontWeight.w800,
                      color:c.actual.containsKey(id)?_navy:Colors.orange.shade700)),
                  if(c.actual.containsKey(id))Text(
                    'Δ '+stockText(c.difference(id)),style:TextStyle(
                      color:c.difference(id)==0?Colors.green:Colors.red)),
                ]),
              onTap:()=>countItem(ledger!.byId(id)!),
            )),
        const SizedBox(height:12),
        FilledButton.icon(onPressed:c.checked==0?null:finishCount,
          icon:const Icon(Icons.check_circle_outline),
          label:const Text('Завершить инвентаризацию')),
        TextButton.icon(onPressed:() async {
          if(await ask('Отменить пересчёт?',
            'Остатки останутся прежними. Результаты сохранятся в истории.',
            'Отменить')){
            await commit(()=>ledger!.cancelCount());
          }
        },icon:const Icon(Icons.cancel_outlined),label:const Text('Отменить пересчёт')),
      ],
    ]);
  }
  Widget history(){
    return ListView(padding:const EdgeInsets.all(14),children:[
      heading('История пересчётов','Отчёты и найденные расхождения'),
      if(ledger!.counts.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(20),
        child:Text('Инвентаризаций пока нет'))),
      for(final c in ledger!.counts)
        Card(child:ExpansionTile(
          title:Text(c.id,style:const TextStyle(fontWeight:FontWeight.bold)),
          subtitle:Text(c.startedAt.replaceFirst('T',' ').substring(0,16)+
            ' · '+(c.cancelled?'Отмена':c.isOpen?'В работе':'Завершена')+
            ' · '+c.checked.toString()+' позиций'),
          children:[
            for(final line in c.actual.entries)
              if(ledger!.byId(line.key)!=null)
                ListTile(dense:true,title:Text(ledger!.byId(line.key)!.name),
                  subtitle:Text('Учёт: '+stockText(c.expected[line.key]??0)+
                    '  ·  Факт: '+stockText(line.value)),
                  trailing:Text(stockText(c.difference(line.key)),
                    style:TextStyle(fontWeight:FontWeight.bold,
                      color:c.difference(line.key)==0?Colors.green:Colors.red))),
            TextButton.icon(onPressed:c.checked==0?null:()=>csv(c),
              icon:const Icon(Icons.file_download),
              label:const Text('Сохранить отчёт CSV')),
          ],
        )),
      OutlinedButton.icon(onPressed:backup,icon:const Icon(Icons.backup_outlined),
        label:const Text('Сохранить копию инвентаризации')),
      const SizedBox(height:16),
    ]);
  }
  @override Widget build(BuildContext context) {
    if(error!=null)return Center(child:Padding(padding:const EdgeInsets.all(24),
      child:Column(mainAxisSize:MainAxisSize.min,children:[
        const Icon(Icons.error_outline,color:Colors.red,size:44),
        const Text('Не удалось открыть данные инвентаризации',
          textAlign:TextAlign.center,style:TextStyle(fontWeight:FontWeight.bold)),
        Text(error!,textAlign:TextAlign.center),
        const Text('Данные не удалены. Не переустанавливай приложение без копии.'),
      ])));
    if(ledger==null)return const Center(child:CircularProgressIndicator());
    return Column(children:[
      if(writing)const LinearProgressIndicator(minHeight:2),
      Padding(padding:const EdgeInsets.fromLTRB(8,6,8,4),
        child:Row(children:[
          for(final (index,title,icon) in [
            (0,'Товары',Icons.inventory_2_outlined),
            (1,'Пересчёт',Icons.qr_code_scanner),
            (2,'История',Icons.history),
          ])Expanded(child:Padding(padding:const EdgeInsets.symmetric(horizontal:3),
            child:ChoiceChip(label:Text(title,style:const TextStyle(fontSize:12)),
              avatar:Icon(icon,size:16),selected:screen==index,
              onSelected:(_)=>setState(()=>screen=index))))],
        )),
      Expanded(child:IndexedStack(index:screen,
        children:[catalog(),counting(),history()])),
    ]);
  }
}
