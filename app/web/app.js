const $=id=>document.getElementById(id);
let status={},items=[],trash=[],currentPlaythrough='',lastOp='',toastTimer,deferredInstall;
const names={L_ToyKingdom:'Toy Kingdom',L_Shopping_mall:'Shopping Mall',L_SkyKids_Store:'SkyKids Store'};
const modes=['Классический','На время','Свободная игра'];
function askName(title,value=''){const d=$('name-dialog');$('name-title').textContent=title;$('name-value').value=value;d.returnValue='';return new Promise(resolve=>{d.onclose=()=>resolve(d.returnValue==='save'?$('name-value').value:null);d.showModal();$('name-value').focus();$('name-value').select()})}
function toast(text){$('toast').textContent=text;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,7000)}
async function post(path,data={}){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});const result=await r.json();if(!r.ok)throw Error(result.error);return result}
async function action(path,data){try{return await post(path,data)}catch(e){toast(e.message);throw e}}
function game(actionName,params={}){return action('/api/game',{action:actionName,...params})}
function button(label,fn,cls=''){const b=document.createElement('button');b.textContent=label;b.className=cls;b.onclick=async()=>{b.disabled=true;try{await fn()}catch{}finally{b.disabled=false}};return b}
function renderGallery(){const g=$('gallery');g.replaceChildren();const selected=$('playthrough').value;const filtered=items.filter(x=>!selected||x.playthrough===selected);$('empty').hidden=filtered.length>0;for(const m of filtered){const card=document.createElement('article');card.className='snapshot';let image;if(m.image){image=document.createElement('img');image.src=`/snapshots/${m.id}/image.png`;image.alt=m.name;image.loading='lazy';image.onclick=()=>{$('large-image').src=image.src;$('image-dialog').showModal()}}else{image=document.createElement('div');image.className='placeholder';image.textContent='Последнее сохранение на диске'}image.classList.add('snapshot-image');card.append(image);const body=document.createElement('div');body.className='snapshot-body';const name=document.createElement('h3');name.textContent=m.name;const date=document.createElement('div');date.className='date';date.textContent=new Date(m.created*1000).toLocaleString('ru-RU',{dateStyle:'medium',timeStyle:'short'});const map=document.createElement('div');map.className='map';map.textContent=`${names[m.world]||m.world} · ${modes[m.mode]} · ${m.playthrough}`;const controls=document.createElement('div');controls.className='snapshot-buttons';const load=button('Загрузить',()=>action('/api/load',{id:m.id}),'primary');load.disabled=status.operation?.status==='running';controls.append(load);const menu=document.createElement('details');const summary=document.createElement('summary');summary.textContent='•••';menu.append(summary);const options=document.createElement('div');options.className='snapshot-menu';options.append(button('Переименовать',async()=>{const name=await askName('Название снапшота',m.name);if(name!==null){await action('/api/rename',{id:m.id,name});await refreshSnapshots()}}),button('Экспорт',async()=>{const x=await action('/api/export',{id:m.id});const a=document.createElement('a');a.href=x.url;a.download=`${m.name}.toybox.zip`;a.click()}),button('В корзину',async()=>{await action('/api/delete',{id:m.id});await refreshSnapshots()}));menu.append(options);controls.append(menu);body.append(name,date,map,controls);card.append(body);g.append(card)}$('trash-count').textContent=trash.length}
async function refreshSnapshots(){const r=await fetch('/api/snapshots');const data=await r.json();items=data.items;trash=data.trash;const old=$('playthrough').value;const all=[...new Set(['Основное прохождение',currentPlaythrough,...items.map(x=>x.playthrough)].filter(Boolean))];$('playthrough').replaceChildren(new Option('Все прохождения',''),...all.map(x=>new Option(x,x)));$('playthrough').value=all.includes(old)?old:'';renderGallery();renderTrash()}
function renderTrash(){const host=$('trash-list');host.replaceChildren();if(!trash.length)host.textContent='Корзина пуста.';for(const m of trash){const row=document.createElement('div');row.className='trash-row';const text=document.createElement('span');text.textContent=m.name;row.append(text,button('Восстановить',async()=>{await action('/api/undelete',{id:m.id});await refreshSnapshots()}));host.append(row)}}
function applyState(){const s=status.game||{};const connected=status.modConnected;const busy=status.operation?.status==='running';$('connection').textContent=connected?(s.cameraReady?'Игра и мод подключены':'Мод подключён · меню'):(status.gameRunning?'Игра запущена · мод не подключён':'Игра закрыта');$('status-dot').className=connected?'online':'';$('launch').disabled=busy||status.gameRunning;$('close').disabled=busy||!status.gameRunning;$('capture').disabled=busy||!connected||!s.ready||!s.authority;$('disk-save').disabled=busy||status.gameRunning;$('role').textContent=s.cameraReady?(s.authority?'Хост / одиночная игра':'Клиент'):(connected?'Откройте уровень':'Игра не подключена');for(const id of ['freecam','tool','noCooldown']){if(document.activeElement!==$(id))$(id).checked=!!s[id];$(id).disabled=!connected||busy||(id==='freecam'&&!s.cameraReady)||(id!=='freecam'&&s.cameraReady&&!s.authority)}for(const [id,factor,unit]of [['speed',.01,' м/с'],['fov',1,'°'],['focalLength',1,' мм'],['lensBlur',1,''],['sensitivity',1,''],['smoothing',1,' с'],['rotationSmoothing',1,' с'],['batch',1,' шт.']]){const value=(s[id]??({speed:600,fov:90,sensitivity:.12,smoothing:.12,rotationSmoothing:.08,focalLength:18,focusDistance:5,lensBlur:0,batch:20}[id]))*factor;if(document.activeElement!==$(id))$(id).value=value;$(id+'-out').textContent=Number(value.toFixed(2))+unit}if(document.activeElement!==$('hands'))$('hands').value=s.hands>0?s.hands:200;$('held-count').textContent=`В руках: ${s.held??'—'} · вместимость: ${s.maxHands??'—'}`;$('save-limit').textContent=connected&&s.ready?'Сохраняется текущее состояние уровня и координаты персонажа. Загрузка выполняется автоматически через меню.':'Откройте игровой уровень для снимка текущего состояния и скриншота.';const warnings=[];if(status.test)warnings.push('Тестовый профиль: пользовательские сохранения не меняются.');if(status.gameRunning&&!connected)warnings.push('Игра запущена без мода. Для подключения нужен её перезапуск.');if(s.cameraReady&&!s.authority)warnings.push('Сохранения, массовый подбор и изменения мира доступны у хоста.');if(status.inputError)warnings.push(status.inputError);if(s.error)warnings.push(s.error);if(s.replayError)warnings.push(s.replayError);if(s.version&&s.version!==status.version)warnings.push("Обновление v4 готово. Для новых функций перезапустите игру.");$('notice').textContent=warnings.join(' ');$('notice').hidden=!warnings.length;const op=status.operation;$('operation').hidden=!op||op.status==='done';$('operation').className='operation '+(op?.status||'');if(op)$('operation-text').textContent=op.message;if(op&&op.status!=='running'&&op.id!==lastOp){lastOp=op.id;refreshSnapshots();refreshReplays()}document.querySelectorAll('[data-command],#hands-apply,#hands-reset').forEach(b=>b.disabled=busy||!connected);$('throw-count').hidden=!s.throwRemaining;$('throw-count').textContent=`Осталось бросить: ${s.throwRemaining||0}`;applyShelfState();applyReplayState()}
async function poll(){try{const r=await fetch('/api/status');status=await r.json();applyState()}catch(e){console.error(e);$('connection').textContent='Локальный сервис недоступен';$('status-dot').className='';$('notice').textContent='Откройте ярлык Toybox Together, чтобы запустить сервис.';$('notice').hidden=false}setTimeout(poll,650)}
// Native links preserve middle-click, Ctrl-click, bookmarks and browser history.
const requestedPage=new URLSearchParams(location.search).get('page');const activePage=['cheats','replays'].includes(requestedPage)?requestedPage:'saves';
document.querySelectorAll('.page').forEach(p=>p.hidden=p.id!==activePage);
$('cheat-sections').hidden=activePage!=='cheats';
document.querySelectorAll('[data-page]').forEach(a=>{const active=a.dataset.page===activePage;a.classList.toggle('active',active);if(active)a.setAttribute('aria-current','page')});
document.title=({cheats:'Камера и читы',replays:'Записи и повторы',saves:'Сохранения'}[activePage])+' · Toybox Together';
function highlightSection(){document.querySelectorAll('[data-section]').forEach(a=>{const active=location.hash==='#'+a.dataset.section;a.classList.toggle('active',active);if(active)a.setAttribute('aria-current','location');else a.removeAttribute('aria-current')})}
window.addEventListener('hashchange',highlightSection);highlightSection();
for(const id of ['freecam','tool','noCooldown'])$(id).onchange=async()=>{try{if(id==='freecam')await game('camera',{enabled:$(id).checked});else await game('settings',{[id]:$(id).checked})}catch{};applyState()};for(const id of ['speed','fov','sensitivity','smoothing','rotationSmoothing','focalLength','lensBlur','batch']){const factor=id==='speed'?100:1;$(id).oninput=()=>$(id+'-out').textContent=$(id).value+(id==='speed'?' м/с':id==='fov'?'°':id==='batch'?' шт.':['smoothing','rotationSmoothing'].includes(id)?' с':id==='focalLength'?' мм':id==='focusDistance'?' м':'');$(id).onchange=async()=>{try{await game('settings',{[id]:Number($(id).value)*factor})}catch{}}}
$('hands-apply').onclick=()=>game('settings',{hands:Number($('hands').value)}).catch(()=>{});$('hands-reset').onclick=()=>game('settings',{hands:-1}).catch(()=>{});
document.querySelectorAll('[data-command]').forEach(b=>b.onclick=async()=>{const data={name:b.dataset.command};if(b.dataset.input)data.value=b.dataset.command==='flyShelves'&&$('shelf-all').checked?-1:Number($(b.dataset.input).value);if(b.dataset.value!==undefined)data.value=Number(b.dataset.value);try{await game('cheat',data);toast('Команда передана игре')}catch{}});
function applyShelfState(){const s=status.game||{},busy=status.operation?.status==='running'||s.shelfBusy;document.querySelectorAll('[data-shelf]').forEach(b=>b.disabled=busy||!status.modConnected||!s.ready||!s.authority);if(s.shelfBusy)document.querySelectorAll('[data-command],#hands-apply,#hands-reset,#capture').forEach(b=>b.disabled=true);$('shelf-count').disabled=$('shelf-all').checked||busy;$('shelf-all').disabled=busy;const op=s.shelfOperation;$('shelf-result').hidden=!op;if(op)$('shelf-result').textContent=op.state==='running'?`${op.message} ${op.completed} / ${op.total}`:op.message;}
$('shelf-all').onchange=applyShelfState;
document.querySelectorAll('[data-shelf]').forEach(b=>b.onclick=async()=>{const count=b.dataset.shelf==='aimed'||$('shelf-all').checked?-1:Number($('shelf-count').value);if(!Number.isInteger(count)||count!==-1&&(count<1||count>1000000)){toast('Введите целое количество от 1 до 1 000 000.');return;}try{await action('/api/shelves',{kind:b.dataset.shelf,count});}catch{}});
$('launch').onclick=()=>action('/api/start').catch(()=>{});$('close').onclick=()=>action('/api/close').catch(()=>{});$('capture').onclick=()=>action('/api/snapshot',{playthrough:$('playthrough').value||currentPlaythrough||'Основное прохождение'}).catch(()=>{});$('disk-save').onclick=()=>action('/api/disk-snapshot',{world:$('disk-world').value,mode:Number($('disk-mode').value),playthrough:$('playthrough').value||currentPlaythrough||'Основное прохождение'}).catch(()=>{});$('playthrough').onchange=renderGallery;$('new-playthrough').onclick=async()=>{const name=await askName('Название прохождения');if(name?.trim()){currentPlaythrough=name.trim().slice(0,120);$('playthrough').append(new Option(currentPlaythrough,currentPlaythrough));$('playthrough').value=currentPlaythrough;renderGallery()}};
$('trash').onclick=()=>{$('trash-dialog').showModal();renderTrash()};document.querySelectorAll('.dialog-close').forEach(b=>b.onclick=()=>b.closest('dialog').close());$('import').onchange=async()=>{const file=$('import').files[0];if(!file)return;try{const r=await fetch('/api/import',{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:file});const data=await r.json();if(!r.ok)throw Error(data.error);await refreshSnapshots();toast('Снапшот импортирован')}catch(e){toast(e.message)}finally{$('import').value=''}};
window.addEventListener('beforeinstallprompt',e=>{e.preventDefault();deferredInstall=e;$('install-pwa').hidden=false});$('install-pwa').onclick=async()=>{if(deferredInstall){await deferredInstall.prompt();deferredInstall=null;$('install-pwa').hidden=true}};if('serviceWorker'in navigator)navigator.serviceWorker.register('/sw.js');refreshSnapshots();poll();




