import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'core.dart';

const navy=Color(0xFF192C39);
const amber=Color(0xFFE8A12A);
const surface=Color(0xFFF3F6F7);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final data=Warehouse();
  await data.load();
  runApp(SkladApp(data));
}

class SkladApp extends StatelessWidget {
  final Warehouse data;
  const SkladApp(this.data,{super.key});
  @override
  Widget build(BuildContext context)=>MaterialApp(
    title:'Склад',debugShowCheckedModeBanner:false,
    theme:ThemeData(
      useMaterial3:true,scaffoldBackgroundColor:surface,
      colorScheme:ColorScheme.fromSeed(seedColor:navy,primary:navy,
        secondary:amber,surface:Colors.white),
      appBarTheme:const AppBarTheme(backgroundColor:surface,
        foregroundColor:navy,scrolledUnderElevation:0),
      cardTheme:CardThemeData(elevation:0,color:Colors.white,
        shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(18))),
      inputDecorationTheme:InputDecorationTheme(
        border:OutlineInputBorder(borderRadius:BorderRadius.circular(12)),
        contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:12)),
    ),
    home:WarehouseHome(data:data),
  );
}

class WarehouseHome extends StatefulWidget {
  final Warehouse data;
  const WarehouseHome({super.key,required this.data});
  @override
  State<WarehouseHome> createState()=>_WarehouseHomeState();
}

class _WarehouseHomeState extends State<WarehouseHome> {
  int tab=0;
  bool loading=false;
  final reportKey=GlobalKey();
  Warehouse get store=>widget.data;

