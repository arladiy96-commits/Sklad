// Create required installable PWA PNG icons with Node built-ins only.
import {writeFile} from 'node:fs/promises';
import {deflateSync} from 'node:zlib';
const palette={navy:[18,41,59,255],inner:[39,71,91,255],gold:[239,180,80,255],left:[215,150,47,255]};
function insidePoly(x,y,poly) {
  let inside=false;
  for(let i=0,j=poly.length-1;i<poly.length;j=i++){
    const a=poly[i],b=poly[j];
    if(((a[1]>y)!==(b[1]>y))&&(x<(b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0]))inside=!inside;
  }
  return inside;
}
function rounded(x,y,left,top,right,bottom,r) {
  if(x<left||x>right||y<top||y>bottom)return false;
  const cx=Math.max(left+r,Math.min(right-r,x));
  const cy=Math.max(top+r,Math.min(bottom-r,y));
  return (x-cx)**2+(y-cy)**2<=r*r;
}
const top=[[256,105],[389,176],[256,247],[123,176]];
const left=[[123,176],[256,247],[256,401],[123,327]];
const right=[[389,176],[389,327],[256,401],[256,247]];
function crc32(buffer){
  let crc=0xffffffff;
  for(const b of buffer){
    crc^=b;
    for(let j=0;j<8;j++)crc=(crc&1)?(crc>>>1)^0xedb88320:crc>>>1;
  }
  return (crc^0xffffffff)>>>0;
}
function chunk(name,bytes){
  const tag=Buffer.from(name,'ascii'),size=Buffer.alloc(4);
  size.writeUInt32BE(bytes.length);
  const sum=Buffer.alloc(4);sum.writeUInt32BE(crc32(Buffer.concat([tag,bytes])));
  return Buffer.concat([size,tag,bytes,sum]);
}
function makePng(size){
  const rowLen=1+size*4;
  const raw=Buffer.alloc(rowLen*size);
  for(let y=0;y<size;y++)for(let x=0;x<size;x++){
    const u=(x+.5)*512/size,v=(y+.5)*512/size;
    let p=[0,0,0,0];
    if(rounded(u,v,0,0,512,512,112)){
      p=palette.navy;
      if(rounded(u,v,86,80,426,430,44))p=palette.inner;
      if(insidePoly(u,v,left))p=palette.left;
      if(insidePoly(u,v,right)||insidePoly(u,v,top))p=palette.gold;
    }
    const idx=y*rowLen+1+x*4;
    for(let c=0;c<4;c++)raw[idx+c]=p[c];
  }
  const ihdr=Buffer.alloc(13);
  ihdr.writeUInt32BE(size,0);ihdr.writeUInt32BE(size,4);
  ihdr[8]=8;ihdr[9]=6;
  return Buffer.concat([
    Buffer.from([137,80,78,71,13,10,26,10]),
    chunk('IHDR',ihdr),chunk('IDAT',deflateSync(raw)),chunk('IEND',Buffer.alloc(0))
  ]);
}
for(const size of [192,512]){
  await writeFile(new URL('../public/icon-'+size+'.png',import.meta.url),makePng(size));
}
console.log('Installable PWA PNG icons prepared');
