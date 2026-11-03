// Original Kids Quota hourglass artwork, rendered from simple vector geometry.
// This dependency-free renderer keeps the PNG assets reproducible on any build
// machine; no external fonts, image service, or downloaded artwork is used.
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {deflateSync} from 'node:zlib';

function crc32(bytes) {
  let crc=0xffffffff;
  for(const byte of bytes) {
    crc^=byte;
    for(let bit=0;bit<8;bit++) crc=(crc>>>1)^((crc&1)?0xedb88320:0);
  }
  return (crc^0xffffffff)>>>0;
}
function chunk(type,data) {
  const name=Buffer.from(type), length=Buffer.alloc(4), checksum=Buffer.alloc(4);
  length.writeUInt32BE(data.length); checksum.writeUInt32BE(crc32(Buffer.concat([name,data])));
  return Buffer.concat([length,name,data,checksum]);
}
function insidePolygon(x,y,vertices) {
  let inside=false;
  for(let i=0,j=vertices.length-1;i<vertices.length;j=i++) {
    const [xi,yi]=vertices[i],[xj,yj]=vertices[j];
    if((yi>y)!==(yj>y) && x<(xj-xi)*(y-yi)/(yj-yi)+xi) inside=!inside;
  }
  return inside;
}
function colorAt(x,y) {
  const dx=Math.max(30-x,0,x-98),dy=Math.max(30-y,0,y-98);
  if(dx*dx+dy*dy>22*22) return [0,0,0,0];
  const white=[250,253,255,255], sand=[93,224,211,255];
  if((x>=37 && x<=91 && ((y>=32 && y<=39)||(y>=89 && y<=96))) ||
    insidePolygon(x,y,[[42,39],[86,39],[82,52],[70,64],[82,76],[86,89],[42,89],[46,76],[58,64],[46,52]])) {
    if(insidePolygon(x,y,[[51,46],[77,46],[64,59]]) || insidePolygon(x,y,[[64,69],[77,82],[51,82]])) return sand;
    return white;
  }
  return [25,78,143,255];
}
export function renderIcon(size) {
  const samples=4, scan=Buffer.alloc((size*4+1)*size);
  for(let row=0;row<size;row++) for(let column=0;column<size;column++) {
    const totals=[0,0,0,0];
    for(let sy=0;sy<samples;sy++) for(let sx=0;sx<samples;sx++) {
      const rgba=colorAt((column+(sx+.5)/samples)*128/size,(row+(sy+.5)/samples)*128/size);
      for(let channel=0;channel<3;channel++) totals[channel]+=rgba[channel]*rgba[3];
      totals[3]+=rgba[3];
    }
    const offset=row*(size*4+1)+1+column*4;
    for(let channel=0;channel<3;channel++) scan[offset+channel]=totals[3]?Math.round(totals[channel]/totals[3]):0;
    scan[offset+3]=Math.round(totals[3]/(samples*samples));
  }
  const header=Buffer.alloc(13);
  header.writeUInt32BE(size,0);header.writeUInt32BE(size,4);header[8]=8;header[9]=6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(scan)),chunk('IEND',Buffer.alloc(0))]);
}
export async function writeExtensionIcons(out) {
  await mkdir(path.join(out,'icons'),{recursive:true});
  const icons={};
  for(const size of [16,32,48,128]) {
    icons[size]=`icons/icon${size}.png`;
    await writeFile(path.join(out,icons[size]),renderIcon(size));
  }
  return icons;
}
