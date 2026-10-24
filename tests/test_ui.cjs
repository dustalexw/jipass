// Deterministic browser-controller tests with simulated media and a delayed server.
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
function harness(){
 const nodes=new Map();
 function el(tag='div'){return {tagName:tag.toUpperCase(),textContent:'',hidden:false,disabled:false,children:[],dataset:{},style:{setProperty(){}},attrs:{},className:'',classList:{add(){},remove(){},toggle(){}},append(...x){this.children.push(...x)},replaceChildren(...x){this.children=x},setAttribute(k,v){this.attrs[k]=v},getAttribute(k){return this.attrs[k]},removeAttribute(k){delete this.attrs[k]},querySelector(sel){return this.children.find(c=>c.className===sel.slice(1))},showModal(){this.open=true},close(){this.open=false},focus(){},load(){},pause(){this.paused=true},play(){this.paused=false;return Promise.resolve()}};}
 const get=id=>{if(!nodes.has(id))nodes.set(id,el());return nodes.get(id)};
 get('length').value='5';get('game').hidden=false;
 const requests=[];let resolveReady;
 const context=vm.createContext({console,URL,URLSearchParams,window:{scrollTo(){}},document:{getElementById:get,createElement:el,createTextNode:t=>({textContent:t}),querySelector:()=>get('source-tag'),querySelectorAll:s=>s==='.answer'?get('answers').children:[],addEventListener(){}},localStorage:{getItem(){},setItem(){}},performance:{now:()=>1000},setInterval:()=>1,clearInterval(){},setTimeout:()=>1,clearTimeout(){},confirm:()=>true,fetch:async(url,options)=>{requests.push(url);if(url==='/api/ready')return new Promise(r=>resolveReady=()=>r({ok:true,json:async()=>({remaining:10})}));if(url==='/api/answer')return {ok:true,json:async()=>({feedback:{correct:true,timeout:false,points:900,elapsed:2,answer:'a',track:{title:'Local song',artist:'Local artist',album:'Local album'},artwork:'/artwork/revealed-only'},done:false})};throw Error('Unexpected request '+url)}});
 const script=fs.readFileSync(path.join(__dirname,'../static/app.js'),'utf8').replace(/refresh\(\)\.catch\(error\);\s*$/,'');vm.runInContext(script,context);
 vm.runInContext("round='r';loadQuestion({number:1,kind:'title',token:'token',duration:10,options:[{id:'a',label:'A song'},{id:'b',label:'B song'},{id:'c',label:'C song'},{id:'d',label:'D song'}]});",context);
 return {get,requests,run:s=>vm.runInContext(s,context),ready:()=>resolveReady()};
}
const turn=()=>new Promise(r=>setImmediate(r));
test('autoplay waits for playback and server readiness; canplay fires only one start',async()=>{
 const h=harness();h.run('audio.oncanplay();audio.oncanplay()');await turn();assert.equal(h.run('active'),false);assert.ok(h.get('answers').children.every(b=>b.disabled));assert.equal(h.requests.length,1);
 h.ready();await turn();assert.equal(h.run('active'),true);assert.ok(h.get('answers').children.every(b=>!b.disabled));
 h.run('audio.oncanplay()');await turn();assert.equal(h.requests.length,1);
 h.run("submit('a');submit('a')");await turn();assert.equal(h.requests.filter(x=>x==='/api/answer').length,1);assert.equal(h.get('feedback').children[0].className,'feedback-card feedback-win');assert.equal(h.run('streak'),1);
});
test('blocked autoplay keeps the timer and answers inactive and offers manual playback',async()=>{
 const h=harness();h.get('audio').play=()=>Promise.reject(Object.assign(Error('Blocked'),{name:'NotAllowedError'}));h.run('audio.oncanplay()');await turn();assert.equal(h.run('active'),false);assert.equal(h.requests.length,0);assert.ok(h.get('answers').children.every(b=>b.disabled));assert.match(h.get('play-hint').textContent,/Tap play/);assert.equal(h.get('play').disabled,false);
});
test('leaving while playback is starting never starts a question clock',async()=>{
 const h=harness();let release;h.get('audio').play=()=>new Promise(r=>release=r);h.run('audio.oncanplay();stop()');release();await turn();assert.equal(h.run('active'),false);assert.equal(h.requests.length,0);
});
test('artist picker filters by source, searches names, and locks questions to song titles',()=>{
 const h=harness();h.run("library={categories:[{source:'nas',genre:'Rock',count:12},{source:'demo',genre:'Demo',count:3}],artist_categories:[{source:'nas',artist:'Tame Impala',count:8},{source:'nas',artist:'Another Band',count:4},{source:'demo',artist:'Demo Artist',count:3}]};source='nas';browse('artist');");
 assert.equal(h.get('categories').children.length,3);
 h.get('category-search').value='tame';h.run('renderCategories()');assert.equal(h.get('categories').children.length,2);
 h.get('kind').value='artist';h.get('categories').children[1].onclick();assert.equal(h.run('artist'),'Tame Impala');assert.equal(h.get('kind').value,'title');assert.equal(h.get('kind').disabled,true);
 h.run("browse('genre')");assert.equal(h.run('artist'),'');assert.equal(h.get('kind').disabled,false);assert.equal(h.get('kind').value,'mixed');
});
test('album artwork is requested only after a result and resets for the next question',async()=>{
 const h=harness();assert.equal(h.get('album-art').hidden,true);assert.equal(h.get('album-image').src,undefined);
 h.run('audio.oncanplay()');await turn();h.ready();await turn();h.run("submit('a')");await turn();assert.equal(h.get('album-art').hidden,false);assert.equal(h.get('album-image').src,'/artwork/revealed-only');assert.equal(h.get('album-image').hidden,true);h.get('album-image').onload();assert.equal(h.get('album-image').hidden,false);
 h.run("loadQuestion({number:2,kind:'title',token:'next',duration:10,options:[]})");assert.equal(h.get('album-art').hidden,true);assert.equal(h.get('vinyl').hidden,false);
});
test('folder polling preserves the path being typed and disables changes while scanning',()=>{
 const h=harness();h.get('nas-path').value='/Volumes/New music';h.run("library={folders:[{path:'/Volumes/One',count:10,status:'Ready'},{path:'/Volumes/Two',count:5,status:'Ready'}],scan:{running:false},folders_locked:false};renderFolders()");assert.equal(h.get('folder-list').children.length,2);assert.equal(h.get('nas-path').value,'/Volumes/New music');assert.equal(h.get('add-folder').disabled,false);
 h.run('library.scan.running=true;renderFolders()');assert.equal(h.get('add-folder').disabled,true);assert.ok(h.get('folder-list').children.every(row=>row.children[1].children.every(button=>button.disabled)));
});
test('artist photos use local URLs and mixed-mode eligibility is explained',()=>{
 const h=harness();h.get('kind').value='mixed';h.run("library={categories:[{source:'nas',genre:'Rock',count:10}],artist_categories:[{source:'nas',artist:'The Strokes',count:10,photo_id:'cached-id'}]};source='nas';browse('artist');");
 const artistCard=h.get('categories').children[1],art=artistCard.children[0];assert.match(art.children[2].src,/^\/artist-photo\/cached-id\?v=/);assert.equal(art.children[2].loading,'lazy');
 h.run("browse('genre')");assert.match(h.get('kind-note').textContent,/needs 4 distinct artists/);
});
test('image editing is hidden until BIG CHIEF mode is enabled and settings show saved flags',()=>{
 const h=harness();h.run("library={categories:[{source:'nas',genre:'Rock',count:10}],artist_categories:[{source:'nas',artist:'The Strokes',count:10}],settings:{debug_mode:false,demo_mode:false}};source='nas';browse('artist');renderSettings()");assert.equal(h.get('debug-toggle').checked,false);assert.equal(h.get('categories').children[1].className.includes('category-tile'),false);
 h.run('library.settings.debug_mode=true;renderSettings();renderCategories()');assert.equal(h.get('debug-toggle').checked,true);const tile=h.get('categories').children[1];assert.equal(tile.className,'category-tile');assert.equal(tile.children[1].textContent,'Change image');
 h.run("browse('genre')");assert.equal(h.get('categories').children[1].children[1].textContent,'Change image');
 h.run('library.settings.debug_mode=false;renderCategories()');assert.equal(h.get('categories').children[1].className.includes('category-tile'),false);
});