let replayTimer;let replayItems=[],replayStamp='',selectedReplay='';
function duration(seconds){seconds=Math.floor(seconds||0);return `${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`}
function applyReplayState(){
 const r=status.game?.replay||{},busy=status.operation?.status==='running',supported=['4.0.1','4.1.0'].includes(status.game?.version);
 const active=r.state&&!['idle','finished'].includes(r.state),recording=['recording','overdubbing'].includes(r.state)||['recording','overdubbing'].includes(r.pausedState);
 if(document.activeElement!==$('record-kind')&&r.kind)$('record-kind').value=r.kind;
 const labels={idle:'Готов к записи',loaded:'✓ Загружено · старт в паузе',recording:'● Идёт запись',playing:'▶ Идёт повтор',paused:'Ⅱ Пауза',overdubbing:'● Перезапись игрока',finished:'✓ Повтор завершён'};
 $('record-state').textContent=labels[r.state]||labels.idle;$('record-time').textContent=duration(r.time)+(r.duration&&!recording?` / ${duration(r.duration)}`:'');
 $('record-start').disabled=busy||active||!supported||!status.game?.cameraReady||($('record-kind').value==='players'&&!status.game?.authority);
 $('record-pause').disabled=busy||!['playing','recording','overdubbing','paused'].includes(r.state)||!supported;$('record-pause').textContent=r.state==='paused'?'Продолжить':'Пауза';
 $('record-stop').disabled=busy||(!active&&r.state!=='finished')||!supported;$('record-stop').textContent=recording?'Завершить запись':'Закрыть повтор';$('record-kind').disabled=active||busy;
 if(document.activeElement!==$('replay-speed'))$('replay-speed').value=r.speed||1;$('replay-speed-out').textContent='×'+(r.speed||1);
 $('replay-start').disabled=busy||!supported||recording||!['loaded','paused','finished'].includes(r.state);$('replay-start').textContent=r.state==='paused'?'▶ Продолжить':'▶ Начать';
 $('replay-restart').disabled=busy||!supported||recording||!r.id||!r.duration;
 const m=replayItems.find(x=>x.id===r.id);$('loaded-replay').textContent=r.state!=='idle'&&m?m.name:'Выберите повтор и нажмите «Загрузить».';
 $('replay-camera').checked=!!status.game?.freecam;$('replay-camera').disabled=busy||!supported||!status.game?.cameraReady||(r.kind==='camera'&&active)||recording;
 const timeline=$('replay-timeline');timeline.max=Math.max(r.duration||0,.01);if(document.activeElement!==timeline)timeline.value=r.time||0;timeline.disabled=busy||!supported||r.kind!=='camera'||!['loaded','playing','paused','finished'].includes(r.state);
 $('replay-timeline-out').textContent=`${duration(r.time)} / ${duration(r.duration)}`;$('timeline-hint').textContent=r.kind==='players'?'Игроки: таймлайн показывает прогресс. «Сначала» восстанавливает игрушки и действия.':'Камера: передвиньте ползунок, чтобы выбрать момент повтора.';
 document.querySelectorAll('.replay-card').forEach(card=>{const loaded=card.dataset.id===r.id&&r.state!=='idle';card.classList.toggle('loaded',loaded);card.querySelector('.replay-load').disabled=busy||!supported||card.dataset.ready!=='true';card.querySelector('.replay-play').disabled=busy||!supported||!loaded||recording||!['loaded','paused','finished'].includes(r.state);});
}
async function refreshReplays(){clearTimeout(replayTimer);try{const response=await fetch('/api/replays');if(!response.ok)return;const data=await response.json();const stamp=JSON.stringify(data.items);replayItems=data.items;if(stamp!==replayStamp){replayStamp=stamp;renderReplays()}}catch{}replayTimer=setTimeout(refreshReplays,3000)}
function renderReplays(){
 const host=$('replay-gallery'),trashHost=$('replay-trash');host.replaceChildren();trashHost.replaceChildren();$('replay-empty').hidden=replayItems.some(x=>!x.deleted);
 for(const m of replayItems){
  if(m.deleted){const row=document.createElement('div');row.className='trash-row';const text=document.createElement('span');text.textContent=m.name;row.append(text,button('Восстановить',async()=>{await action('/api/replay/patch',{id:m.id,deleted:false});replayStamp='';await refreshReplays()}));trashHost.append(row);continue}
  const card=document.createElement('article');card.className='snapshot replay-card';card.dataset.id=m.id;card.dataset.ready=String(m.status==='ready');
  const image=document.createElement(m.image?'img':'div');image.className='snapshot-image'+(m.image?'':' placeholder');if(m.image){image.src=`/replays/${m.id}/image.png`;image.alt=m.name;image.loading='lazy'}else image.textContent=m.kind==='camera'?'🎥 Полёт камеры':'👥 Игроки и действия';
  const body=document.createElement('div');body.className='snapshot-body';const title=document.createElement('h3');title.textContent=m.name;const details=document.createElement('div');details.className='date';details.textContent=`${m.kind==='camera'?'Камера':'Игроки'} · ${duration(m.duration)} · ${names[m.world]||'Записывается…'}`;
  const controls=document.createElement('div');controls.className='snapshot-buttons';
  const load=button('Загрузить',async()=>{selectedReplay=m.id;await action('/api/replay/load',{id:m.id})},'replay-load primary');
  const play=button('▶ Начать',()=>action('/api/replay/play',{id:m.id}),'replay-play');
  const menu=document.createElement('details'),summary=document.createElement('summary');summary.textContent='•••';menu.append(summary);const options=document.createElement('div');options.className='snapshot-menu';
  options.append(button('Название',async()=>{const name=await askName('Название повтора',m.name);if(name!==null){await action('/api/replay/patch',{id:m.id,name});replayStamp='';await refreshReplays()}}),button('В корзину',async()=>{await action('/api/replay/patch',{id:m.id,deleted:true});replayStamp='';await refreshReplays()}));menu.append(options);controls.append(load,play,menu);body.append(title,details,controls);
  if(m.kind==='players'&&m.tracks.length){const tracks=document.createElement('div');tracks.className='replay-tracks';m.tracks.forEach((t,index)=>{
   const row=document.createElement('div');row.className='replay-track';const name=document.createElement('span');name.textContent='👤 '+t.name;
   const enabled=document.createElement('label'),enabledInput=document.createElement('input');enabledInput.type='checkbox';enabledInput.checked=t.enabled;enabledInput.onchange=()=>action('/api/replay/patch',{id:m.id,track:index+1,enabled:enabledInput.checked}).catch(()=>{});enabled.append(enabledInput,'Дорожка');
   const actions=document.createElement('label'),actionsInput=document.createElement('input');actionsInput.type='checkbox';actionsInput.checked=t.actions;actionsInput.onchange=()=>action('/api/replay/patch',{id:m.id,track:index+1,actions:actionsInput.checked}).catch(()=>{});actions.append(actionsInput,'Действия');
   row.append(name,enabled,actions,button('Перезаписать',()=>action('/api/replay/play',{id:m.id,track:index+1}),'quiet'));tracks.append(row)
  });if(m.tracks.length<4)tracks.append(button('＋ Добавить игрока',()=>action('/api/replay/play',{id:m.id,track:m.tracks.length+1}),'quiet'));body.append(tracks)}
  card.append(image,body);host.append(card)
 }
 applyReplayState();
}
$('record-start').onclick=()=>action('/api/replay/record',{kind:$('record-kind').value}).catch(()=>{});
$('record-pause').onclick=()=>game('replayPause').catch(()=>{});
$('record-stop').onclick=()=>game('replayStop').then(()=>{setTimeout(()=>{replayStamp='';refreshReplays()},500)}).catch(()=>{});
$('record-kind').onchange=()=>{applyReplayState();game('replaySettings',{kind:$('record-kind').value}).catch(()=>{})};
$('replay-speed').oninput=()=>$('replay-speed-out').textContent='×'+$('replay-speed').value;$('replay-speed').onchange=()=>game('replaySettings',{speed:Number($('replay-speed').value)}).catch(()=>{});
$('replay-start').onclick=()=>action('/api/replay/play',{id:status.game?.replay?.id}).catch(()=>{});
$('replay-restart').onclick=()=>action('/api/replay/play',{id:status.game?.replay?.id,restart:true}).catch(()=>{});
$('replay-camera').onchange=()=>game('camera',{enabled:$('replay-camera').checked}).catch(()=>{});
$('replay-timeline').oninput=()=>$('replay-timeline-out').textContent=`${duration(Number($('replay-timeline').value))} / ${duration(status.game?.replay?.duration)}`;
$('replay-timeline').onchange=()=>game('replaySeek',{time:Number($('replay-timeline').value)}).catch(()=>{});
refreshReplays();

