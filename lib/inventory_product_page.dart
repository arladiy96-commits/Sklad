import 'package:flutter/material.dart';
import 'inventory_model.dart';
import 'inventory_scanner.dart';
import 'inventory_reports.dart';

typedef StockCommit=Future<bool> Function(void Function());

class StockDraft {
  final String name,unit,location,category;
  final bool active;
  StockDraft(this.name,this.unit,this.location,this.category,this.active);
}
Future<StockDraft?> stockProductForm(BuildContext context,[StockProduct? old]) async {
  final name=TextEditingController(text:old?.name??'');
  final unit=TextEditingController(text:old?.unit??'шт');
  final location=TextEditingController(text:old?.location??'');
  final category=TextEditingController(text:old?.category??'');
  bool active=old?.active??true;
  final draft=await showDialog<StockDraft>(context:context,builder:(ctx)=>
    StatefulBuilder(builder:(ctx,change)=>AlertDialog(
      title:Text(old==null?'Новый товар':'Карточка товара'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,decoration:const InputDecoration(labelText:'Название *')),
        const SizedBox(height:10),
        TextField(controller:unit,decoration:const InputDecoration(labelText:'Единица *',
          hintText:'шт, кг, меш, м, л')),
        const SizedBox(height:10),
        TextField(controller:location,decoration:const InputDecoration(labelText:'Место хранения')),
        const SizedBox(height:10),
        TextField(controller:category,decoration:const InputDecoration(labelText:'Категория')),
        if(old!=null)SwitchListTile(value:active,title:const Text('Активен'),
          contentPadding:EdgeInsets.zero,onChanged:(v)=>change(()=>active=v)),
      ])),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Отмена')),
        FilledButton(onPressed:(){
          if(name.text.trim().isEmpty||unit.text.trim().isEmpty)return;
          Navigator.pop(ctx,StockDraft(name.text,unit.text,
            location.text,category.text,active));
        },child:const Text('Сохранить')),
      ],
    )));
  name.dispose();unit.dispose();location.dispose();category.dispose();
  return draft;
}
class StockProductPage extends StatefulWidget {
  final String id;
  final StockLedger Function() ledger;
  final StockCommit commit;
  const StockProductPage({super.key,required this.id,required this.ledger,required this.commit});
  @override State<StockProductPage> createState()=>_StockProductPageState();
}
class _StockProductPageState extends State<StockProductPage> {
  StockProduct get p=>widget.ledger().byId(widget.id)!;
  void notify(String s) {
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  }
  Future<bool> ask(String title,String body) async =>await showDialog<bool>(
    context:context,builder:(ctx)=>AlertDialog(title:Text(title),content:Text(body),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Отмена')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Да')),
      ]))??false;
  Future<void> edit() async {
    final draft=await stockProductForm(context,p);
    if(draft==null)return;
    if(await widget.commit(()=>widget.ledger().updateProduct(p.id,
      name:draft.name,unit:draft.unit,location:draft.location,
      category:draft.category,active:draft.active))&&mounted)setState((){});
  }
  Future<void> movement(bool receipt) async {
    final qtyController=TextEditingController();
    final noteController=TextEditingController();
    final result=await showDialog<(double,String)>(context:context,builder:(ctx)=>
      AlertDialog(title:Text(receipt?'Приход':'Расход'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          Text(p.name,style:const TextStyle(fontWeight:FontWeight.bold)),
          Text('Остаток: '+stockText(widget.ledger().balance(p.id))+' '+p.unit),
          const SizedBox(height:10),
          TextField(controller:qtyController,autofocus:true,
            keyboardType:const TextInputType.numberWithOptions(decimal:true),
            decoration:InputDecoration(labelText:'Количество ('+p.unit+')')),
          const SizedBox(height:10),
          TextField(controller:noteController,
            decoration:const InputDecoration(labelText:'Примечание')),
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Отмена')),
          FilledButton(onPressed:(){
            final q=readStockQty(qtyController.text);
            if(q==null||q<=0){
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content:Text('Введи количество больше нуля')));
              return;
            }
            Navigator.pop(ctx,(q,noteController.text));
          },child:const Text('Записать')),
        ],
      ));
    qtyController.dispose();noteController.dispose();
    if(result==null||!mounted)return;
    if(await widget.commit(()=>widget.ledger().move(p.id,result.$1,
      receipt:receipt,note:result.$2))&&mounted){
      setState((){});notify('Движение сохранено');
    }
  }
  Future<void> link(bool manual) async {
    final code=manual?await enterCode(context):await requestCode(context);
    if(code==null||!mounted)return;
    if(await widget.commit(()=>widget.ledger().addCode(p.id,code))&&mounted){
      setState((){});notify('Код привязан');
    }
  }
  Future<void> unlink(String code) async {
    if(!await ask('Отвязать код?',code))return;
    if(await widget.commit(()=>widget.ledger().removeCode(p.id,code))&&mounted)setState((){});
  }
  @override Widget build(BuildContext context) {
    final item=p;
    final moves=widget.ledger().movements.reversed
      .where((m)=>m.productId==item.id).take(100).toList();
    const navy=Color(0xFF192C39);
    return Scaffold(
      appBar:AppBar(title:const Text('Карточка товара'),actions:[
        IconButton(onPressed:edit,icon:const Icon(Icons.edit_outlined)),
      ]),
      body:ListView(padding:const EdgeInsets.all(14),children:[
        Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(item.name,style:const TextStyle(fontSize:22,
              fontWeight:FontWeight.w800,color:navy)),
            const SizedBox(height:6),
            Text(item.category.isEmpty?'Без категории':item.category),
            if(item.location.isNotEmpty)Text('Место: '+item.location),
            if(!item.active)const Text('Товар отключён',style:TextStyle(color:Colors.red)),
            const SizedBox(height:16),
            Text(stockText(widget.ledger().balance(item.id))+' '+item.unit,
              style:const TextStyle(fontSize:30,fontWeight:FontWeight.w800,color:navy)),
            const Text('Текущий остаток',style:TextStyle(color:Colors.black54)),
          ]))),
        const SizedBox(height:10),
        Row(children:[
          Expanded(child:FilledButton.icon(
            onPressed:widget.ledger().current!=null||!item.active?null:()=>movement(true),
            icon:const Icon(Icons.add),label:const Text('Приход'))),
          const SizedBox(width:8),
          Expanded(child:OutlinedButton.icon(
            onPressed:widget.ledger().current!=null||!item.active?null:()=>movement(false),
            icon:const Icon(Icons.remove),label:const Text('Расход'))),
        ]),
        if(widget.ledger().current!=null)const Text(
          'На время инвентаризации приход и расход заблокированы'),
        const SizedBox(height:10),
        FilledButton.tonalIcon(onPressed:()=>showInventoryLabels(context,item),
          icon:const Icon(Icons.qr_code_2),
          label:const Text('QR + штрихкод · распечатать')),
        const SizedBox(height:14),
        Row(children:[
          const Expanded(child:Text('Привязанные коды',
            style:TextStyle(fontWeight:FontWeight.w800,fontSize:17))),
          PopupMenuButton<bool>(tooltip:'Добавить код',onSelected:link,
            itemBuilder:(_)=>[
              const PopupMenuItem(value:false,child:Text('Сканировать')),
              const PopupMenuItem(value:true,child:Text('Ввести вручную')),
            ],child:const Icon(Icons.add_circle_outline)),
        ]),
        for(final code in item.codes)Card(child:ListTile(
          title:Text(code),
          subtitle:Text(code==item.id?'Внутренний QR / Code 128':'Заводской или другой код'),
          leading:Icon(code==item.id?Icons.qr_code:Icons.barcode_reader),
          trailing:code==item.id?null:IconButton(icon:const Icon(Icons.close),
            onPressed:()=>unlink(code)),
        )),
        const SizedBox(height:12),
        const Text('История движений',
          style:TextStyle(fontSize:17,fontWeight:FontWeight.w800)),
        if(moves.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(16),
          child:Text('Операций пока нет'))),
        for(final m in moves)ListTile(
          title:Text(m.kind=='receipt'?'Приход':m.kind=='issue'?'Расход':'Инвентаризация'),
          subtitle:Text(m.timestamp.replaceFirst('T',' ').substring(0,16)+
            (m.note.isEmpty?'':' · '+m.note)),
          trailing:Text((m.delta>0?'+':'')+stockText(m.delta),
            style:TextStyle(fontWeight:FontWeight.bold,
              color:m.delta<0?Colors.red:navy)),
        ),
      ]),
    );
  }
}
