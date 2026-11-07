import {defineConfig} from 'vite';
import {VitePWA} from 'vite-plugin-pwa';

const base=process.env.GITHUB_ACTIONS?'/Sklad/':'/';
export default defineConfig({
  base,
  plugins:[VitePWA({
    registerType:'autoUpdate',
    injectRegister:'auto',
    includeAssets:['icon.svg'],
    manifest:{
      id:base,
      name:'Склад · Windows',
      short_name:'Склад',
      description:'Офлайн-склад для накладных и инвентаризации',
      theme_color:'#12293b',
      background_color:'#f4f6f8',
      display:'standalone',
      scope:base,
      start_url:base,
      lang:'ru',
      icons:[{src:'icon.svg',sizes:'any',type:'image/svg+xml',purpose:'any maskable'}]
    },
    workbox:{
      globPatterns:['**/*.{html,js,css,svg,png,wasm,gz}'],
      maximumFileSizeToCacheInBytes:30*1024*1024,
      navigateFallback:'index.html',
      cleanupOutdatedCaches:true,
      skipWaiting:true,
      clientsClaim:true
    }
  })]
});