// v4.1.0: benchmark progress
setInterval(()=>{const el=$('bench-status');if(!el)return;const b=status.game?.bench;if(!b){el.textContent='';return}if(b.state==='running'){el.textContent=`Идёт замер ${b.step}/${b.total}: ${b.name}. Не трогайте камеру.`;return}if(b.state==='aborted'){el.textContent='Замер прерван, настройки возвращены.';return}const r=b.results||[];el.textContent='Готово, файл '+b.file+'. '+r.map(x=>`${x.name}: ${x.avgFps} FPS, 1% — ${x.low1Fps}`).join(' · ')},1000);

// v4.1.0: graphics presets
(()=>{let built=false,touched=0;const L={vd:'Дальность прогрузки',shadow:'Качество теней',gi:'Глобальное освещение',refl:'Отражения',fx:'Эффекты',shading:'Шейдинг',pp:'Постобработка',tex:'Текстуры',aa:'Сглаживание TAA, качество',shadowRadius:'Порог теней',dlss:'DLSS → MetalFX',screen:'Разрешение рендера',dof:'Качество размытия'};
const text=v=>Object.keys(L).map(k=>`${L[k]}: ${k==='screen'?v[k]+'%':k==='dof'?(v[k]===2?'стандартное':'облегчённое'):k==='dlss'?(v[k]?'вкл.':'выкл.'):k==='shadowRadius'?(v[k]>=0.1?'без теней у мелких и средних':v[k]>=0.05?'без теней у самых мелких':'как в игре'):v[k]}`).join(' · ');
const SHORT={close:'Крупный',medium:'Средний',far:'Дальний'};
const ROWS=[['vd','Дальность прогрузки'],['shadow','Качество теней'],['shadowRadius','Порог теней'],['gi','Глоб. освещение'],['refl','Отражения'],['fx','Эффекты'],['shading','Шейдинг'],['pp','Постобработка'],['tex','Текстуры'],['aa','Сглаживание TAA'],['dlss','DLSS → MetalFX'],['screen','Разрешение'],['dof','Размытие']];
const cell=(k,v)=>v===undefined||v===null?'—':k==='screen'?Math.round(v)+'%':k==='dof'?(v>=3?'высокое':v===2?'станд.':v===1?'облегч.':'выкл'):k==='dlss'?(v?'вкл':'выкл'):k==='shadowRadius'?(Math.round(v*100)/100).toFixed(2).replace('.',','):String(v);
let tableKey='';
function build(list){const sel=$('preset-select');sel.replaceChildren(...list.map(p=>{return new Option(p.name,p.id)}));built=true}
function table(list,game){const cols=[...list.map(p=>({id:p.id,head:SHORT[p.id]||p.name,title:p.name,values:p.values})),{id:'game',head:'Внутри игры',title:'Настройки, выставленные в самой игре',values:game||{}}];
 const key=JSON.stringify(cols.map(c=>c.values));if(key===tableKey)return;tableKey=key;
 const tb=document.createElement('table');tb.className='preset-table';const hr=tb.insertRow();hr.append(document.createElement('th'));
 cols.forEach(c=>{const th=document.createElement('th');th.textContent=c.head;th.title=c.title;th.dataset.preset=c.id;hr.append(th)});
 ROWS.forEach(([k,n])=>{const r=tb.insertRow();const th=document.createElement('th');th.scope='row';th.textContent=n;r.append(th);cols.forEach(c=>{const td=r.insertCell();td.textContent=cell(k,c.values[k]);td.dataset.preset=c.id})});
 $('preset-table').replaceChildren(tb)}
const OFF_DESC='Пресеты выключены. Порог теней по умолчанию — тени отбрасывают почти все игрушки, без теней остаётся только совсем мелкое и далёкое.';
function describe(id,list,on){const p=list.find(x=>x.id===id);$('preset-desc').textContent=on?(p?p.desc:''):OFF_DESC;const act=on?id:'game';document.querySelectorAll('#preset-table [data-preset]').forEach(e=>e.classList.toggle('active',e.dataset.preset===act))}
function label(on,id,list){const p=list.find(x=>x.id===id);if(!$('preset-enabled-label'))return;$('preset-enabled-label').textContent=on?`Пресет включён: ${p?p.name:id}`:'Пресеты выключены · графика как в настройках игры'}
$('preset-enabled').onchange=async()=>{touched=Date.now();try{await game('settings',{presetEnabled:$('preset-enabled').checked});toast($('preset-enabled').checked?'Пресет применён':'Возвращены настройки игры')}catch{}};
$('preset-select').onchange=async()=>{touched=Date.now();try{await game('settings',{preset:$('preset-select').value});toast('Пресет выбран')}catch{}};
setInterval(()=>{const g=status.game;if(!g||!g.presets)return;if(!built)build(g.presets);if(Date.now()-touched>2500){$('preset-enabled').checked=!!g.presetEnabled;if(document.activeElement!==$('preset-select'))$('preset-select').value=g.preset}label($('preset-enabled').checked,$('preset-select').value,g.presets);table(g.presets,g.gameSettings);describe($('preset-select').value,g.presets,$('preset-enabled').checked);$('preset-select').disabled=$('preset-enabled').disabled=!status.modConnected},800)})();

