const $=id=>document.getElementById(id);
let library, source='nas', genre='', artist='', categoryMode='genre', preferredKind='mixed', round=null, q=null, active=false, submitted=false, deadline=0, ticker=null, total=0, lastResult=null, loading=false, starting=false, autoplayAttempted=false, playbackEpoch=0, streak=0, soundContext=null, imageTarget=null, previewObjectUrl=null;
const audio=$('audio'); audio.volume=.8;
async function api(path,data){const r=await fetch('/api/'+path,data===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});const j=await r.json();if(!r.ok)throw Error(j.error||'Request failed');return j;}
function error(e){$('error').textContent=e.message||e;$('error').hidden=false;clearTimeout(error.timeout);error.timeout=setTimeout(()=>$('error').hidden=true,9000);}
function show(id){for(const x of ['home','game','results','library','history'])$(x).hidden=x!==id;$('breadcrumb').textContent='THE COLLECTION / '+({home:'PLAY',game:'ON THE DECKS',results:'RESULTS',library:'LIBRARY',history:'HISTORY'}[id]);document.querySelectorAll('.nav').forEach(b=>b.classList.toggle('active',b.id==='nav-'+({home:'play',game:'play',results:'play',library:'library',history:'history'}[id])));window.scrollTo(0,0);}
function element(tag,text,cls){const e=document.createElement(tag);e.textContent=text;if(cls)e.className=cls;return e;}
async function refresh(){library=await api('library');const configuredSource=library.settings?.demo_mode?'demo':'nas';if(!round&&configuredSource!==source){source=configuredSource;artist='';genre='';}renderSettings();renderSourceBanner();const selected=$('profile').value||localStorage.getItem('needle-player');$('profile').replaceChildren(...library.profiles.map(p=>{const o=element('option',p.name);o.value=p.id;return o;}));if(library.profiles.some(p=>p.id===selected))$('profile').value=selected;renderFolders();$('scan-message').textContent=library.scan.message;$('scan-errors').replaceChildren(...library.scan.errors.map(s=>element('li',s)));$('scan').disabled=library.scan.running||!(library.folders?.length);renderCategories();renderHistory();}
function syncQuestionKind(){
    const selected=categoryMode==='artist'&&!!artist;
    const wasLocked=$('kind').disabled;
    $('kind').disabled=selected;if(selected)$('kind').value='title';else if(wasLocked)$('kind').value=preferredKind;
    $('category-note').textContent=selected?'Guess song titles by '+artist+'. Other answers prefer this artist’s songs.':categoryMode==='artist'?'Pick an artist for a song-title round. Artist photos are cached locally from Wikipedia.':'Choose a genre or mix the whole collection.';
    const artists=(library.artist_categories||[]).filter(c=>c.source===source).length;
    $('kind-note').textContent=$('kind').value==='mixed'?(artists<4?'Mixed mode needs 4 distinct artists for artist questions. This library has '+artists+'; rounds will use song titles until you add more artists.':'Mixed mode alternates between “Name that song” and “Who’s the artist?” when both have four distinct answers.'):(selected?'Artist selected: guess song titles from their collection.':'');
}
$('kind').onchange=()=>{preferredKind=$('kind').value;syncQuestionKind();};
async function updatePhotoCredits(){
    try{const data=await api('photo-credits');$('photo-credit-list').replaceChildren(...data.credits.map(c=>{const row=element('li',c.artist+' — '+c.author+' · '+c.license+' ');const link=element('a','Photo source');link.href=c.source_url;link.target='_blank';link.rel='noopener noreferrer';row.append(link);if(c.license_url){const license=element('a','License');license.href=c.license_url;license.target='_blank';license.rel='noopener noreferrer';row.append(document.createTextNode(' · '),license);}if(c.matched_artist!==c.artist)row.append(document.createTextNode(' (photo: '+c.matched_artist+')'));return row;}));$('photo-credits').hidden=categoryMode!=='artist'||!data.credits.length;}catch(e){$('photo-credits').hidden=true;}
}
function renderCategories(){
    const genres=library.categories.filter(c=>c.source===source), count=genres.reduce((n,c)=>n+c.count,0);
    const cats=categoryMode==='artist'?(library.artist_categories||[]).filter(c=>c.source===source).map(c=>({name:c.artist,count:c.count,photo:c.photo_id,image:c.image_url,custom:c.image_custom})):genres.map(c=>({name:c.genre,count:c.count,image:c.image_url,custom:c.image_custom}));
    const selected=categoryMode==='artist'?artist:genre;
    const query=$('category-search').value.trim().toLocaleLowerCase();
    const list=[{name:'',count},...cats.sort((a,b)=>a.name.localeCompare(b.name))].filter(c=>!c.name||!query||c.name.toLocaleLowerCase().includes(query));
    $('categories').replaceChildren();syncQuestionKind();$('photo-credits').hidden=true;if(categoryMode==='artist'&&source==='nas')updatePhotoCredits();
    if(!count){$('categories').append(element('div','Your collection is waiting. Connect a mounted music folder in Library settings, then scan it to get started.','empty'));$('start').disabled=true;return;}
    $('start').disabled=false;
    if(categoryMode==='artist'&&!library.artist_categories){$('categories').append(element('div','Artist categories are ready. Restart jipass once to load the updated server, then refresh this page.','empty'));return;}
    list.forEach((c,i)=>{
        const isArtist=categoryMode==='artist'&&!!c.name, chosen=selected===c.name;
        const b=element('button','','category'+(chosen?' selected':'')+(isArtist?' artist-category':''));b.setAttribute('aria-pressed',chosen);
        const art=element('div','','art '+(!c.name?'mixed':isArtist?'artist-art':['electronic','indie','jazz'][(i-1)%3]));art.setAttribute('aria-hidden','true');
        if(isArtist){const initials=c.name.split(/\s+/).slice(0,2).map(w=>w[0]).join('').toUpperCase();art.append(element('div',initials,'artist-monogram'),element('span',c.name.includes(',')?'LEAD ARTIST PHOTO':'ARTIST COLLECTION','artist-caption')); }
        else art.append(element('div','','shape'));
        if(c.image||c.photo){const img=element('img','','category-photo');img.alt='';img.loading='lazy';img.decoding='async';img.onload=()=>{art.classList.add('has-category-image');if(isArtist){art.classList.add('has-artist-photo');updatePhotoCredits();}};img.src=c.image||'/artist-photo/'+c.photo+'?v=custom-images-5';art.append(img);}
        const info=element('div','','category-info'),name=element('div',c.name||'Mixed library','category-name');name.append(element('span',chosen?'✓':'','check'));
        info.append(name,element('small',c.count+' '+(c.count===1?'track':'tracks')+' · '+(!c.name?'A little of everything':c.count<5?'Needs 5 tracks for a round':isArtist?'Guess their songs':'From your collection')));b.append(art,info);
        b.onclick=()=>{if(categoryMode==='artist'){artist=c.name;genre='';}else{genre=c.name;artist='';}if(c.count<10)$('length').value='5';renderCategories();};
        if(c.name&&library.settings?.debug_mode){
            const tile=element('div','','category-tile'),edit=element('button','Change image','category-image-edit');
            edit.setAttribute('aria-label','Change image for '+c.name);edit.onclick=()=>openImageEditor(categoryMode,source,c.name,c.image|| (c.photo?'/artist-photo/'+c.photo+'?v=custom-images-5':null),c.custom);
            tile.append(b,edit);$('categories').append(tile);
        }else $('categories').append(b);
    });
    if(list.length===1&&query)$('categories').append(element('div','No matching '+(categoryMode==='artist'?'artists':'genres')+'. Try a different search.','empty'));
}
function browse(mode){categoryMode=mode;genre='';artist='';$('category-search').value='';$('category-search').placeholder=mode==='artist'?'Find an artist…':'Find a genre…';for(const type of ['genre','artist']){const b=$(type==='genre'?'browse-genres':'browse-artists');b.classList.toggle('selected',mode===type);b.setAttribute('aria-pressed',mode===type);}renderCategories();}
$('browse-genres').onclick=()=>browse('genre');$('browse-artists').onclick=()=>browse('artist');$('category-search').oninput=renderCategories;
function renderSourceBanner(){document.querySelector('.demo-banner .tag').textContent=source==='demo'?'DEMO MODE':'LOCAL LIBRARY';$('source-message').textContent=source==='demo'?'Demo mode is on. Playing original synthesized sketches. Change this in Settings.':'Songs and answers come exclusively from your indexed music folders.';}
function setSource(s){source=s;genre='';artist='';renderSourceBanner();renderCategories();}
function renderSettings(){
    $('debug-toggle').checked=!!library?.settings?.debug_mode;$('demo-toggle').checked=!!library?.settings?.demo_mode;
    $('debug-toggle').disabled=$('demo-toggle').disabled=!library?.settings;
}
$('open-settings').onclick=()=>{renderSettings();$('settings-status').textContent=!library?.settings?'Restart jipass once to enable the new settings.':round?'The question clock keeps running while Settings is open.':'Changes are saved locally.';$('settings-dialog').showModal();};
$('close-settings').onclick=()=>$('settings-dialog').close();
$('settings-library').onclick=()=>{$('settings-dialog').close();navigate('library');};
async function saveSetting(key,value){
    const input=$(key==='debug_mode'?'debug-toggle':'demo-toggle');
    if(key==='demo_mode'&&round){renderSettings();$('settings-status').textContent='Finish or leave the round before switching music sources.';return;}
    input.disabled=true;
    try{const saved=await api('settings',{[key]:value});library.settings=saved.settings;if(key==='demo_mode')setSource(value?'demo':'nas');renderSettings();renderCategories();$('settings-status').textContent='Saved locally.';}
    catch(e){renderSettings();$('settings-status').textContent=e.message;}
}
$('debug-toggle').onchange=()=>saveSetting('debug_mode',$('debug-toggle').checked);
$('demo-toggle').onchange=()=>saveSetting('demo_mode',$('demo-toggle').checked);
function clearImagePreview(){if(previewObjectUrl){URL.revokeObjectURL(previewObjectUrl);previewObjectUrl=null;}}
function openImageEditor(kind,musicSource,name,current,custom){
    if(!library.settings?.debug_mode)return;
    clearImagePreview();imageTarget={kind,source:musicSource,name};$('image-target').textContent=(kind==='artist'?'Artist: ':'Genre: ')+name;
    $('image-file').value='';$('image-preview').hidden=!current;if(current)$('image-preview').src=current;
    $('image-save').disabled=true;$('image-reset').hidden=!custom;$('image-upload-status').textContent='';$('image-dialog').showModal();
}
$('close-image').onclick=()=>$('image-dialog').close();$('image-dialog').onclose=clearImagePreview;
$('image-file').onchange=()=>{
    clearImagePreview();const file=$('image-file').files[0];$('image-save').disabled=true;if(!file)return;
    if(!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>8*1024*1024){$('image-upload-status').textContent='Choose a JPEG, PNG, or WebP image smaller than 8 MB.';return;}
    previewObjectUrl=URL.createObjectURL(file);$('image-preview').src=previewObjectUrl;$('image-preview').hidden=false;$('image-save').disabled=false;$('image-upload-status').textContent='Ready to save.';
};
$('image-save').onclick=async()=>{
    const file=$('image-file').files[0];if(!file||!imageTarget)return;
    $('image-save').disabled=true;$('image-upload-status').textContent='Saving your image…';
    try{const params=new URLSearchParams(imageTarget);const response=await fetch('/api/category-image?'+params,{method:'POST',headers:{'Content-Type':file.type},body:file});const result=await response.json();if(!response.ok)throw Error(result.error||'Could not save image');await refresh();$('image-dialog').close();}
    catch(e){$('image-upload-status').textContent=e.message;$('image-save').disabled=false;}
};
$('image-reset').onclick=async()=>{if(!imageTarget)return;try{await api('category-image/remove',imageTarget);await refresh();$('image-dialog').close();}catch(e){$('image-upload-status').textContent=e.message;}};
function navigate(id){if(round&&!$('game').hidden&&!confirm('Leave this round? Completed answers are saved, but this round cannot be resumed.'))return;stop();round=null;show(id);if(id==='history')renderHistory();}
$('nav-play').onclick=()=>navigate('home');$('nav-library').onclick=$('connect').onclick=()=>navigate('library');$('nav-history').onclick=()=>navigate('history');$('back-library').onclick=$('back-history').onclick=()=>navigate('home');
$('add-profile').onclick=()=>{$('profile-dialog').showModal();$('player-name').focus();};$('cancel-profile').onclick=()=>$('profile-dialog').close();$('profile-form').onsubmit=async e=>{e.preventDefault();try{const p=await api('profile',{name:$('player-name').value});localStorage.setItem('needle-player',p.id);await refresh();$('profile').value=p.id;$('profile-dialog').close();$('player-name').value='';}catch(e){error(e);}};$('profile').onchange=()=>{localStorage.setItem('needle-player',$('profile').value);renderHistory();};
function renderFolders(){
    const folders=library.folders||[];
    $('folder-list').replaceChildren();
    if(!library.folders){$('folder-list').append(element('div','Restart jipass once to enable multiple folders and album artwork.','empty'));}
    else if(!folders.length){$('folder-list').append(element('div','No music folders yet. Add your first folder above.','empty'));}
    folders.forEach(folder=>{
        const row=element('div','','folder-row');const info=element('div','','folder-info');info.append(element('b',folder.path),element('small',folder.count+' indexed '+(folder.count===1?'track':'tracks')+' · '+folder.status));
        const actions=element('div','','folder-actions'),scan=element('button','Rescan ↻','text-btn'),remove=element('button','Remove','text-btn');
        scan.setAttribute('aria-label','Rescan '+folder.path);remove.setAttribute('aria-label','Remove '+folder.path);
        scan.disabled=library.scan.running;remove.disabled=library.scan.running||library.folders_locked;
        scan.onclick=()=>scanFolder(folder.path);
        remove.onclick=async()=>{if(!confirm('Remove this folder and its exclusive tracks from the index? Your music files and scores will stay untouched.'))return;try{await api('folders/remove',{path:folder.path});await refresh();}catch(e){error(e);}};
        actions.append(scan,remove);row.append(info,actions);$('folder-list').append(row);
    });
    $('add-folder').disabled=library.scan.running||library.folders_locked||!library.folders;
    $('nas-path').disabled=!!library.folders_locked;
    $('folder-summary').textContent=library.folders_locked?'Folders are managed through environment settings.':folders.length+' configured '+(folders.length===1?'folder':'folders');
}
async function scanFolder(path){try{await api('scan',path?{path}:{});await refresh();}catch(e){error(e);}}
$('scan').onclick=()=>scanFolder();
$('add-folder').onclick=async()=>{try{await api('folders/add',{path:$('nas-path').value});$('nas-path').value='';await refresh();}catch(e){error(e);}};
$('nas-path').onkeydown=e=>{if(e.key==='Enter')$('add-folder').click();};
setInterval(async()=>{if(library?.scan.running){try{await refresh();}catch(e){error(e);}}},1500);
$('start').onclick=async()=>{if(!$('profile').value){$('profile-dialog').showModal();return;}if(loading)return;unlockFeedbackSound();loading=true;$('start').disabled=true;$('start').textContent='Preparing your clip…';try{const r=await api('round',{profile:$('profile').value,source,genre,artist,kind:$('kind').value,length:Number($('length').value),seconds:Number($('seconds').value)});round=r.id;total=0;streak=0;$('round-notice').textContent=r.notice||'';$('round-notice').hidden=!r.notice;$('live-score').textContent='0 PTS';show('game');loadQuestion(r.question);}catch(e){error(e);}finally{loading=false;$('start').disabled=false;$('start').textContent='Let’s play ↗';}};
function stop(){playbackEpoch++;starting=false;clearInterval(ticker);active=false;audio.pause();$('vinyl').classList.remove('playing');}
function loadQuestion(question){stop();$('album-art').hidden=true;$('album-image').hidden=true;$('album-image').removeAttribute('src');$('vinyl').hidden=false;q=question;autoplayAttempted=false;submitted=false;lastResult=null;deadline=0;$('next').hidden=true;$('feedback').replaceChildren();$('feedback').className='';$('answers').classList.remove('answered');$('live-score').classList.remove('score-pop');$('round-progress').textContent=String(q.number).padStart(2,'0')+' / '+$('length').value;$('progress-fill').style.width=((q.number-1)/Number($('length').value)*100)+'%';$('question-number').textContent='TRACK '+String(q.number).padStart(2,'0')+' / '+(q.kind==='title'?'SONG TITLE':'ARTIST');$('question-title').textContent=q.kind==='title'?'Name that song.':'Who’s the artist?';$('game-source').textContent=artist?(source==='demo'?'DEMO · ':'ARTIST · ')+artist:source==='demo'?'DEMO · ORIGINAL SKETCHES':'YOUR LOCAL COLLECTION';$('timer').textContent=q.duration.toFixed(1)+'s';$('timer-fill').style.width='100%';$('play-status').textContent='Your next discovery';$('play-hint').textContent='Starting automatically when ready…';$('play').textContent='▶';$('play').disabled=true;$('play').setAttribute('aria-label','Play clip');$('answers').replaceChildren(...q.options.map((o,i)=>{const b=element('button','','answer');const badge=element('span','ABCD'[i],'answer-badge');badge.setAttribute('aria-hidden','true');b.append(badge,element('span',o.label,'answer-label'),element('span','›','answer-trailing'));b.setAttribute('aria-label','Answer '+(i+1)+': '+o.label);b.dataset.option=o.id;b.disabled=true;b.onclick=()=>submit(o.id);return b;}));audio.src='/audio/'+q.token;audio.load();}
audio.oncanplay=()=>{
    if(submitted || $('game').hidden)return;
    $('play').disabled=false;
    if(!autoplayAttempted && !active){autoplayAttempted=true;startPlayback();}
};
audio.onerror=()=>{stop();$('play-status').textContent='Audio unavailable';error('The clip could not load. Leave this round and rescan your library.');};
$('volume').oninput=()=>{audio.volume=Number($('volume').value);};
function unlockFeedbackSound(){
    try{const AudioContext=window.AudioContext||window.webkitAudioContext;if(AudioContext){soundContext ||= new AudioContext();soundContext.resume().catch(()=>{});}}catch(e){}
}
function feedbackSound(correct){
    if(!soundContext || soundContext.state!=='running' || !audio.volume)return;
    try{const now=soundContext.currentTime;const notes=correct?[523.25,659.25,783.99]:[293.66,220];
        notes.forEach((frequency,i)=>{const osc=soundContext.createOscillator(),gain=soundContext.createGain();const at=now+i*.085;osc.type='sine';osc.frequency.value=frequency;gain.gain.setValueAtTime(0,at);gain.gain.linearRampToValueAtTime(.12*audio.volume,at+.012);gain.gain.exponentialRampToValueAtTime(.001,at+.18);osc.connect(gain);gain.connect(soundContext.destination);osc.start(at);osc.stop(at+.2);});
    }catch(e){}
}
async function startPlayback(){
    if(submitted || starting || active || !q || $('game').hidden)return;
    starting=true;const epoch=playbackEpoch,token=q.token,id=round;$('play').disabled=true;
    try{
        await audio.play();
        if(epoch!==playbackEpoch)return;
        const start=performance.now();const ready=await api('ready',{id,token});
        if(epoch!==playbackEpoch)return;
        deadline=start+ready.remaining*1000;active=true;
        $('play-status').textContent='Listen closely';$('play-hint').textContent='Pick an answer · the clock keeps running if paused';
        $('play').textContent='Ⅱ';$('play').setAttribute('aria-label','Pause clip');$('vinyl').classList.add('playing');
        document.querySelectorAll('.answer').forEach(b=>b.disabled=false);ticker=setInterval(tick,40);tick();
    }catch(e){
        if(epoch!==playbackEpoch)return;
        audio.pause();$('play-status').textContent='Ready when you are';$('play-hint').textContent='Tap play to enable audio and start the clock';
        if(e.name!=='NotAllowedError')error(e);
    }finally{if(epoch===playbackEpoch){starting=false;$('play').disabled=submitted;}}
}
$('play').onclick=async()=>{
    unlockFeedbackSound();if(submitted||starting)return;
    if(!active){await startPlayback();return;}
    if(audio.paused){try{await audio.play();$('play').textContent='Ⅱ';$('play').setAttribute('aria-label','Pause clip');$('vinyl').classList.add('playing');}catch(e){error(e);}}
    else{audio.pause();$('play').textContent='▶';$('play').setAttribute('aria-label','Resume clip');$('vinyl').classList.remove('playing');}
};
document.addEventListener('keydown',e=>{
    if(e.repeat||e.ctrlKey||e.metaKey||e.altKey||!active||submitted||$('game').hidden||['INPUT','SELECT','TEXTAREA'].includes(e.target.tagName))return;
    const i='1234'.indexOf(e.key);if(i>=0){e.preventDefault();submit(q.options[i].id);}
});
function artworkThumb(url){
    const frame=element('div','','track-artwork');const fallback=element('span','♫');fallback.setAttribute('aria-hidden','true');frame.append(fallback);
    if(url){const image=element('img','');image.alt='Album cover';image.hidden=true;image.onload=()=>{image.hidden=false;fallback.hidden=true;};image.onerror=()=>{image.hidden=true;fallback.hidden=false;};image.src=url;frame.append(image);}
    return frame;
}
function revealArtwork(f){
    $('vinyl').hidden=true;$('album-art').hidden=false;$('album-image').hidden=true;
    $('album-art-status').textContent=f.artwork?'Finding local artwork…':'No local artwork';
    if(!f.artwork)return;
    const image=$('album-image'),url=f.artwork;
    image.alt='Album cover for '+f.track.album+' by '+f.track.artist;
    image.onload=()=>{if(lastResult?.feedback?.artwork===url&&submitted)image.hidden=false;};
    image.onerror=()=>{if(lastResult?.feedback?.artwork===url&&submitted){image.hidden=true;$('album-art-status').textContent='No local artwork';}};
    image.src=url;
}
function renderFeedback(f,option){
    streak=f.correct?streak+1:0;
    $('answers').classList.add('answered');
    document.querySelectorAll('.answer').forEach(b=>{
        const right=b.dataset.option===f.answer, chosen=b.dataset.option===option;
        b.classList.remove('pending');
        if(right){b.classList.add('correct');b.querySelector('.answer-badge').textContent='✓';b.querySelector('.answer-trailing').textContent=chosen?'YOU GOT IT':'CORRECT ANSWER';}
        else if(chosen){b.classList.add('incorrect');b.querySelector('.answer-badge').textContent='×';b.querySelector('.answer-trailing').textContent='YOUR PICK';}
        else b.classList.add('unselected');
        b.setAttribute('aria-label',b.getAttribute('aria-label')+(right?' — correct answer':chosen?' — your incorrect answer':''));
    });
    const fast=f.correct&&f.elapsed/q.duration<.25;
    const title=f.timeout?'Time’s up!':f.correct?(fast?'Lightning ears!':'You nailed it!'):'So close. Next one’s yours.';
    const card=element('div','','feedback-card '+(f.correct?'feedback-win':'feedback-miss'));
    const top=element('div','','feedback-top');const headline=element('div');headline.append(element('p',f.correct?'CORRECT ANSWER':f.timeout?'TIMEOUT':'INCORRECT ANSWER','feedback-kicker'),element('strong',title,'feedback-title'));
    top.append(element('span',f.correct?'✓':f.timeout?'◷':'×','feedback-icon'),headline);
    const reward=element('div','','feedback-reward');reward.append(element('b','+'+f.points.toLocaleString()),element('span','POINTS'));top.append(reward);
    const meta=element('div','','feedback-meta');meta.append(element('span',f.elapsed.toFixed(2)+'s response'));
    if(f.correct){meta.append(element('span','500 correct + '+(f.points-500)+' speed bonus'));if(streak>1)meta.append(element('span',streak+' in a row!','streak-badge'));}
    else meta.append(element('span',f.timeout?'No answer before the deadline':'Keep listening. You’ve got this.'));
    const reveal=element('div','','track-reveal');reveal.append(artworkThumb(f.artwork));const track=element('div');track.append(element('small','THE TRACK WAS'),element('b',f.track.title),element('span',f.track.artist+' · '+f.track.album));reveal.append(track);
    card.append(top,meta,reveal);
    if(f.correct){const burst=element('div','','win-burst');burst.setAttribute('aria-hidden','true');for(let i=0;i<9;i++){const spark=element('i','');spark.style.setProperty('--i',i);burst.append(spark);}card.append(burst);}
    $('feedback').replaceChildren(card);$('feedback').className=f.correct?'feedback-celebrate':'feedback-reveal';
    $('live-score').classList.remove('score-pop');void $('live-score').offsetWidth;if(f.points)$('live-score').classList.add('score-pop');
    revealArtwork(f);feedbackSound(f.correct);
}
function tick(){if(submitted||!active)return;const remaining=Math.max(0,(deadline-performance.now())/1000);$('timer').textContent=remaining.toFixed(1)+'s';$('timer-fill').style.width=(remaining/q.duration*100)+'%';if(remaining<=0)submit(null);}
async function submit(option){if(submitted||!active)return;submitted=true;clearInterval(ticker);audio.pause();$('vinyl').classList.remove('playing');$('play').disabled=true;document.querySelectorAll('.answer').forEach(b=>{b.disabled=true;if(b.dataset.option===option)b.classList.add('pending');});try{const r=await api('answer',{id:round,token:q.token,option});if(r.remaining!==undefined){submitted=false;deadline=performance.now()+r.remaining*1000;ticker=setInterval(tick,40);return;}lastResult=r;total+=r.feedback.points;$('live-score').textContent=total.toLocaleString()+' PTS';const f=r.feedback;renderFeedback(f,option);$('play-status').textContent='Track revealed';$('play-hint').textContent=f.track.title;$('next').hidden=false;$('next').textContent=r.done?'See your results ↗':'Next track ↗';$('next').focus();}catch(e){error(e);submitted=false;$('feedback').replaceChildren(element('p','Could not save your answer. Retry to recover the server result.'));const b=element('button','Retry answer','primary');b.onclick=()=>submit(option);$('feedback').append(b);}}
$('next').onclick=async()=>{if(loading)return;if(lastResult?.done){renderResults(lastResult.summary);return;}loading=true;$('next').disabled=true;$('next').textContent='Preparing next track…';try{const r=await api('next',{id:round});if(r.summary)renderResults(r.summary);else loadQuestion(r.question);}catch(e){error(e);}finally{loading=false;$('next').disabled=false;}};
function renderResults(s){stop();show('results');$('total').textContent=s.score.toLocaleString();$('accuracy').textContent=s.accuracy+'%';$('average').textContent=s.average+'s';$('best').textContent=s.best.toLocaleString();$('result-note').textContent=s.count+' tracks played'+(s.skipped?' · '+s.skipped+' unplayable tracks skipped':'')+' · '+(source==='demo'?'Demo session':'Local library session');$('result-tracks').replaceChildren(...s.results.map((f,i)=>{const row=element('div','','result-track');const name=element('span',f.track.title,'result-track-name');name.append(element('small',f.track.artist+' · '+f.track.genre+(f.kind?' · '+(f.kind==='artist'?'Artist question':'Song-title question'):'')));row.append(element('span',String(i+1).padStart(2,'0')),artworkThumb(f.artwork),name,element('span',f.timeout?'Timeout':f.correct?'Correct':'Incorrect'),element('b','+'+f.points));return row;}));round=null;refresh().catch(error);}
$('leave').onclick=()=>navigate('home');$('again').onclick=()=>show('home');
function renderHistory(){if(!library)return;const rows=library.history.filter(r=>r.profile===$('profile').value);$('history-list').replaceChildren(...rows.map(r=>{const row=element('div','','history-item');row.append(element('span',r.source==='demo'?'Demo library':'My library'),element('span',r.count+' tracks'),element('span',r.accuracy+'%'),element('b',r.score.toLocaleString()+' pts'));return row;}));if(!rows.length)$('history-list').append(element('div','Your first record is waiting. Finish a round to see it here.','empty'));}
refresh().catch(error);
