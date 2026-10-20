#!/usr/bin/env node
// Rasterize the checked-in SVG artwork. Requires sharp; never downloads assets.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const assets = path.join(root, 'docs/assets');
async function main() {
  const source = fs.readFileSync(path.join(assets, 'logo.svg'));
  await sharp(source, {density: 288}).resize(1024,1024).png().toFile(path.join(assets,'app-icon.png'));
  await sharp(fs.readFileSync(path.join(assets,'quietbar.svg')), {density: 144}).resize(1200,360).png().toFile(path.join(assets,'quietbar.png'));
  await sharp(fs.readFileSync(path.join(assets,'social-preview.svg')), {density: 144}).resize(1280,640).png().toFile(path.join(assets,'social-preview.png'));
  const iconset = path.join(root,'build/QuietBar.iconset');
  fs.mkdirSync(iconset,{recursive:true});
  for (const size of [16,32,128,256,512]) for (const scale of [1,2]) {
    await sharp(source,{density:288}).resize(size*scale,size*scale).png().toFile(path.join(iconset,`icon_${size}x${size}${scale===2?'@2x':''}.png`));
  }
  process.stdout.write('Rendered brand PNGs and build/QuietBar.iconset. Convert with iconutil -c icns.\n');
}
main().catch(error=>{process.stderr.write(String(error)+'\n');process.exit(1);});