  void message(String text) {
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text(text)));
  }
  Future<void> refresh() async {
    await store.save();
    if(mounted)setState((){});
  }
  Future<void> edit(Invoice? previous,{ScanData? scan,String imagePath=''}) async {
    final edited=await Navigator.push<Invoice>(context,MaterialPageRoute(
      builder:(_)=>InvoiceEditor(
        data:store,previous:previous,scan:scan,imagePath:imagePath)));
    if(edited==null)return;
    store.invoices.removeWhere((i)=>i.id==edited.id);
    store.invoices.add(edited);
    await refresh();
    if(mounted)setState(()=>tab=0);
  }

  Future<void> take(ImageSource source) async {
    if(loading)return;
    XFile? photo;
    try{
      photo=await ImagePicker().pickImage(source:source,imageQuality:95);
      if(photo==null)return;
      setState(()=>loading=true);
      final path=await store.keepPhoto(photo.path);
      ScanData scanned;
      try{
        scanned=await Scanner().scan(path,store.catalog.keys.toSet());
      }catch(e){
        scanned=ScanData('',[]);
        if(mounted)message('Распознавание не удалось. Введи позиции вручную: $e');
      }
      if(!mounted)return;
      setState(()=>loading=false);
      await edit(null,scan:scanned,imagePath:path);
    }catch(e){
      if(mounted)message('Ошибка камеры: $e');
    }finally{
      if(mounted)setState(()=>loading=false);
    }
  }

  Future<void> removeInvoice(Invoice invoice) async {
    final approved=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Удалить накладную?'),
      content:Text('Накладная '+invoice.number+' исчезнет из общей ведомости.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Отмена')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Удалить'))]));
    if(approved!=true)return;
    store.invoices.removeWhere((e)=>e.id==invoice.id);
    await refresh();
  }

  Future<void> finishBatch() async {
    if(store.invoices.isEmpty)return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Закончить текущую сборку?'),
      content:const Text('Накладные сохранятся в истории, а новая сборка начнётся с нуля.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Отмена')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Завершить')),
      ]));
    if(ok!=true)return;
    store.finishBatch();
    await refresh();
    message('Сборка сохранена в истории');
  }

  Future<void> restoreBatch(int index) async {
    if(store.invoices.isNotEmpty){
      message('Сначала заверши текущую сборку');return;
    }
    final old=store.history.removeAt(index);
    store.invoices=store.batchInvoices(old);
    await refresh();
    message('Сборка восстановлена для редактирования');
  }

  Future<Uint8List> renderPdf() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary=reportKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if(boundary==null)throw StateError('Открой вкладку «Ведомость»');
    final image=await boundary.toImage(pixelRatio:3);
    final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
    image.dispose();
    if(bytes==null)throw StateError('Не удалось сделать изображение ведомости');
    final doc=pw.Document();
    doc.addPage(pw.Page(pageFormat:PdfPageFormat.a4,
      margin:const pw.EdgeInsets.all(18),
      build:(_)=>pw.Center(child:pw.Image(pw.MemoryImage(
        bytes.buffer.asUint8List()),fit:pw.BoxFit.contain))));
    return doc.save();
  }

  Future<void> export({required bool print}) async {
    try{
      final pdf=await renderPdf();
      if(print){
        await Printing.layoutPdf(onLayout:(_)=>pdf,name:'Склад — сборочная ведомость');
      }else{
        await Printing.sharePdf(bytes:pdf,filename:'sklad_vedomost.pdf');
      }
    }catch(e){message('Ошибка PDF: $e');}
  }

  @override
  Widget build(BuildContext context){
    final totalLines=summary(store.invoices,store.products);
    return Scaffold(
      appBar:AppBar(
        title:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('СКЛАД',style:TextStyle(fontWeight:FontWeight.w900,letterSpacing:2)),
          Text('Сборочные ведомости',style:TextStyle(fontSize:12,
            fontWeight:FontWeight.w400))]),
        actions:[if(loading)const Padding(padding:EdgeInsets.all(16),
          child:SizedBox(width:22,height:22,child:CircularProgressIndicator(strokeWidth:2)))],
      ),
      body:IndexedStack(index:tab,children:[
        homePage(totalLines),
        reportPage(totalLines),
        catalogPage(),
      ]),
      bottomNavigationBar:NavigationBar(selectedIndex:tab,
        onDestinationSelected:(i)=>setState(()=>tab=i),
        destinations:const [
          NavigationDestination(icon:Icon(Icons.receipt_long_outlined),
            selectedIcon:Icon(Icons.receipt_long),label:'Накладные'),
          NavigationDestination(icon:Icon(Icons.assignment_outlined),
            selectedIcon:Icon(Icons.assignment),label:'Ведомость'),
          NavigationDestination(icon:Icon(Icons.inventory_2_outlined),
            selectedIcon:Icon(Icons.inventory_2),label:'Товары'),
        ]),
    );
  }

  Widget homePage(List<PickLine> lines){
    final total=lines.fold<int>(0,(v,e)=>v+e.total);
    final invoices=store.invoices.reversed.toList();
    return ListView(padding:const EdgeInsets.all(16),children:[
      Container(padding:const EdgeInsets.all(20),
        decoration:BoxDecoration(color:navy,borderRadius:BorderRadius.circular(22)),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('ТЕКУЩАЯ СБОРКА',style:TextStyle(color:amber,fontSize:12,
            letterSpacing:1.5,fontWeight:FontWeight.bold)),
          const SizedBox(height:18),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            counter('Накладных',store.invoices.length),
            counter('Позиций',lines.length),
            counter('Мешков',total),
          ]),
        ])),
      const SizedBox(height:16),
      FilledButton.icon(onPressed:loading?null:()=>take(ImageSource.camera),
        icon:const Icon(Icons.camera_alt_outlined),
        label:const Text('Сфотографировать накладную'),
        style:FilledButton.styleFrom(padding:const EdgeInsets.all(18),
          backgroundColor:navy,foregroundColor:Colors.white)),
      const SizedBox(height:8),
      Row(children:[
        Expanded(child:OutlinedButton.icon(
          onPressed:loading?null:()=>take(ImageSource.gallery),
          icon:const Icon(Icons.photo_library_outlined),
          label:const Text('Из галереи'))),
        const SizedBox(width:8),
        Expanded(child:OutlinedButton.icon(
          onPressed:loading?null:()=>edit(null),
          icon:const Icon(Icons.edit_note),label:const Text('Вручную'))),
      ]),
      if(store.invoices.isNotEmpty)
        TextButton.icon(onPressed:finishBatch,icon:const Icon(Icons.archive_outlined),
          label:const Text('Завершить сборку и начать новую')),
      const SizedBox(height:26),
      const Text('Добавленные накладные',style:TextStyle(
        fontSize:19,fontWeight:FontWeight.bold,color:navy)),
      const SizedBox(height:10),
      if(invoices.isEmpty)
        const Card(child:Padding(padding:EdgeInsets.all(25),
          child:Text('Пока пусто. Сфотографируй первую накладную или введи позиции вручную.',
            textAlign:TextAlign.center))),
      for(final invoice in invoices)
        Card(child:ListTile(
          leading:const CircleAvatar(child:Icon(Icons.description_outlined)),
          title:Text(invoice.number.isEmpty?'Без номера':invoice.number),
          subtitle:Text(invoice.items.length.toString()+' позиций · '+
            invoice.items.fold<int>(0,(v,i)=>v+(i.bags(store.catalog)?.round()??0)).toString()+' мешков'),
          onTap:()=>edit(invoice),
          trailing:IconButton(icon:const Icon(Icons.delete_outline),
            tooltip:'Удалить',onPressed:()=>removeInvoice(invoice)),
        )),
      if(store.history.isNotEmpty)...[
        const SizedBox(height:18),
        const Text('История сборок',style:TextStyle(
          fontSize:19,fontWeight:FontWeight.bold,color:navy)),
        const SizedBox(height:8),
        for(var i=0;i<store.history.length;i++)
          Card(child:ExpansionTile(
            title:Text('Сборка '+(store.history[i]['finishedAt'] as String).substring(0,16).replaceAll('T',' ')),
            subtitle:Text(store.batchInvoices(store.history[i]).length.toString()+' накладных'),
            children:[
              for(final p in summary(store.batchInvoices(store.history[i]),store.products))
                ListTile(dense:true,title:Text(p.product.name),
                  trailing:Text(p.total.toString()+' шт.')),
              TextButton.icon(onPressed:()=>restoreBatch(i),
                icon:const Icon(Icons.restore),label:const Text('Вернуть на редактирование')),
            ],
          )),
      ],
      const SizedBox(height:20),
    ]);
  }

  Widget counter(String title,int value)=>Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(value.toString(),style:const TextStyle(color:Colors.white,
        fontSize:30,fontWeight:FontWeight.w800)),
      Text(title,style:const TextStyle(color:Color(0xFFBFD0D6),fontSize:11)),
    ]);

  Widget reportPage(List<PickLine> lines) {
    final count=lines.fold<int>(0,(v,e)=>v+e.total);
    return ListView(padding:const EdgeInsets.all(16),children:[
      Row(children:[
        const Expanded(child:Text('Итоговая ведомость',
          style:TextStyle(fontSize:21,fontWeight:FontWeight.bold,color:navy))),
        IconButton(onPressed:lines.isEmpty?null:()=>export(print:false),
          tooltip:'Поделиться PDF',icon:const Icon(Icons.share_outlined)),
        IconButton(onPressed:lines.isEmpty?null:()=>export(print:true),
          tooltip:'Печать',icon:const Icon(Icons.print_outlined)),
      ]),
      const SizedBox(height:10),
      RepaintBoundary(key:reportKey,child:Container(
        color:Colors.white,padding:const EdgeInsets.all(18),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          const Center(child:Text('СБОРОЧНАЯ ВЕДОМОСТЬ',
            style:TextStyle(fontSize:19,fontWeight:FontWeight.w900,color:navy))),
          const SizedBox(height:5),
          Center(child:Text('Накладных: '+store.invoices.length.toString(),
            style:const TextStyle(fontSize:12))),
          const SizedBox(height:18),
          if(lines.isEmpty)const Padding(padding:EdgeInsets.all(18),
            child:Text('Добавь накладные — ведомость появится здесь.',
              textAlign:TextAlign.center)),
          for(var i=0;i<lines.length;i++)...[
            Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
              SizedBox(width:28,child:Text((i+1).toString()+'.',
                style:const TextStyle(fontSize:13))),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(lines[i].product.name,style:const TextStyle(
                  fontWeight:FontWeight.bold,fontSize:13)),
                const SizedBox(height:3),
                Text(lines[i].additions.join(' + ')+' = '+lines[i].total.toString()+' меш.',
                  style:const TextStyle(fontSize:12,color:navy)),
              ])),
              const SizedBox(width:5),
              Text(lines[i].total.toString()+' шт.',
                style:const TextStyle(fontSize:17,fontWeight:FontWeight.w900,color:navy)),
            ]),
            const Divider(height:18),
          ],
          const SizedBox(height:12),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            const Text('ИТОГО МЕШКОВ:',style:TextStyle(
              fontWeight:FontWeight.w900,fontSize:15)),
            Text(count.toString(),style:const TextStyle(fontSize:22,
              fontWeight:FontWeight.w900,color:navy)),
          ]),
          const SizedBox(height:12),
          const Text('Собрано: _____________________   Проверено: _____________________',
            style:TextStyle(fontSize:10)),
        ]),
      )),
      const SizedBox(height:15),
      if(lines.isNotEmpty)
        FilledButton.icon(onPressed:()=>export(print:false),
          icon:const Icon(Icons.picture_as_pdf),label:const Text('Отправить PDF')),
      if(lines.isNotEmpty)
        OutlinedButton.icon(onPressed:()=>export(print:true),
          icon:const Icon(Icons.print),label:const Text('Распечатать')),
    ]);
  }

  Widget catalogPage() {
    final sorted=[...store.products]..sort((a,b)=>a.name.compareTo(b.name));
    return ListView(padding:const EdgeInsets.all(16),children:[
      Row(children:[
        const Expanded(child:Text('Справочник товаров',style:TextStyle(
          fontSize:21,fontWeight:FontWeight.bold,color:navy))),
        IconButton(icon:const Icon(Icons.add_circle_outline),
          tooltip:'Добавить товар',onPressed:()=>editProduct()),
      ]),
      const Text('Код определяет наименование и вес мешка. Цены берём из накладных.',
        style:TextStyle(color:Colors.black54)),
      const SizedBox(height:12),
      for(final p in sorted)
        Card(child:ListTile(
          title:Text(p.name,style:const TextStyle(fontWeight:FontWeight.w600)),
          subtitle:Text(p.code+' · '+qty(p.bag)+' кг'+
            (p.confirmed?'':' · код не подтверждён')),
          trailing:const Icon(Icons.edit_outlined),
          onTap:()=>editProduct(p),
        )),
      const SizedBox(height:20),
    ]);
  }

  Future<void> editProduct([Product? old]) async {
    final codeController=TextEditingController(text:old?.code??'');
    final nameController=TextEditingController(text:old?.name??'');
    final bagController=TextEditingController(text:old==null?'':qty(old.bag));
    var active=old?.active??true;
    var confirmed=old?.confirmed??false;
    final newItem=await showDialog<Product>(context:context,builder:(ctx)=>
      StatefulBuilder(builder:(ctx,change)=>AlertDialog(
        title:Text(old==null?'Новый товар':'Изменить товар'),
        content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:codeController,textCapitalization:TextCapitalization.characters,
            decoration:const InputDecoration(labelText:'Код (H00001955)')),
          const SizedBox(height:10),
          TextField(controller:nameController,decoration:const InputDecoration(labelText:'Название')),
          const SizedBox(height:10),
          TextField(controller:bagController,keyboardType:const TextInputType.numberWithOptions(decimal:true),
            decoration:const InputDecoration(labelText:'Вес мешка, кг')),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Активен'),
            value:active,onChanged:(v)=>change(()=>active=v)),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Проверен складом'),
            value:confirmed,onChanged:(v)=>change(()=>confirmed=v)),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Отмена')),
          FilledButton(onPressed:(){
            final code=codeOf(codeController.text);
            final name=nameController.text.trim();
            final bag=numeric(bagController.text);
            if(!RegExp(r'^H[0-9]{8}$').hasMatch(code) ||
              name.isEmpty || bag==null || bag<=0 ||
              store.products.any((e)=>e.code==code && e.code!=old?.code)) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content:Text('Проверь код, название, фасовку и уникальность кода')));
              return;
            }
            Navigator.pop(ctx,Product(code,name,bag,
              active:active,confirmed:confirmed));
          },child:const Text('Сохранить')),
        ],
      )));
    codeController.dispose();nameController.dispose();bagController.dispose();
    if(newItem==null)return;
    if(old!=null){
      final idx=store.products.indexOf(old);
      if(idx>=0)store.products[idx]=newItem;
    }else{store.products.add(newItem);}
    await refresh();
  }
}

