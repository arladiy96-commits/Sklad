import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

Future<String?> requestCode(BuildContext context) =>
    Navigator.push<String>(context,MaterialPageRoute(builder:(_)=>const CodeScanner()));

Future<String?> enterCode(BuildContext context) async {
  final controller=TextEditingController();
  final result=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
    title:const Text('Ввести штрихкод или QR'),
    content:TextField(controller:controller,autofocus:true,
      decoration:const InputDecoration(labelText:'Код с упаковки')),
    actions:[
      TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Отмена')),
      FilledButton(onPressed:()=>Navigator.pop(ctx,controller.text.trim()),
        child:const Text('Продолжить')),
    ],
  ));
  controller.dispose();
  return result==null||result.trim().isEmpty?null:result.trim();
}

class CodeScanner extends StatefulWidget {
  const CodeScanner({super.key});
  @override State<CodeScanner> createState()=>_CodeScannerState();
}
class _CodeScannerState extends State<CodeScanner> {
  bool received=false;
  void accept(String? value) {
    if(received||value==null||value.trim().isEmpty)return;
    received=true;
    Navigator.of(context).pop(value.trim());
  }
  Future<void> manual() async {
    final value=await enterCode(context);
    if(mounted)accept(value);
  }
  @override Widget build(BuildContext context)=>Scaffold(
    backgroundColor:Colors.black,
    appBar:AppBar(title:const Text('Сканирование'),backgroundColor:Colors.black,
      foregroundColor:Colors.white),
    body:Stack(children:[
      MobileScanner(
        onDetect:(capture){
          for(final b in capture.barcodes){
            if(b.rawValue!=null&&b.rawValue!.trim().isNotEmpty){
              accept(b.rawValue);break;
            }
          }
        },
        errorBuilder:(ctx,error)=>Center(child:Padding(
          padding:const EdgeInsets.all(24),
          child:Text('Не удалось открыть камеру: $error',
            textAlign:TextAlign.center,style:const TextStyle(color:Colors.white)))),
      ),
      Center(child:IgnorePointer(child:Container(width:260,height:180,
        decoration:BoxDecoration(
          border:Border.all(color:const Color(0xFFE8A12A),width:3),
          borderRadius:BorderRadius.circular(16))))),
      Positioned(left:12,right:12,bottom:45,child:Column(children:[
        const Text('Наведи камеру на QR, EAN или Code 128',
          textAlign:TextAlign.center,style:TextStyle(color:Colors.white)),
        const SizedBox(height:14),
        FilledButton.icon(onPressed:manual,icon:const Icon(Icons.keyboard),
          label:const Text('Ввести код вручную')),
      ])),
    ]),
  );
}
