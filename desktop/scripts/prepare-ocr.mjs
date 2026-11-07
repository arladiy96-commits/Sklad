import {mkdir,copyFile,readdir,access,writeFile,rename,unlink} from 'node:fs/promises';

const dest=new URL('../public/ocr/',import.meta.url);
await mkdir(dest,{recursive:true});
const worker=new URL('../node_modules/tesseract.js/dist/worker.min.js',import.meta.url);
await copyFile(worker,new URL('worker.min.js',dest));
const core=new URL('../node_modules/tesseract.js-core/',import.meta.url);
for(const file of await readdir(core)){
  if(/^tesseract-core.*\.(?:js|wasm)$/.test(file))await copyFile(new URL(file,core),new URL(file,dest));
}
async function download(lang){
  const target=new URL(lang+'.traineddata.gz',dest);
  try{await access(target);return;}catch{}
  const url='https://tessdata.projectnaptha.com/4.0.0/'+lang+'.traineddata.gz';
  const result=await fetch(url);
  if(!result.ok)throw Error('Не удалось скачать модель '+lang+': HTTP '+result.status);
  const bytes=new Uint8Array(await result.arrayBuffer());
  if(bytes.length<100000)throw Error('Слишком маленький файл модели: '+lang);
  const temp=new URL(lang+'.tmp',dest);
  try{await writeFile(temp,bytes);await rename(temp,target);}
  catch(e){await unlink(temp).catch(()=>{});throw e;}
  console.log('OCR model '+lang+': '+(bytes.length/1024/1024).toFixed(1)+' MB');
}
await Promise.all(['eng','rus'].map(download));
console.log('Offline OCR assets prepared');
