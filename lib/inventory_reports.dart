import 'dart:io';
import 'dart:ui' as ui;
import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'inventory_model.dart';

Future<void> exportInventoryBackup(StockLedger ledger) async {
  final target=File('${(await getTemporaryDirectory()).path}/sklad_inventory_backup.json');
  await target.writeAsString(ledger.encode(),flush:true);
  await SharePlus.instance.share(ShareParams(
    files:[XFile(target.path)],
    text:'Резервная копия товаров, движений и инвентаризаций. Храни отдельно от телефона.',
  ));
}
String _csv(String s)=>'"${s.replaceAll('"','""')}"';
Future<void> exportInventoryCsv(StockLedger ledger,StockCount count) async {
  final rows=<String>['\uFEFFТовар;Код;Ед.;По учёту;Фактически;Расхождение;Место'];
  for(final entry in count.actual.entries){
    final p=ledger.byId(entry.key);
    if(p==null)continue;
    rows.add([
      _csv(p.name),_csv(p.id),_csv(p.unit),
      stockText(count.expected[p.id]??0),stockText(entry.value),
      stockText(count.difference(p.id)),_csv(p.location),
    ].join(';'));
  }
  final file=File('${(await getTemporaryDirectory()).path}/inventarizaciya_${count.id}.csv');
  await file.writeAsString(rows.join('\r\n'),flush:true);
  await SharePlus.instance.share(ShareParams(files:[XFile(file.path)]));
}

Future<void> showInventoryLabels(BuildContext context,StockProduct product) async {
  final key=GlobalKey();
  Future<void> printOrShare(bool print) async {
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary=key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if(boundary==null)throw StateError('Нет изображения этикетки');
      final image=await boundary.toImage(pixelRatio:3);
      final png=await image.toByteData(format:ui.ImageByteFormat.png);
      image.dispose();
      if(png==null)throw StateError('Не удалось создать этикетку');
      final document=pw.Document();
      document.addPage(pw.Page(pageFormat:PdfPageFormat.a6,
        margin:const pw.EdgeInsets.all(12),
        build:(_)=>pw.Center(child:pw.Image(
          pw.MemoryImage(png.buffer.asUint8List()),fit:pw.BoxFit.contain))));
      final bytes=await document.save();
      if(print){await Printing.layoutPdf(onLayout:(_)=>bytes,name:'Склад ${product.id}');}
      else {await Printing.sharePdf(bytes:bytes,filename:'label_${product.id}.pdf');}
    }catch(e){
      if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Ошибка этикетки: $e')));
    }
  }
  await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
    title:const Text('QR и штрихкод'),
    content:SingleChildScrollView(child:RepaintBoundary(key:key,
      child:Container(width:300,color:Colors.white,
        padding:const EdgeInsets.all(12),
        child:Column(mainAxisSize:MainAxisSize.min,children:[
          Text(product.name,textAlign:TextAlign.center,
            style:const TextStyle(color:Colors.black,fontSize:16,
              fontWeight:FontWeight.w800)),
          const SizedBox(height:12),
          BarcodeWidget(barcode:Barcode.qrCode(),data:product.id,
            width:128,height:128,drawText:false),
          const SizedBox(height:12),
          BarcodeWidget(barcode:Barcode.code128(),data:product.id,
            width:260,height:68,drawText:false,
            errorBuilder:(_,error)=>Text(error)),
          const SizedBox(height:7),
          Text(product.id,style:const TextStyle(color:Colors.black,
            fontWeight:FontWeight.bold)),
          if(product.location.isNotEmpty)Text(product.location,
            style:const TextStyle(color:Colors.black)),
        ])))),
    actions:[
      TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Закрыть')),
      TextButton(onPressed:()=>printOrShare(false),child:const Text('PDF')),
      FilledButton.icon(onPressed:()=>printOrShare(true),
        icon:const Icon(Icons.print),label:const Text('Печать')),
    ],
  ));
}