// v4.1.0: bokeh slider (off / 6 blades / 8 blades)
(()=>{let touched=0;const V=[0,6,8],N=['выкл','6','8'],M=['выкл','6','8'];
$('bokeh-marks').replaceChildren(...M.map((m,i)=>{const s=document.createElement('span');s.textContent=m;s.style.left=`calc(10px + ${i} * (100% - 20px) / 2)`;return s}));
$('bokeh').oninput=()=>{$('bokeh-label').textContent=N[$('bokeh').value]};
$('bokeh').onchange=async()=>{touched=Date.now();const i=Number($('bokeh').value);try{await game('settings',{bokehBlades:V[i]});toast(i?'Боке: '+N[i]:'Боке выключено')}catch{}};
setInterval(()=>{const g=status.game;if(!g)return;if(Date.now()-touched>2500&&document.activeElement!==$('bokeh')){const b=Number(g.bokehBlades)||(g.bokeh?6:0);$('bokeh').value=b>=8?2:b>=6?1:0}$('bokeh-label').textContent=N[$('bokeh').value];$('bokeh').disabled=!status.modConnected},800)})();

// v4.1.0: aperture in f-stops (maps to the mod's lens blur: f = 16 / (1 + 1.9 * blur))
(()=>{const STOPS=[1.2,1.4,2,2.8,4,5.6,8,11,16];const fmt=f=>'f/'+String(f).replace('.',',');
const toBlur=f=>Math.max(0.001,Math.round((16/f-1)/1.9*1000)/1000);const toF=b=>Math.max(0.8,16/(1+1.9*b));
$('aperture-marks').replaceChildren(...STOPS.map((f,i)=>{const s=document.createElement('span');s.textContent=String(f).replace('.',',');s.style.left=`calc(10px + ${i} * (100% - 20px) / ${STOPS.length-1})`;return s}));
const nearest=f=>STOPS.reduce((best,x,i)=>Math.abs(Math.log(x/f))<Math.abs(Math.log(STOPS[best]/f))?i:best,0);
$('aperture').oninput=()=>{$('aperture-out').textContent=fmt(STOPS[$('aperture').value])};
$('aperture').onchange=async()=>{const f=STOPS[$('aperture').value];try{await game('settings',{lensBlur:toBlur(f)});toast('Диафрагма '+fmt(f))}catch{}};
setInterval(()=>{const g=status.game;if(!g||document.activeElement===$('aperture'))return;const b=Number(g.lensBlur)||0;
 if(b<=0){$('aperture').value=8;$('aperture-out').textContent='выкл.';return}
 const f=toF(b),i=nearest(f);$('aperture').value=i;$('aperture-out').textContent=Math.abs(STOPS[i]-f)/f<0.03?fmt(STOPS[i]):'≈ f/'+f.toFixed(1).replace('.',',')},800)})();

