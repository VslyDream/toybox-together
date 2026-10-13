-- Coordinate tracks plus native GAS inputs: replay actors are real local players.
local M={}
function M.new(ctx)
 local H,S,valid,json,ROOT=ctx.H,ctx.S,ctx.valid,ctx.json,ctx.ROOT
 local R={state='idle',speed=1,time=0,kind='camera'}
 local actors,original,previous,recorded={},{},{},{}
 local suppress=false;local mapSettings=nil;local viewportSettings=nil;local timeDilation=nil
 local hookDefinitions,hooks,pendingActivations={},{},{}
 local function recordingPlayers()
  return not suppress and R.kind=='players' and (R.state=='recording' or R.state=='overdubbing')
 end
 local function v(x)return {X=x.X,Y=x.Y,Z=x.Z} end
 local function r(x)return {Pitch=x.Pitch,Yaw=x.Yaw,Roll=x.Roll} end
 local function now()return H:GetGameplayStatics():GetRealTimeSeconds(H:GetWorld()) end
 local function safeid(id)assert(type(id)=='string' and #id==32 and id:match('^[a-f0-9]+$'),'Некорректная запись.');return id end
 local function publish()
  S.replay={state=R.state,pausedState=R.pausedState,speed=R.speed,time=R.time,duration=R.data and R.data.duration or 0,id=R.id,kind=R.kind,track=R.overdub,tracks=R.data and #R.data.tracks or 0}
 end
 local function appearance(p)
  local a=p:GetAppearance()
  if a.Parts then
   local b={Body=valid(a.Body) and a.Body:GetFullName() or nil,SkinColorIndex=a.SkinColorIndex,Parts={}}
   for i=1,#a.Parts do local x=a.Parts[i];if type(x)=='userdata' then x=x:get() end
    b.Parts[i]={Part=valid(x.Part) and x.Part:GetFullName() or nil,ColorIndex=x.ColorIndex}
   end
   return b
  end
  local b={PresetIndex=a.PresetIndex,SkinColorIndex=a.SkinColorIndex,SlotMeshIndices={},SlotColorIndices={}}
  for i=1,#a.SlotMeshIndices do local x=a.SlotMeshIndices[i];b.SlotMeshIndices[i]=type(x)=='userdata' and x:get() or x end
  for i=1,#a.SlotColorIndices do local x=a.SlotColorIndices[i];b.SlotColorIndices[i]=type(x)=='userdata' and x:get() or x end
  return b
 end
 local function applyAppearance(p,a)
  if a.Parts then
   local function asset(name,class)
    if not name then return CreateInvalidObject() end
    local object=StaticFindObject(name:match('^[^ ]+ (.+)$') or name)
    assert(valid(object) and object:IsA(class),'Внешность из записи не найдена в этой версии игры.')
    return object
   end
   local resolved={Body=asset(a.Body,'/Script/MyToyStore.TS_CharacterBodyDefinition'),SkinColorIndex=a.SkinColorIndex,Parts={}}
   for i,x in ipairs(a.Parts) do resolved.Parts[i]={Part=asset(x.Part,'/Script/MyToyStore.TS_CharacterPartDefinition'),ColorIndex=x.ColorIndex} end
   p:SetAppearanceLocal(resolved)
  elseif p:GetAppearance().Parts then
   -- Old slot indices have no asset identity in the new customization system.
   p:SetAppearanceLocal(p:GetAppearance())
  else p:SetAppearanceLocal(a) end
 end
 local function held(p)
  local out={};for i=1,#p.Interaction.HeldStack do out[i]=p.Interaction.HeldStack[i]:GetFullName() end;return out
 end
 local function sample(p,pc,t)
  return {t=t,p=v(p:K2_GetActorLocation()),r=r(p:K2_GetActorRotation()),look=r(pc:GetControlRotation()),view=v(pc.PlayerCameraManager:GetCameraLocation()),cameraMode=p.CurrentCameraMode,velocity=v(p:GetVelocity()),movementMode=p.CharacterMovement.MovementMode,customMode=p.CharacterMovement.CustomMovementMode}
 end
 local function sourceId(p)
  local ps=p.PlayerState
  return valid(ps) and ps:GetPersistentPlayerId():ToString() or tostring(p:GetAddress())
 end
 local function event(p,e)
  if not recordingPlayers() or not valid(p) then return end
  local entry=recorded[p:GetAddress()];if not entry then return end
  if e.type=='toolThrow' then entry.ignoreDropUntil=R.time+.15 end
  if e.type=='bulkGrab' then entry.ignorePickupUntil=R.time+.15 end
  if (e.type=='press' or e.type=='release') and e.input==1001 and entry.ignoreDropUntil and R.time<=entry.ignoreDropUntil then return end
  if (e.type=='press' or e.type=='release') and e.input==1000 and entry.ignorePickupUntil and R.time<=entry.ignorePickupUntil then return end
  e.t=e.t or R.time
  local key=e.type..':'..tostring(e.input or '')
  entry.last=entry.last or {}
  if (e.type=='press' or e.type=='release') and entry.last[key] and R.time-entry.last[key]<0.045 then return end
  entry.last[key]=R.time;entry.track.events[#entry.track.events+1]=e
 end
 local function hook(path,fn)
  hookDefinitions[#hookDefinitions+1]={path=path,callback=function(...)
   -- Check before unwrapping any borrowed Unreal parameters.
   if not recordingPlayers() then return end
   local good,e=pcall(fn,...);if not good then S.replayError=tostring(e) end
  end}
 end
 local function stopHooks()
  for i=#hooks,1,-1 do local h=hooks[i];UnregisterHook(h.path,h.pre,h.post);hooks[i]=nil end
  pendingActivations={}
 end
 local function startHooks()
  if #hooks>0 then return end
  for _,h in ipairs(hookDefinitions) do
   local ok,pre,post=pcall(RegisterHook,h.path,h.callback)
   if not ok then stopHooks();error('Не удалось включить запись действий: '..tostring(pre)) end
   hooks[#hooks+1]={path=h.path,pre=pre,post=post}
  end
 end
 local function flushActivations()
  local pending=pendingActivations;pendingActivations={}
  if not recordingPlayers() then return end
  for _,e in ipairs(pending) do if valid(e.asc) and valid(e.p) and recorded[e.p:GetAddress()] then
   -- Struct arrays must be read on the game-thread update, outside the RPC hook's Lua stack.
   local specs=e.asc.ActivatableAbilities.Items
   for i=1,#specs do local spec=specs[i];if spec.Handle.Handle==e.handle then
    event(e.p,{type='press',input=spec.InputID,t=e.t});break
   end end
  end end
 end
 hook('/Script/MyToyStore.TS_DropItemAbility:HandleThrowReleased',function(a,charge)
  if (S.throwRemaining or 0)>0 then return end
  local ability=a:get();local p=ability:GetAvatarActorFromActorInfo()
  if valid(p) then event(p,{type='throw',charge=charge:get(),clean=(S.throwRemaining or 0)>0}) end
 end)
 hook('/Script/MyToyStore.TS_Character:HandleHeldScrolled',function(p,direction)
  event(p:get(),{type='scroll',direction=direction:get()})
 end)
 hook('/Script/GameplayAbilities.AbilitySystemComponent:ServerTryActivateAbility',function(asc,handle,pressed)
  local a=asc:get();if not valid(a) then return end;local p=a.AvatarActor
  if not valid(p) or not recorded[p:GetAddress()] then return end
  pendingActivations[#pendingActivations+1]={asc=a,p=p,handle=handle:get().Handle,t=R.time}
 end)
 hook('/Script/GameplayAbilities.AbilitySystemComponent:PressInputID',function(asc,id)
  local p=asc:get().AvatarActor;if valid(p) then event(p,{type='press',input=id:get()}) end
 end)
 hook('/Script/GameplayAbilities.AbilitySystemComponent:ReleaseInputID',function(asc,id)
  local p=asc:get().AvatarActor;if valid(p) then event(p,{type='release',input=id:get()}) end
 end)
 local function restoreOriginal()
  if R.pauseWorld and valid(R.pauseWorld.world) then H:GetGameplayStatics():SetGamePaused(R.pauseWorld.world,R.pauseWorld.value) end;R.pauseWorld=nil
  for _,a in ipairs(original) do if valid(a.pc) and valid(a.p) then a.pc:EnableInput(a.pc);a.p:EnableInput(a.pc);a.pc:ResetIgnoreMoveInput();a.pc:ResetIgnoreLookInput();if not S.freecam then a.pc:SetViewTargetWithBlend(valid(a.view) and a.view or a.p,0,0,0,false) end;a.p:SetActorHiddenInGame(a.hidden);a.p:SetActorEnableCollision(a.collision);if valid(a.p.CharacterMovement) then a.p.CharacterMovement:SetMovementMode(a.mode,a.custom);a.p.CharacterMovement:SetComponentTickEnabled(a.tick);a.p.CharacterMovement.Velocity={X=0,Y=0,Z=0} end end end
  original={}
  if timeDilation and valid(timeDilation.object) then timeDilation.object.TimeDilation=timeDilation.value end;timeDilation=nil
  if S.freecam then ctx.lockCameraControls() end
 end
 local function restoreControls()
  restoreOriginal()
  -- Closing a take must not destroy real toys still held by temporary players.
  local seen={};for _,it in ipairs(FindAllOf('TS_ItemActor') or {}) do seen[it:GetAddress()]=true end
  local wasSuppress=suppress;suppress=true
  for _,a in ipairs(actors) do if a.clone and valid(a.pc) and valid(a.p) then
   local count=a.p.Interaction:GetHeldCount()
   for i=1,count do local before=a.p.Interaction:GetHeldCount();ctx.throwForTrack(a.p);assert(a.p.Interaction:GetHeldCount()<before,'Не удалось освободить руки игрока повтора. Игрушки сохранены у персонажа.') end
   H:GetGameplayStatics():RemovePlayer(a.pc,true)
  end end
  suppress=wasSuppress
  local lane=0;for _,it in ipairs(FindAllOf('TS_ItemActor') or {}) do if not seen[it:GetAddress()] and valid(it.Mesh) then local pos=it.Mesh:K2_GetComponentLocation();it.Mesh:K2_SetWorldLocation({X=pos.X+(lane%4-1.5)*35,Y=pos.Y,Z=pos.Z+(math.floor(lane%8/4)-.5)*35},false,{},true);it.Mesh:SetCollisionResponseToChannel(5,0);lane=lane+1 end end
  actors={}
  if mapSettings then mapSettings.object.bUseSplitscreen=mapSettings.value;mapSettings=nil end
  if viewportSettings and valid(viewportSettings.object) then viewportSettings.object.MaxSplitscreenPlayers=viewportSettings.value end;viewportSettings=nil
 end
 local function saveData(checkpoint)
  local data=R.data
  if R.overdub then
   data={};for k,x in pairs(R.data) do data[k]=x end;data.tracks={};for i,tr in ipairs(R.data.tracks) do data.tracks[i]=i==R.overdub and R.newTrack or tr end
   if R.overdub>#data.tracks then data.tracks[R.overdub]=R.newTrack end
  end
  data.duration=math.max(data.duration or 0,R.time)
  local dest=ROOT..'/bridge/replay-'..safeid(R.id)..'.json'
  local f=assert(io.open(dest..'.tmp','wb'));f:write(json.encode(data));f:close();os.remove(dest);assert(os.rename(dest..'.tmp',dest))
  if checkpoint then S.replayCheckpoint={id=R.id,time=now(),duration=data.duration} else S.replayFinished={id=R.id,time=now(),duration=data.duration} end
 end
 local function stop(save)
  flushActivations();stopHooks()
  if save and R.data and (R.state=='recording' or R.state=='overdubbing' or R.pausedState=='recording' or R.pausedState=='overdubbing') then
   if R.overdub then R.data.tracks[R.overdub]=R.newTrack end
   R.data.duration=math.max(R.data.duration or 0,R.time)
   saveData(false)
  end
  restoreControls();R.state='idle';R.pausedState=nil;R.overdub=nil;R.data=nil;R.time=0;recorded={};previous={};publish()
 end
 local function newTrack(p,pc,id,name)
  return {id=id,name=name,sourceId=sourceId(p),appearance=appearance(p),initialHeld=held(p),frames={sample(p,pc,0)},events={},enabled=true,actions=true}
 end
 local function record(id,kind)
  assert(R.state=='idle','Сначала завершите текущую запись или повтор.')
  if kind=='players' then ctx.authority();assert(S.ready,'Дождитесь загрузки игрушек.');ctx.stopcam();S.tool=false
  else ctx.startcam() end
  R.id=safeid(id);R.kind=kind;R.time=0;R.last=now();R.sampleAt=0;R.data={schema=2,kind=kind,world=S.world,mode=S.mode,duration=0,timeScale=H:GetWorldSettings().TimeDilation,tracks={}};recorded={};previous={}
  if kind=='players' then
   local list=FindAllOf('TS_Character') or {}
   for _,p in ipairs(list) do local pc=p.Controller
    if valid(pc) and pc:IsA('/Script/Engine.PlayerController') then
     local tr=newTrack(p,pc,'p'..(#R.data.tracks+1),'Игрок '..(#R.data.tracks+1));R.data.tracks[#R.data.tracks+1]=tr;recorded[p:GetAddress()]={p=p,pc=pc,track=tr}
    end
   end
   assert(#R.data.tracks>0 and #R.data.tracks<=4,'Поддерживаются записи до четырёх игроков.')
  else R.data.tracks={{id='camera',name='Камера',frames={},events={},enabled=true,actions=true}} end
  if kind=='players' then startHooks() end
  R.state='recording';R.checkpointAt=2;S.replayError=nil;publish();return {id=R.id}
 end
 local function disable(p,pc)
  original[#original+1]={p=p,pc=pc,view=pc:GetViewTarget(),mode=p.CharacterMovement.MovementMode,custom=p.CharacterMovement.CustomMovementMode,tick=p.CharacterMovement:IsComponentTickEnabled(),hidden=p.bHidden,collision=p:GetActorEnableCollision()}
  pc:DisableInput(pc);p:DisableInput(pc);pc:ResetIgnoreMoveInput();pc:ResetIgnoreLookInput();pc:SetIgnoreMoveInput(true);pc:SetIgnoreLookInput(true);p.CharacterMovement:SetComponentTickEnabled(false)
 end
 local function setpose(a,f)
  local p,pc=a.p,a.pc
  if a.clone then p:SetActorEnableCollision(false);p.CharacterMovement:SetComponentTickEnabled(false) end
  p:K2_SetActorLocationAndRotation(f.p,{Pitch=0,Yaw=f.r.Yaw,Roll=0},false,{},true);pc:SetControlRotation(f.look)
  p.FirstPersonCamera.bUsePawnControlRotation=true;local mode=f.cameraMode or 1;if p.CurrentCameraMode~=mode then p:ChangeCameraMode(mode) end
  if not f.movementMode and f.view then p.FirstPersonCamera.bUsePawnControlRotation=false;p.FirstPersonCamera:K2_SetWorldLocationAndRotation(f.view,f.look,false,{},true) end
  local movement=p.CharacterMovement
  -- Disable displacement, retaining locomotion state and velocity for the anim graph.
  local mode=f.movementMode or (math.abs(f.velocity.Z)>40 and 3 or 1)
  if mode==0 then mode=1 end
  if movement.MovementMode~=mode or movement.CustomMovementMode~=(f.customMode or 0) then movement:SetMovementMode(mode,f.customMode or 0) end
  movement.Velocity=f.velocity
 end
 local function spawnTrack(track,useOriginal)
  local pc,p,a
  if useOriginal then p,pc=ctx.authority();disable(p,pc)
  else
   local settings=StaticFindObject('/Script/EngineSettings.Default__GameMapsSettings')
   if not mapSettings then mapSettings={object=settings,value=settings.bUseSplitscreen} end;settings.bUseSplitscreen=false
   local viewport=H:GetGameViewportClient();if valid(viewport) then if not viewportSettings then viewportSettings={object=viewport,value=viewport.MaxSplitscreenPlayers} end;viewport.MaxSplitscreenPlayers=math.max(viewport.MaxSplitscreenPlayers,5) end
   pc=H:GetGameplayStatics():CreatePlayer(H:GetWorld(),-1,true);assert(valid(pc) and valid(pc.Pawn),'Не удалось создать дополнительного игрока.');p=pc.Pawn
   a={p=p,pc=pc,track=track,index=1,eventIndex=1,clone=true};actors[#actors+1]=a
   if p.Mesh:IsSimulatingPhysics(FName('None')) then p:Multicast_RestoreAfterRagdoll() end
   p:SetActorEnableCollision(false)
   pc:DisableInput(pc);p:DisableInput(pc);pc:SetIgnoreMoveInput(true);pc:SetIgnoreLookInput(true);p.CharacterMovement:SetComponentTickEnabled(false)
   if valid(pc.HUDLayout) then pc.HUDLayout:SetVisibility(1) end
  end
  if not a then a={p=p,pc=pc,track=track,index=1,eventIndex=1,clone=not useOriginal};actors[#actors+1]=a end
  if track.appearance then applyAppearance(p,track.appearance) end
  setpose(a,track.frames[1])
  return a
 end
 local function readData(id)
  local path=ROOT..'/bridge/replay-'..safeid(id)..'.json'
  local f=assert(io.open(path,'rb'),'Файл повтора не найден.');local ok,data=pcall(json.decode,f:read('*a'));f:close();assert(ok and data.schema==2 and data.kind and data.tracks,'Файл повтора повреждён.');return data
 end
 local function loadReplay(id,overdub,observer)
  assert(R.state=='idle','Сначала завершите текущую запись или повтор.')
  local data=readData(id);assert(data.world==S.world,'Сначала загрузите карту повтора.')
  R.data=data;R.id=id;R.kind=data.kind;R.time=0;R.last=now();R.overdub=overdub;actors={};recorded={};previous={};R.cameraIndex=nil
  if data.kind=='players' then
   local p,pc=ctx.authority();assert(S.ready,'Дождитесь загрузки игрушек.');ctx.stopcam();S.tool=false
   if not overdub then disable(p,pc);p:SetActorHiddenInGame(true);p:SetActorEnableCollision(false) end
   for i,tr in ipairs(data.tracks) do if tr.enabled~=false and i~=overdub then
    local a=spawnTrack(tr,false)
    if #tr.initialHeld>0 then ctx.restoreTrackHeld(tr.initialHeld,a.p,a.pc) end
   end end
   if overdub then
    assert(overdub>=1 and overdub<=math.min(4,#data.tracks+1),'Дорожка не найдена.')
    local selected=data.tracks[overdub];local first=(selected or data.tracks[1]).frames[1];p:K2_SetActorLocationAndRotation(first.p,{Pitch=0,Yaw=first.r.Yaw,Roll=0},false,{},true);pc:SetControlRotation(first.look)
    if selected and #selected.initialHeld>0 then ctx.restoreTrackHeld(selected.initialHeld,p,pc) end
    R.newTrack=newTrack(p,pc,selected and selected.id or 'p'..overdub,selected and selected.name or 'Игрок '..overdub);recorded[p:GetAddress()]={p=p,pc=pc,track=R.newTrack}
   end
   local ws=H:GetWorldSettings();timeDilation={object=ws,value=ws.TimeDilation};ws.TimeDilation=R.speed*(data.timeScale or 1)
   R.pauseWorld={world=H:GetWorld(),value=H:GetGameplayStatics():IsGamePaused(H:GetWorld())};H:GetGameplayStatics():SetGamePaused(H:GetWorld(),true)
   if not overdub then
    if observer~=false then ctx.startcam();local f=data.tracks[1].frames[1];ctx.setCamera({p=f.view or f.p,r=f.look,fov=S.fov,focusDistance=S.focusDistance,lensBlur=S.lensBlur})
    elseif actors[1] then pc:SetViewTargetWithBlend(actors[1].p,0,0,0,false) end
   end
  else ctx.startcam();ctx.setCamera(data.tracks[1].frames[1]) end
  R.state='loaded';R.checkpointAt=2;S.replayError=nil;publish();return {loaded=true}
 end
 local function start()
  assert(R.state=='loaded' or R.state=='paused','Сначала загрузите повтор.')
  if R.kind=='players' and (R.overdub or R.pausedState=='recording') then startHooks() end
  if R.state=='paused' then R.state=R.pausedState;R.pausedState=nil else R.state=R.overdub and 'overdubbing' or 'playing' end
  R.last=now()
  if R.kind=='players' then H:GetGameplayStatics():SetGamePaused(H:GetWorld(),false) end
  if timeDilation then timeDilation.object.TimeDilation=R.speed*(R.data.timeScale or 1) end
  publish();return {playing=true}
 end
 local function pause()
  flushActivations()
  if R.state=='paused' and R.kind=='players' and (R.pausedState=='recording' or R.pausedState=='overdubbing') then startHooks() end
  if R.state=='paused' then R.state=R.pausedState;R.pausedState=nil;R.last=now()
   if R.kind=='players' then H:GetGameplayStatics():SetGamePaused(H:GetWorld(),false) end
  elseif R.state=='playing' or R.state=='recording' or R.state=='overdubbing' then R.pausedState=R.state;R.state='paused' end
  if R.state=='paused' and R.kind=='players' then
   stopHooks()
   if not R.pauseWorld then R.pauseWorld={world=H:GetWorld(),value=H:GetGameplayStatics():IsGamePaused(H:GetWorld())} end;H:GetGameplayStatics():SetGamePaused(H:GetWorld(),true)
  elseif R.state~='paused' and timeDilation then timeDilation.object.TimeDilation=R.speed*(R.data.timeScale or 1) end
  publish();return {}
 end
 local function blend(a,b,t)
  local o={};for k,x in pairs(a) do o[k]=x+(b[k]-x)*t end;return o
 end
 local function blendrot(a,b,t)
  local o={};for k,x in pairs(a) do local delta=(b[k]-x+180)%360-180;o[k]=x+delta*t end;return o
 end
 local function evaluate(track,a,t)
  local frames=track.frames
  while a.index<#frames and frames[a.index+1].t<=t do a.index=a.index+1 end
  local f=frames[a.index];local next=frames[math.min(a.index+1,#frames)]
  local alpha=next.t>f.t and math.min(1,math.max(0,(t-f.t)/(next.t-f.t))) or 0
  return {p=blend(f.p,next.p,alpha),r=blendrot(f.r,next.r,alpha),look=f.look and blendrot(f.look,next.look,alpha),view=f.view and next.view and blend(f.view,next.view,alpha),cameraMode=f.cameraMode,movementMode=f.movementMode,customMode=f.customMode,velocity=f.velocity and blend(f.velocity,next.velocity,alpha),fov=f.fov and f.fov+(next.fov-f.fov)*alpha,focusDistance=f.focusDistance and f.focusDistance+(next.focusDistance-f.focusDistance)*alpha,lensBlur=f.lensBlur and f.lensBlur+(next.lensBlur-f.lensBlur)*alpha}
 end
 local function execute(a,e)
  suppress=true
  local ok,err=pcall(function()
   local asc=a.p.AbilitySystemComponent
   if e.type=='press' then asc:PressInputID(e.input)
   elseif e.type=='release' then asc:ReleaseInputID(e.input)
   elseif e.type=='throw' or e.type=='toolThrow' then
    if e.type=='toolThrow' then ctx.throwForTrack(a.p)
    else
     asc:TryActivateAbilityByClass(StaticFindObject('/Script/MyToyStore.TS_DropItemAbility'),true)
     for _,b in ipairs(FindAllOf('TS_DropItemAbility') or {}) do local av=b:GetAvatarActorFromActorInfo();if valid(av) and av:GetAddress()==a.p:GetAddress() then b:HandleThrowReleased(e.charge or 1);break end end
    end
   elseif e.type=='bulkGrab' then ctx.grabForTrack(e.targets,a.p,a.pc,R.data.legacyDefinitions)
   elseif e.type=='scroll' then a.p:HandleHeldScrolled(e.direction) end
  end)
  suppress=false;if not ok then error(err) end
 end
 local function executeBatch(a,events)
  local clean=false;for _,e in ipairs(events) do if e.clean then clean=true;break end end
  local seen={};if clean then for _,it in ipairs(FindAllOf('TS_ItemActor') or {}) do seen[it:GetAddress()]=true end end
  for _,e in ipairs(events) do execute(a,e) end
  if clean then
   local right=H:GetKismetMathLibrary():GetRightVector(a.pc:GetControlRotation())
   for _,it in ipairs(FindAllOf('TS_ItemActor') or {}) do if not seen[it:GetAddress()] and valid(it.Mesh) then
    a.throwIndex=a.throwIndex or 0;local lane=a.throwIndex%8;a.throwIndex=a.throwIndex+1
    local side=(lane%4-1.5)*35;local up=(math.floor(lane/4)-.5)*35;local pos=it.Mesh:K2_GetComponentLocation()
    it.Mesh:K2_SetWorldLocation({X=pos.X+right.X*side,Y=pos.Y+right.Y*side,Z=pos.Z+up},false,{},true);it.Mesh:SetCollisionResponseToChannel(5,0)
   end end
  end
 end
 local function update(input,dt)
  flushActivations()
  local n=now();local elapsed=math.max(0,n-(R.last or n));R.last=n
  if R.state=='idle' or R.state=='loaded' or R.state=='paused' or R.state=='finished' then publish();return end
  R.time=R.time+elapsed*(R.state=='recording' and 1 or R.speed)
  if R.time>=1800 and (R.state=='recording' or R.state=='overdubbing') then R.time=1800;stop(true);return end
  if R.state=='recording' or R.state=='overdubbing' then
   for address,a in pairs(recorded) do if valid(a.p) and valid(a.pc) then
    local specs=a.p.AbilitySystemComponent.ActivatableAbilities.Items;local prev=previous[address] or {}
    for i=1,#specs do local spec=specs[i];local key=spec.InputID;local old=prev[key]
     if old then
      if spec.InputPressed~=old.pressed then event(a.p,{type=spec.InputPressed and 'press' or 'release',input=key})
      elseif spec.ActiveCount>old.active and not spec.InputPressed then event(a.p,{type='press',input=key}) end
     end
     prev[key]={pressed=spec.InputPressed,active=spec.ActiveCount}
    end
    previous[address]=prev
    if R.time>=(R.sampleAt or 0) then a.track.frames[#a.track.frames+1]=sample(a.p,a.pc,R.time) end
   end end
   if R.kind=='camera' and R.time>=(R.sampleAt or 0) then
    local cam=ctx.getCamera();assert(cam,'Свободная камера выключена во время записи.')
    R.data.tracks[1].frames[#R.data.tracks[1].frames+1]={t=R.time,p=v(cam.pos),r=r(cam.rotation),fov=S.fov,focusDistance=S.focusDistance,lensBlur=S.lensBlur}
   end
   if R.time>=(R.sampleAt or 0) then R.sampleAt=R.time+1/60 end
   R.data.duration=math.max(R.data.duration,R.time)
   if R.time>=(R.checkpointAt or 2) then saveData(true);R.checkpointAt=R.time+30 end
  end
  if R.state=='playing' or R.state=='overdubbing' then
   if R.kind=='camera' then
    R.cameraIndex=R.cameraIndex or {index=1};ctx.setCamera(evaluate(R.data.tracks[1],R.cameraIndex,R.time))
   else for _,a in ipairs(actors) do if valid(a.p) and valid(a.pc) and a.track.enabled~=false then
    setpose(a,evaluate(a.track,a,R.time))
    if a.pending then executeBatch(a,a.pending) end;a.pending={}
    while a.eventIndex<=#a.track.events and a.track.events[a.eventIndex].t<=R.time do
     local e=a.track.events[a.eventIndex];if a.track.actions~=false then a.pending[#a.pending+1]=e end;a.eventIndex=a.eventIndex+1
    end
   end end end
   if R.time>=R.data.duration and R.state=='playing' then
    for _,a in ipairs(actors) do if a.pending then executeBatch(a,a.pending);a.pending={} end end
    R.time=R.data.duration;R.state='finished'
    if R.pauseWorld and valid(R.pauseWorld.world) then H:GetGameplayStatics():SetGamePaused(R.pauseWorld.world,R.pauseWorld.value) end;R.pauseWorld=nil
    if timeDilation and valid(timeDilation.object) then timeDilation.object.TimeDilation=timeDilation.value end;timeDilation=nil
    for _,a in ipairs(actors) do if a.clone and valid(a.p) then a.p.CharacterMovement.Velocity={X=0,Y=0,Z=0} end end
   end
  end
  publish()
 end
 local function command(q)
  if q.action=='replayRecord' then return record(q.replayId,q.kind)
  elseif q.action=='replayLoad' or q.action=='replayPlay' then local ok,result=pcall(loadReplay,q.replayId,q.track and math.floor(q.track),q.observer);if not ok then stop(false);error(result) end;if q.cameraPose and R.kind=='players' and not R.overdub and ctx.getCamera() then ctx.setCamera(q.cameraPose) end;if q.action=='replayPlay' then return start() end;return result
  elseif q.action=='replayStart' then return start()
  elseif q.action=='replaySeek' then
   assert(R.kind=='camera' and (R.state=='loaded' or R.state=='playing' or R.state=='paused' or R.state=='finished'),'Перемотка доступна для камеры. Для игроков используйте «Сначала».')
   R.time=math.max(0,math.min(R.data.duration,tonumber(q.time) or 0));R.cameraIndex={index=1};ctx.setCamera(evaluate(R.data.tracks[1],R.cameraIndex,R.time));R.last=now();if R.state=='finished' then R.state='loaded' end;publish();return {}
  elseif q.action=='replayPause' then return pause()
  elseif q.action=='replayStop' then stop(true);return {}
  elseif q.action=='replayTrack' then
   if q.replayId~=R.id or not R.data or R.kind~='players' then return {} end
   if R.state=='idle' or R.state=='finished' then return {} end
   local index=math.floor(q.track);local tr=R.data.tracks[index];assert(tr,'Дорожка не найдена.')
   if R.overdub==index then return {} end
   if q.enabled~=nil then tr.enabled=q.enabled and true or false end
   if q.actions~=nil then tr.actions=q.actions and true or false end
   local found=nil;for _,a in ipairs(actors) do if a.track==tr then found=a;break end end
   if not found and tr.enabled~=false and (R.state=='loaded' or R.state=='playing' or R.state=='paused' or R.state=='overdubbing') then
    found=spawnTrack(tr,false);if #tr.initialHeld>0 then ctx.restoreTrackHeld(tr.initialHeld,found.p,found.pc) end
    while found.eventIndex<=#tr.events and tr.events[found.eventIndex].t<=R.time do found.eventIndex=found.eventIndex+1 end
   end
   if found and valid(found.p) then
    if tr.enabled~=false then while found.eventIndex<=#tr.events and tr.events[found.eventIndex].t<=R.time do found.eventIndex=found.eventIndex+1 end end
    found.p:SetActorHiddenInGame(tr.enabled==false);found.p:SetActorEnableCollision(false)
    if tr.actions==false or tr.enabled==false then
     suppress=true
     for _,ability in ipairs(FindAllOf('TS_GameplayAbility') or {}) do local av=ability:GetAvatarActorFromActorInfo();if valid(av) and av:GetAddress()==found.p:GetAddress() then ability:K2_CancelAbility() end end
     local specs=found.p.AbilitySystemComponent.ActivatableAbilities.Items;for i=1,#specs do if specs[i].InputPressed then found.p.AbilitySystemComponent:ReleaseInputID(specs[i].InputID) end end
     suppress=false;found.pending={}
    end
   end
   publish();return {}
  elseif q.action=='replaySettings' then R.speed=math.max(.1,math.min(4,tonumber(q.speed) or R.speed));if timeDilation then timeDilation.object.TimeDilation=R.speed*(R.data.timeScale or 1) end;if R.state=='idle' then R.kind=q.kind or R.kind;R.id=q.replayId and safeid(q.replayId) or R.id end;publish();return {}
  end
 end
 publish()
 return {command=command,withoutRecording=function(f)local before=suppress;suppress=true;local ok,e=pcall(f);suppress=before;if not ok then error(e) end;return e end,update=function(...)local ok,e=pcall(update,...);if not ok then stop(false);error(e) end end,stop=stop,event=event,follow=function()if not S.freecam and R.kind=='players' and R.state~='idle' and not R.overdub and actors[1] and valid(actors[1].p) then H:GetPlayerController():SetViewTargetWithBlend(actors[1].p,0,0,0,false) end end,ownsControls=function()return R.kind=='players' and R.state~='idle' and not R.overdub end,isCameraPlayback=function()return R.kind=='camera' and (R.state=='loaded' or R.state=='playing' or R.state=='paused' or R.state=='finished') end,request=function(action)S.replayRequest={token=tostring(os.time())..':'..tostring(now()),action=action,id=R.id,kind=R.kind} end,toggleRecord=function()if R.state=='finished' then stop(false) end;if R.state~='idle' then pause() else S.replayRequest={token=tostring(now()),action='record',kind=R.kind} end end,togglePlay=function()if R.state=='loaded' then start() elseif R.state=='playing' or R.state=='paused' then pause() elseif R.state=='idle' or R.state=='finished' then S.replayRequest={token=tostring(now()),action='play',id=R.id} end end}
end
return M