class InvoiceEditor extends StatefulWidget {
  final Warehouse data;
  final Invoice? previous;
  final ScanData? scan;
  final String imagePath;
  const InvoiceEditor({super.key,required this.data,
    this.previous,this.scan,this.imagePath=''});
  @override
  State<InvoiceEditor> createState()=>_InvoiceEditorState();
}
class _InvoiceEditorState extends State<InvoiceEditor> {
  late final TextEditingController numberController;
  late final List<Item> items;
  @override
  void initState() {
    super.initState();
    numberController=TextEditingController(
      text:widget.previous?.number??widget.scan?.number??'');
    items=widget.previous?.items.map((e)=>Item(e.code,e.kg,
      price:e.price,amount:e.amount,raw:e.raw)).toList() ??
      widget.scan?.items ?? [];
  }
  @override
  void dispose(){numberController.dispose();super.dispose();}
  void addRow()=>setState(()=>items.add(Item('',0)));
  Future<void> save() async {
    final number=numberController.text.trim();
    if(items.isEmpty){
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Добавь хотя бы одну позицию')));
      return;
    }
    if(widget.data.duplicate(number,widget.previous?.id)){
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:Text('Накладная с таким номером уже добавлена')));
      return;
    }
    for(var i=0;i<items.length;i++){
      final problem=items[i].problem(widget.data.catalog);
      if(problem!=null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:Text('Строка '+(i+1).toString()+': '+problem)));
        return;
      }
    }
    final id=widget.previous?.id??DateTime.now().microsecondsSinceEpoch.toString();
    final invoice=Invoice(id,
      number.isEmpty?'Без номера '+id.substring(id.length-5):number,
      widget.previous?.imagePath??widget.imagePath,
      widget.previous?.createdAt??DateTime.now().toIso8601String(),
      items);
    Navigator.pop(context,invoice);
  }

  @override
  Widget build(BuildContext context) {
    final catalog=widget.data.catalog;
    final options=widget.data.products.where((p)=>p.active).toList()
      ..sort((a,b)=>a.name.compareTo(b.name));
    final total=items.fold<int>(0,(a,e)=>a+(e.bags(catalog)?.round()??0));
    return Scaffold(
      appBar:AppBar(title:Text(widget.previous==null?'Новая накладная':'Редактировать накладную')),
      bottomNavigationBar:SafeArea(minimum:const EdgeInsets.all(12),
        child:FilledButton.icon(onPressed:save,icon:const Icon(Icons.check),
          label:const Text('Подтвердить и добавить'),
          style:FilledButton.styleFrom(padding:const EdgeInsets.all(16)))),
      body:ListView(padding:const EdgeInsets.all(14),children:[
        if(widget.imagePath.isNotEmpty || (widget.previous?.imagePath.isNotEmpty??false))
          Card(clipBehavior:Clip.antiAlias,child:Column(children:[
            SizedBox(height:190,width:double.infinity,
              child:Image.file(File(widget.previous?.imagePath??widget.imagePath),
                fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Center(
                  child:Text('Исходное фото недоступно')))),
            const Padding(padding:EdgeInsets.all(8),
              child:Text('Сверь цифры с фотографией перед подтверждением',
                style:TextStyle(fontSize:12,color:Colors.black54))),
          ])),
        TextField(controller:numberController,decoration:const InputDecoration(
          labelText:'Номер накладной',prefixIcon:Icon(Icons.tag))),
        const SizedBox(height:14),
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          Text('Позиции: '+items.length.toString(),style:const TextStyle(
            fontSize:17,fontWeight:FontWeight.bold)),
          Text('Мешков: '+total.toString(),style:const TextStyle(fontSize:16,
            fontWeight:FontWeight.bold,color:navy)),
        ]),
        if(widget.scan!=null && widget.scan!.items.isEmpty)
          const Card(child:Padding(padding:EdgeInsets.all(12),
            child:Text('OCR не нашёл строки. Добавь товар вручную. Исходное фото сохранено.'))),
        for(var i=0;i<items.length;i++)itemCard(items[i],i,options,catalog),
        OutlinedButton.icon(onPressed:addRow,icon:const Icon(Icons.add),
          label:const Text('Добавить позицию')),
        const SizedBox(height:20),
      ]),
    );
  }

  Widget itemCard(Item item,int index,List<Product> options,Map<String,Product> catalog){
    final error=item.problem(catalog);
    final chosen=catalog.containsKey(codeOf(item.code)) ? codeOf(item.code) : null;
    return Card(key:ObjectKey(item),child:Padding(padding:const EdgeInsets.all(12),child:Column(
      crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[
          Expanded(child:Text('ПОЗИЦИЯ '+(index+1).toString(),
            style:const TextStyle(fontWeight:FontWeight.bold,color:navy))),
          IconButton(onPressed:()=>setState(()=>items.remove(item)),
            icon:const Icon(Icons.close),tooltip:'Убрать строку'),
        ]),
        DropdownButtonFormField<String>(
          value:chosen, isExpanded:true,
          decoration:const InputDecoration(labelText:'Товар и код'),
          hint:Text(item.code.isEmpty?'Выбери товар':'OCR: '+item.code+' — выбери правильный'),
          items:options.map((p)=>DropdownMenuItem(value:p.code,
            child:Text(p.name+' · '+p.code,overflow:TextOverflow.ellipsis))).toList(),
          onChanged:(v)=>setState(()=>item.code=v??''),
        ),
        const SizedBox(height:10),
        Row(children:[
          Expanded(child:TextFormField(
            key:ValueKey(item.hashCode.toString()+'_kg'),
            initialValue:item.kg==0?'':qty(item.kg),
            keyboardType:const TextInputType.numberWithOptions(decimal:true),
            decoration:const InputDecoration(labelText:'Количество, кг'),
            onChanged:(v)=>setState(()=>item.kg=numeric(v)??0))),
          const SizedBox(width:8),
          Expanded(child:InputDecorator(
            decoration:const InputDecoration(labelText:'Мешков'),
            child:Text(item.bags(catalog)==null?'—':qty(item.bags(catalog)!),
              style:const TextStyle(fontWeight:FontWeight.bold,fontSize:17)))),
        ]),
        const SizedBox(height:10),
        Row(children:[
          Expanded(child:TextFormField(initialValue:item.price==null?'':qty(item.price!),
            keyboardType:const TextInputType.numberWithOptions(decimal:true),
            decoration:const InputDecoration(labelText:'Цена (необяз.)'),
            onChanged:(v)=>setState(()=>item.price=numeric(v)))),
          const SizedBox(width:8),
          Expanded(child:TextFormField(initialValue:item.amount==null?'':qty(item.amount!),
            keyboardType:const TextInputType.numberWithOptions(decimal:true),
            decoration:const InputDecoration(labelText:'Сумма (необяз.)'),
            onChanged:(v)=>setState(()=>item.amount=numeric(v)))),
        ]),
        if(error!=null)Padding(padding:const EdgeInsets.only(top:8),
          child:Text(error,style:const TextStyle(color:Colors.deepOrange,
            fontWeight:FontWeight.w600,fontSize:12))),
        if(item.raw.isNotEmpty)Padding(padding:const EdgeInsets.only(top:6),
          child:Text('OCR: '+item.raw,style:const TextStyle(fontSize:10,
            color:Colors.black45))),
      ]),
    ));
  }
}