// v4.1.0: focus distance on a lens-ring (logarithmic) scale, 0.1–50 m
(()=>{const FMIN=0.1,FMAX=50,K=Math.log(FMAX/FMIN),MARKS=[0.1,0.2,0.5,1,2,5,10,20,50];
const toD=p=>FMIN*Math.exp(K*p/1000),toP=d=>Math.round(1000*Math.log(Math.min(FMAX,Math.max(FMIN,d))/FMIN)/K);
const round=d=>d<1?Math.round(d*100)/100:d<10?Math.round(d*10)/10:Math.round(d);
const fmt=d=>String(round(d)).replace('.',',')+' м';
const el=$('focusDistance'),out=$('focusDistance-out');
$('focus-marks').replaceChildren(...MARKS.map(d=>{const s=document.createElement('span');s.textContent=String(d).replace('.',',');s.style.left=`calc(10px + ${(Math.log(d/FMIN)/K).toFixed(4)} * (100% - 20px))`;return s}));
el.oninput=()=>{out.textContent=fmt(toD(Number(el.value)))};
el.onchange=async()=>{try{await game('settings',{focusDistance:round(toD(Number(el.value)))})}catch{}};
setInterval(()=>{const g=status.game||{};if(document.activeElement===el)return;const d=Number(g.focusDistance??5);el.value=toP(d);out.textContent=fmt(d)},500)})();

// v4.1.0: glow softness slider (0 = as in the game … 3)
(()=>{let touched=0;const el=$('glow'),out=$('glow-out');
$('glow-marks').replaceChildren(...[0,1,2,3].map(v=>{const s=document.createElement('span');s.textContent=v;s.style.left=`calc(10px + ${v} * (100% - 20px) / 3)`;return s}));
el.oninput=()=>{out.textContent=el.value};
el.onchange=async()=>{touched=Date.now();try{await game('settings',{glow:Number(el.value)});toast('Мягкость свечения: '+el.value)}catch{}};
setInterval(()=>{const g=status.game;if(!g)return;if(Date.now()-touched>2500&&document.activeElement!==el)el.value=String(g.glow||0);out.textContent=el.value;el.disabled=!status.modConnected},800)})();
