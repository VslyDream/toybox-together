-- Toybox Together v4. Game-thread mutations, independent observer, transactional IPC.
local H=require('UEHelpers')
local json=require('json')
local ROOT=os.getenv('LOCALAPPDATA')..'/ToyboxTogether'
local hasRoot,installedRoot=pcall(require,'ToyboxRoot')
if hasRoot and type(installedRoot)=='string' then ROOT=installedRoot end
local BRIDGE=ROOT..'/bridge/'
local function read(path)
 local f=io.open(path,'rb'); if not f then return nil end
 local s=f:read('*a'); f:close();s=s:gsub('^\239\187\191','');local ok,v=pcall(json.decode,s); if ok then return v end
end
local function write(path,v)
 local f=io.open(path,'wb'); if f then f:write(json.encode(v)); f:close() end
end
local config=read(ROOT..'/config.json') or {}
local S={version='4.1.0',started=os.time(),freecam=false,tool=false,speed=600,fov=90,sensitivity=0.12,smoothing=0.12,rotationSmoothing=0.08,focusDistance=5,lensBlur=0,batch=20,hands=200,noCooldown=false,maxFps=60,presetEnabled=false,preset='medium',bokeh=false,bokehBlades=0,glow=0}
local replay=nil
local C=nil
local lastFov=nil
local opticsOriginal={}
local opticsFields={"DepthOfFieldFocalDistance","DepthOfFieldFstop","DepthOfFieldScale","DepthOfFieldSensorWidth"}
-- ===== Bokeh (v4.1.0) =====
-- 6-blade aperture on the free camera + Diaphragm DOF highlight scattering (bright out-of-focus points become hexagons).
local BOKEH_BLADES=6 -- fallback; the panel slider sets S.bokehBlades (0 off, 6 or 8)
local BOKEH_CVARS={{'r.DOF.Gather.EnableBokehSettings',1},{'r.DOF.Scatter.EnableBokehSettings',1},{'r.DOF.Recombine.EnableBokehSettings',1},
 {'r.DOF.Scatter.BackgroundCompositing',2},{'r.DOF.Scatter.ForegroundCompositing',1}}
local bokehSaved=nil
local function bokehCmd(c) H:GetKismetSystemLibrary():ExecuteConsoleCommand(H:GetWorld(),c,H:GetPlayerController()) end
local function bokehSet(on)
 if on and not bokehSaved then
  local k=H:GetKismetSystemLibrary();bokehSaved={quality=k:GetConsoleVariableIntValue('r.DepthOfFieldQuality')}
  for _,c in ipairs(BOKEH_CVARS) do bokehSaved[c[1]]=k:GetConsoleVariableIntValue(c[1]);bokehCmd(c[1]..' '..c[2]) end
  -- Highlight scattering needs at least the standard DOF quality.
  if bokehSaved.quality<2 then bokehCmd('r.DepthOfFieldQuality 2') end
 elseif not on and bokehSaved then
  for _,c in ipairs(BOKEH_CVARS) do bokehCmd(c[1]..' '..tostring(bokehSaved[c[1]])) end
  bokehCmd('r.DepthOfFieldQuality '..tostring(bokehSaved.quality));bokehSaved=nil
 end
end
local function bokehShape(pp,old,on)
 if on then
  if old.blades==nil then old.blades={pp.DepthOfFieldBladeCount,pp.bOverride_DepthOfFieldBladeCount,pp.DepthOfFieldMinFstop,pp.bOverride_DepthOfFieldMinFstop} end
  pp.bOverride_DepthOfFieldBladeCount=true;pp.DepthOfFieldBladeCount=(tonumber(S.bokehBlades)==8 and 8 or BOKEH_BLADES)
  pp.bOverride_DepthOfFieldMinFstop=true;pp.DepthOfFieldMinFstop=0 -- straight blades: a crisp hexagon
 elseif old.blades then
  pp.DepthOfFieldBladeCount=old.blades[1];pp.bOverride_DepthOfFieldBladeCount=old.blades[2];pp.DepthOfFieldMinFstop=old.blades[3];pp.bOverride_DepthOfFieldMinFstop=old.blades[4];old.blades=nil
 end
end
-- ===== end bokeh =====
-- ===== Glow softness (v4.1.0) =====
-- Free camera only: wider/stronger bloom around emissive toys (lava lamps) + max bloom quality. 0 = as in the game.
local glowSaved=nil
local glowBase=nil
local function glowWorldBase()
 local base={intensity=0.675,size=4,method=0}
 for _,v in ipairs(FindAllOf('PostProcessVolume') or {}) do
  if v:IsValid() and v.bUnbound and v.bEnabled then local s=v.Settings
   if s.bOverride_BloomIntensity then base.intensity=s.BloomIntensity end
   if s.bOverride_BloomSizeScale then base.size=s.BloomSizeScale end
   if s.bOverride_BloomMethod then base.method=s.BloomMethod end
  end
 end
 return base
end
local function glowApply(cam,off)
 if not cam or not cam:IsValid() then return end
 local g=(not off) and math.max(0,math.min(3,tonumber(S.glow) or 0)) or 0
 local pp=cam.PostProcessSettings
 if g>0 then
  if not glowBase then local ok,b=pcall(glowWorldBase);glowBase=ok and b or {intensity=0.675,size=4,method=0};S.bloomInfo=glowBase end
  if not glowSaved then glowSaved={quality=H:GetKismetSystemLibrary():GetConsoleVariableIntValue('r.BloomQuality')};bokehCmd('r.BloomQuality 5') end
  pp.bOverride_BloomIntensity=true;pp.BloomIntensity=glowBase.intensity*(1+0.35*g)
  pp.bOverride_BloomSizeScale=true;pp.BloomSizeScale=glowBase.size*(1+0.5*g)
 else
  if pp.bOverride_BloomIntensity then pp.bOverride_BloomIntensity=false end
  if pp.bOverride_BloomSizeScale then pp.bOverride_BloomSizeScale=false end
  if glowSaved then bokehCmd('r.BloomQuality '..tostring(glowSaved.quality));glowSaved=nil end
 end
end
-- ===== end glow =====
local function optics(cam,enabled)
 if not cam or not cam:IsValid() then return end
 glowApply(cam)
 local pp=cam.PostProcessSettings; local addr=cam:GetAddress();local old=opticsOriginal[addr]
 if enabled then
  if not old then old={camera=cam,weight=cam.PostProcessBlendWeight,quality=H:GetKismetSystemLibrary():GetConsoleVariableIntValue('r.DepthOfFieldQuality')};for _,k in ipairs(opticsFields) do old[k]=pp[k];old["bOverride_"..k]=pp["bOverride_"..k] end;opticsOriginal[addr]=old;if S.presetEnabled and tonumber(S.dofQuality) then H:GetKismetSystemLibrary():ExecuteConsoleCommand(H:GetWorld(),'r.DepthOfFieldQuality '..math.floor(tonumber(S.dofQuality)),H:GetPlayerController()) end end
  for _,k in ipairs(opticsFields) do pp["bOverride_"..k]=true end
  pp.DepthOfFieldFocalDistance=S.focusDistance*100;pp.DepthOfFieldFstop=math.max(0.8,16/(1+S.lensBlur*1.9));pp.DepthOfFieldScale=1;pp.DepthOfFieldSensorWidth=36;cam.PostProcessBlendWeight=1
  bokehShape(pp,old,S.bokeh==true);bokehSet(S.bokeh==true)
 elseif old then
  bokehShape(pp,old,false);bokehSet(false)
  for _,k in ipairs(opticsFields) do pp[k]=old[k];pp["bOverride_"..k]=old["bOverride_"..k] end;cam.PostProcessBlendWeight=old.weight;opticsOriginal[addr]=nil;H:GetKismetSystemLibrary():ExecuteConsoleCommand(H:GetWorld(),'r.DepthOfFieldQuality '..old.quality,H:GetPlayerController())
 end
end
local input=nil
local lastseq=-1
local initialRequest=read(BRIDGE..'request.json')
local lastrequest=initialRequest and initialRequest.id or ''
local cooldowns={}
local originalHands={}
local pendingPose=nil
local capturePause=nil
local testInput=nil
local cachedController=nil
H.GetPlayerController=function()
 if cachedController and cachedController:IsValid() and cachedController:IsLocalPlayerController() then return cachedController end
 local all=FindAllOf('TS_PlayerController') or FindAllOf('PlayerController') or {}
 for _,pc in ipairs(all) do if pc:IsValid() and pc:IsLocalPlayerController() then cachedController=pc; return pc end end
 return CreateInvalidObject()
end
local function valid(o) return o and o:IsValid() end
local function message(e)return tostring(e):gsub('^[^\r\n]*%.lua:%d+:%s*','')end
local function vec(v) return {X=v.X,Y=v.Y,Z=v.Z} end
local function rot(v) return {Pitch=v.Pitch,Yaw=v.Yaw,Roll=v.Roll} end
local function clamp(v,a,b) return math.min(b,math.max(a,v)) end
local function console(cmd)
 H:GetKismetSystemLibrary():ExecuteConsoleCommand(H:GetWorld(),cmd,H:GetPlayerController())
end
local function setfov(value)
 if lastFov~=value then console("fov "..value);lastFov=value end
end
local function actor()
 local p=H:GetPlayer(); assert(valid(p) and p:IsA('/Script/MyToyStore.TS_Character'),'Откройте игровой уровень.')
 return p,H:GetPlayerController()
end
local function authority()
 local p,pc=actor(); assert(p:HasAuthority(),'Это действие выполняется у хоста. Камера доступна и на клиенте.'); return p,pc
end
local function worldinfo()
 local w=H:GetWorld()
 if not valid(w) then return end
 S.world=w:GetFName():ToString()
 local paths=StaticFindObject('/Script/Engine.Default__BlueprintPathsLibrary')
 if valid(paths) then S.savedDir=paths:ProjectSavedDir():ToString() end
 local gs=H:GetGameStateBase()
 S.ready=valid(gs) and gs:IsA('/Script/MyToyStore.TS_GameState') and gs.bItemsInitialized
 S.mode=S.ready and gs.GameModeType or 0
 if S.ready then S.money=gs.Money; S.totalItems=gs.TotalItems; S.placedItems=gs.CorrectlyPlaced else S.money=nil end
 local p=H:GetPlayer()
 S.authority=valid(p) and p:HasAuthority() or false
 if valid(p) and p:IsA('/Script/MyToyStore.TS_Character') then
  S.cameraReady=valid(p.FirstPersonCamera)
  S.position=vec(p:K2_GetActorLocation()); S.rotation=rot(H:GetPlayerController():GetControlRotation())
  S.held=p.Interaction:GetHeldCount(); S.maxHands=p.Interaction:GetMaxStackSize()
 else S.held=0; S.maxHands=0;S.cameraReady=false end
 S.time=os.time();S.focalLength=18/math.tan(math.rad(S.fov/2))
 local pc=H:GetPlayerController();if valid(pc) and valid(pc.PlayerCameraManager) then S.actualFov=pc.PlayerCameraManager:GetFOVAngle() end
 S.paused=H:GetGameplayStatics():IsGamePaused(w)
 if C and valid(C.camera) then S.cameraPosition=vec(C.camera:K2_GetComponentLocation());S.cameraRotation=rot(C.camera:K2_GetComponentRotation()) else S.cameraPosition=nil;S.cameraRotation=nil end
end
local function observerMeshes()
 if not C or not valid(C.pawn) then return end
 local function patch(m,fp)
  if not valid(m) then return end
  local addr=m:GetAddress()
  if not C.meshes[addr] then C.meshes[addr]={object=m,hidden=m.bHiddenInGame,noSee=m.bOwnerNoSee} end
  if fp then m:SetHiddenInGame(true,false) else m:SetOwnerNoSee(false) end
 end
 local p=C.pawn;patch(p.Mesh,false);patch(p.OwnerMesh,true);patch(p.HeldItemMesh,false);patch(p.OutgoingItemMesh,false);patch(p.HeldItemMeshFP,true);patch(p.OutgoingItemMeshFP,true)
 patch(p.Interaction.HoverProxy,true)
 for i=1,#p.ChildMeshes do patch(p.ChildMeshes[i],false) end
 for i=1,#p.HeldAdditionalMeshes do patch(p.HeldAdditionalMeshes[i],false) end
 for i=1,#p.HeldAdditionalMeshesFP do patch(p.HeldAdditionalMeshesFP[i],true) end
end
local function lockCameraControls()
 if not C or not valid(C.pc) or not valid(C.pawn) then return end
 C.pc:ResetIgnoreMoveInput();C.pc:ResetIgnoreLookInput();C.pc:SetIgnoreMoveInput(true);C.pc:SetIgnoreLookInput(true)
 C.pawn:DisableInput(C.pc);C.pc:DisableInput(C.pc)
end
local function stopcam()
 if replay and S.replay and S.replay.kind=='camera' and S.replay.state~='idle' then replay.stop(true) end
 if C then
  if valid(C.camera) then optics(C.camera,false);glowApply(C.camera,true) end
  for _,m in pairs(C.meshes) do if valid(m.object) then m.object:SetHiddenInGame(m.hidden,false);m.object:SetOwnerNoSee(m.noSee) end end
  if valid(C.pc) then
   C.pc.bShouldPerformFullTickWhenPaused=C.fullPaused
   C.pc:SetViewTargetWithBlend(valid(C.viewTarget) and C.viewTarget or C.pawn,0,0,0,false)
   C.pc:ResetIgnoreMoveInput();C.pc:ResetIgnoreLookInput()
   if not replay or not replay.ownsControls() then C.pc:EnableInput(C.pc);if valid(C.pawn) then C.pawn:EnableInput(C.pc) end end
   if valid(C.hud) then C.hud:SetVisibility(C.visibility) end
  end
  setfov(C.renderFov)
  if valid(C.actor) then C.actor:K2_DestroyActor() end
 end
 C=nil; S.freecam=false;if replay then replay.follow() end
end
local function startcam()
 if S.freecam then return end
 local p,pc=actor()
 local camActor=H:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.CameraActor'),vec(pc.PlayerCameraManager:GetCameraLocation()),rot(pc.PlayerCameraManager:GetCameraRotation()))
 assert(valid(camActor) and valid(camActor.CameraComponent),'Не удалось создать свободную камеру.')
 local cam=camActor.CameraComponent
 local hud=pc.HUDLayout
 C={actor=camActor,camera=cam,pawn=p,pc=pc,viewTarget=pc:GetViewTarget(),fullPaused=pc.bShouldPerformFullTickWhenPaused,meshes={},renderFov=pc.PlayerCameraManager:GetFOVAngle(),hud=hud,visibility=valid(hud) and hud:GetVisibility() or 0}
 C.pos=vec(pc.PlayerCameraManager:GetCameraLocation()); C.rotation=rot(pc.PlayerCameraManager:GetCameraRotation()); C.velocity={X=0,Y=0,Z=0}; C.targetRotation=rot(C.rotation)
 cam.bUsePawnControlRotation=false;cam.bConstrainAspectRatio=false
 camActor:SetActorEnableCollision(false)
 pc.bShouldPerformFullTickWhenPaused=true
 pc:SetViewTargetWithBlend(camActor,0,0,0,false)
 cam:K2_SetWorldLocationAndRotation(C.pos,C.rotation,false,{},true)
 lockCameraControls();observerMeshes()
 if valid(hud) then hud:SetVisibility(1) end
 cam:SetFieldOfView(S.fov);setfov(S.fov); S.freecam=true; S.tool=false
end
local function applyhands()
 local p=H:GetPlayer(); if not valid(p) or not p:IsA('/Script/MyToyStore.TS_Character') then return end
 local settings=p.Interaction.CharacterSettings
 if valid(settings) then
  local key=settings:GetAddress()
  if not originalHands[key] then originalHands[key]={object=settings,value=settings.DefaultInventorSize} end
  settings.DefaultInventorSize=S.hands>0 and S.hands or originalHands[key].value
 end
end
local function abilities()
 local p=H:GetPlayer(); if not valid(p) or not p:IsA('/Script/MyToyStore.TS_Character') then return end
 local asc=p.AbilitySystemComponent; if not valid(asc) then return end
 local specs=asc.ActivatableAbilities.Items
 local function patch(a)
  if not valid(a) or not a:IsA('/Script/MyToyStore.TS_BaseActiveAbility') then return end
  local class=a.CooldownGameplayEffectClass
  if not valid(class) then return end
  local effect=class:GetCDO();if not valid(effect) then return end
  local addr=effect:GetAddress(); local saved=cooldowns[addr]
  if S.noCooldown then
   if not saved then saved={object=effect,policy=effect.DurationPolicy}; cooldowns[addr]=saved end
   asc:RemoveActiveGameplayEffectBySourceEffect(class,asc,-1)
   effect.DurationPolicy=0
  elseif saved then effect.DurationPolicy=saved.policy; cooldowns[addr]=nil end
 end
 for k=1,#specs do patch(specs[k].Ability) end
 local instances=FindAllOf('TS_BaseActiveAbility') or {}
 for _,a in ipairs(instances) do patch(a) end
 if not S.noCooldown then
  for addr,old in pairs(cooldowns) do if valid(old.object) then old.object.DurationPolicy=old.policy end; cooldowns[addr]=nil end
 end
end
local tool=require("toytool").new({H=H,S=S,valid=valid,console=console,authority=authority,recordGrab=function(p,targets)if replay then replay.event(p,{type='bulkGrab',targets=targets}) end end,recordThrow=function(p)if replay then replay.event(p,{type='toolThrow',charge=1,clean=true}) end end,withoutRecording=function(f)if replay then return replay.withoutRecording(f) else return f() end end,recordNativePickup=function(p)if replay then replay.event(p,{type='press',input=1000});replay.event(p,{type='release',input=1000}) end end})
local grab,drop=tool.grab,tool.drop
local shelves=nil
local function restoreheld(m,p,pc)
 if not m.heldDefinitions or #m.heldDefinitions==0 then return end
 local current=p.Interaction.HeldStack
 if #current==#m.heldDefinitions then
  local counts={};for _,name in ipairs(m.heldDefinitions) do counts[name]=(counts[name] or 0)+1 end
  local same=true
  for k=1,#current do local name=current[k]:GetFullName();counts[name]=(counts[name] or 0)-1;if counts[name]<0 then same=false end end
  if same then return end
 end
 assert(#current==0,'Руки заняты при восстановлении снапшота.')
 local gs=H:GetGameStateBase(); local shards=gs.ItemManager.Shards; local needed={}
 for _,name in ipairs(m.heldDefinitions) do needed[name]=(needed[name] or 0)+1 end
 local selected={}; local count=0; local floor={}; local location=p:K2_GetActorLocation()
 for j=1,#shards do local a=shards[j].Entries.Items; for k=1,#a do local it=a[k]
  if not it.bIsShelfItem then floor[#floor+1]={id=it.ItemId,def=it.DefIndex,d=(it.Location.X-location.X)^2+(it.Location.Y-location.Y)^2+(it.Location.Z-location.Z)^2} end
 end end
 table.sort(floor,function(a,b)return a.d<b.d end)
 for _,it in ipairs(floor) do
  local def=gs:GetDefByIndex(it.def)
  local name=valid(def) and def:GetFullName() or ''
  if needed[name] and needed[name]>0 then selected[it.id]=true; needed[name]=needed[name]-1; count=count+1 end
 end
 assert(count==#m.heldDefinitions,'Не найдены все игрушки из рук снапшота. Сохранён резервный файл.')
 local masked={}
 for j=1,#shards do local a=shards[j].Entries.Items; for k=1,#a do local it=a[k]
  if not it.bIsShelfItem and not selected[it.ItemId] then masked[it.ItemId]=true; it.bIsShelfItem=true end
 end end
 local ok,e=pcall(function() console('TS.Items.Grab '..count) end)
 for j=1,#shards do local a=shards[j].Entries.Items; for k=1,#a do local it=a[k]; if masked[it.ItemId] then it.bIsShelfItem=false end end end
 if not ok then error(e) end
 assert(p.Interaction:GetHeldCount()==count,'Игра не восстановила игрушки в руках.')
end
local function restorepose(m)
 local p,pc=authority()
 local body=m.actorRotation or m.rotation
 p:K2_SetActorLocationAndRotation(m.position,{Pitch=0,Yaw=body.Yaw,Roll=0},false,{},true)
 pc:SetControlRotation(m.rotation)
 p:SampleSafeLocation()
 restoreheld(m,p,pc)
end
local function withTrack(p,pc,f)
 local originalPC=H:GetPlayerController();local originalPawn=originalPC.Pawn
 if p:GetAddress()==originalPawn:GetAddress() then return f(p,pc) end
 local originalPS=originalPC.PlayerState;local otherPS=pc.PlayerState;local control=rot(originalPC:GetControlRotation())
 pc:UnPossess();originalPC.PlayerState=otherPS;originalPC:Possess(p)
 local ok,e=pcall(function() return f(p,originalPC) end)
 originalPC:UnPossess();originalPC.PlayerState=originalPS;originalPC:Possess(originalPawn);originalPC:SetControlRotation(control)
 pc.PlayerState=otherPS;pc:Possess(p)
 pc:DisableInput(pc);p:DisableInput(pc)
 if C and valid(C.actor) then originalPC:SetViewTargetWithBlend(C.actor,0,0,0,false);lockCameraControls() end
 if S.replay and S.replay.state=='playing' then originalPC:DisableInput(originalPC);originalPawn:DisableInput(originalPC) end
 if not ok then error(e) end
 return e
end
local function restoreTrackHeld(defs,p,pc)
 if #defs==0 then return end
 return withTrack(p,pc,function(p,c)return restoreheld({heldDefinitions=defs},p,c)end)
end
replay=require('replay').new({H=H,S=S,valid=valid,json=json,ROOT=ROOT,authority=authority,stopcam=stopcam,startcam=startcam,lockCameraControls=lockCameraControls,restoreTrackHeld=restoreTrackHeld,throwForTrack=tool.dropOne,grabForTrack=function(targets,p,pc,legacy)return withTrack(p,pc,function()return tool.resolveTargets(targets,legacy)end)end,getCamera=function()return C end,setCamera=function(f)
 assert(C and valid(C.camera),'Свободная камера не найдена.')
 C.pos=f.p;C.rotation=f.r;C.targetRotation=rot(f.r);C.velocity={X=0,Y=0,Z=0};S.fov=f.fov;S.focusDistance=f.focusDistance or S.focusDistance;S.lensBlur=f.lensBlur or S.lensBlur
 C.camera:K2_SetWorldLocationAndRotation(C.pos,C.rotation,false,{},true);C.camera:SetFieldOfView(S.fov);setfov(S.fov);optics(C.camera,S.lensBlur>0)
end})
shelves=require('shelves').new({H=H,S=S,valid=valid,console=console,authority=authority,tool=tool,withTrack=withTrack,withoutRecording=function(f)if replay then return replay.withoutRecording(f)else return f()end end})
local function finishcapture()
 if capturePause then
  if valid(capturePause.world) and not capturePause.wasPaused then H:GetGameplayStatics():SetGamePaused(capturePause.world,false) end
  capturePause=nil
 end
end
local allowed={
 shelves='TS.Items.MoveToShelfs',clearShelves='TS.Items.ClearShelfs',flyShelves='TS.Items.FlyToShelfs',
 upgrades='TS.Upgrades.SetAllLevel',money='TS.Economy.SetMoney',randomize='TS.Character.Randomize',sky='TS.NextSkybox',
 skyGlitch='TS.SkyGlitch',resetMachine='TS.ScamMachine.ResetCooldown',screenMessages='DisableAllScreenMessages',
 enableMessages='EnableAllScreenMessages',fps='t.MaxFPS',renderScale='r.ScreenPercentage',motionBlur='r.MotionBlurQuality',
 depthOfField='r.DepthOfFieldQuality',timeScale='slomo',pause='pause'
}
-- ===== Graphics presets (v4.1.0) =====
-- Tuned from the benchmarks on the user's Mac (CrossOver/D3DMetal, 1080p, 60 FPS + VSync, target ~80 FPS uncapped).
-- Main cost in wide shots over toy piles: every small toy drawn into the shadow maps. r.Shadow.RadiusThreshold drops
-- small casters from shadows (0.03 game default; 0.06 small toys; 0.12 small and medium) at shadow quality 2.
-- DLSS goes through MetalFX in a bottle with D3DM_ENABLE_METALFX=1; elsewhere it falls back to TAA upsampling.
-- Disabled: the mod leaves the game's own graphics settings alone (and restores them if a preset was applied).
local PRESET_CVARS={{'sg.ViewDistanceQuality','vd'},{'sg.ShadowQuality','shadow'},{'sg.GlobalIlluminationQuality','gi'},{'sg.ReflectionQuality','refl'},
 {'sg.EffectsQuality','fx'},{'sg.ShadingQuality','shading'},{'sg.PostProcessQuality','pp'},{'sg.TextureQuality','tex'},{'sg.AntiAliasingQuality','aa'},{'r.AntiAliasingMethod','aaMethod'},
 {'r.Shadow.RadiusThreshold','shadowRadius',true},{'r.NGX.DLSS.Enable','dlss'}}
local presets={
 {id='close',name='Крупный план и детали',desc='Максимум детализации и мягкое размытие фона. Тени теряют только самые мелкие игрушки: вблизи тени мелочи заметны.',
  values={vd=2,shadow=2,gi=2,refl=2,fx=2,shading=2,pp=2,tex=3,aa=2,aaMethod=2,shadowRadius=0.06,dlss=1,screen=75,dof=2}},
 {id='medium',name='Средний план',desc='Баланс детализации и дальности. Мелкие и средние игрушки без теней — главный выигрыш в кадрах над кучами.',
  values={vd=2,shadow=2,gi=2,refl=2,fx=2,shading=2,pp=2,tex=3,aa=2,aaMethod=2,shadowRadius=0.12,dlss=1,screen=67,dof=2}},
 {id='far',name='Дальний план',desc='Максимальная дальность прогрузки. Мелкие и средние игрушки без теней, DLSS восстанавливает чёткость из 67%.',
  values={vd=3,shadow=2,gi=2,refl=2,fx=2,shading=2,pp=2,tex=3,aa=2,aaMethod=2,shadowRadius=0.12,dlss=1,screen=67,dof=1}},
}
local presetOriginal=nil
local function presetById(id) for _,p in ipairs(presets) do if p.id==id then return p end end end
local function presetSet(p)
 local set={};for _,c in ipairs(PRESET_CVARS) do set[c[1]]=p.values[c[2]] end
 set['r.ScreenPercentage']=p.values.screen;set['r.DepthOfFieldQuality']=p.values.dof;return set
end
local function captureGame()
 local k=H:GetKismetSystemLibrary();local o={}
 for _,c in ipairs(PRESET_CVARS) do
  if c[3] then o[c[1]]=math.floor(k:GetConsoleVariableFloatValue(c[1])*1000+.5)/1000 else o[c[1]]=k:GetConsoleVariableIntValue(c[1]) end
 end
 o['r.ScreenPercentage']=math.floor(k:GetConsoleVariableFloatValue('r.ScreenPercentage')+.5)
 o['r.DepthOfFieldQuality']=k:GetConsoleVariableIntValue('r.DepthOfFieldQuality')
 return o
end
local function applyCvars(set)
 for _,c in ipairs(PRESET_CVARS) do if set[c[1]]~=nil then console(c[1]..' '..tostring(set[c[1]])) end end
 if set['r.DepthOfFieldQuality']~=nil then console('r.DepthOfFieldQuality '..tostring(set['r.DepthOfFieldQuality'])) end
 if set['r.ScreenPercentage']~=nil then
  if set['r.ScreenPercentage']<100 then console('r.TemporalAA.Upsampling 1') end
  console('r.ScreenPercentage '..tostring(set['r.ScreenPercentage']))
 end
end
local function publishGameSettings()
 local o=presetOriginal or captureGame();local v={}
 for _,c in ipairs(PRESET_CVARS) do v[c[2]]=o[c[1]] end
 v.screen=o['r.ScreenPercentage'];v.dof=o['r.DepthOfFieldQuality']
 S.gameSettings=v
end
S.presets={};for _,p in ipairs(presets) do table.insert(S.presets,{id=p.id,name=p.name,desc=p.desc,values=p.values}) end
-- ===== end presets =====
-- ===== Performance benchmark (v4.1.0) =====
-- Moving benchmark: the free camera repeats the same slow sideways pass for every variant,
-- starting from the pose where the user placed it. Each variant changes one thing relative to the current settings.
-- Unless a variant is marked "production", the FPS cap and VSync are lifted to measure headroom.
local appliedFrameCap=nil
local B=nil
-- Suite «Итоговые пресеты» (v4.1.0): current settings, then every preset without the cap (headroom, target ~80)
-- and as in production (60 + VSync). Results are written after every run.
local benchVariants={{id='base',name='Текущие настройки'}}
for _,p in ipairs(presets) do table.insert(benchVariants,{id=p.id,name='Пресет «'..p.name..'»',set=presetSet(p)}) end
for _,p in ipairs(presets) do table.insert(benchVariants,{id=p.id..'60',name='Пресет «'..p.name..'», как на съёмке (60 + VSync)',production=true,set=presetSet(p)}) end
local BENCH_FLOAT_CVARS={['r.ScreenPercentage']=true,['r.Shadow.RadiusThreshold']=true}
local benchCvars={'sg.ViewDistanceQuality','sg.ShadowQuality','sg.GlobalIlluminationQuality','sg.ReflectionQuality','sg.EffectsQuality','sg.ShadingQuality','sg.PostProcessQuality','sg.TextureQuality','sg.AntiAliasingQuality','r.AntiAliasingMethod','r.DepthOfFieldQuality','r.DOF.Gather.EnableBokehSettings','r.DOF.Scatter.EnableBokehSettings','r.DOF.Recombine.EnableBokehSettings','r.DOF.Scatter.BackgroundCompositing','r.DOF.Scatter.ForegroundCompositing',
 'r.Shadow.RadiusThreshold','r.NGX.DLSS.Enable','r.ScreenPercentage'}
local BENCH_WARMUP,BENCH_MEASURE=4,12
-- Strafe right at the free camera's minimum speed (20 units/s, the same clamp as the speed setting); no pan or tilt.
local PATH={kind='strafe-right',speed=20}
local function benchNow() return H:GetGameplayStatics():GetRealTimeSeconds(H:GetWorld()) end
local function benchApply(v)
 local set=v and v.set
 for _,name in ipairs(benchCvars) do if name~='r.ScreenPercentage' then console(name..' '..tostring(B.original[name])) end end
 if set then for name,value in pairs(set) do if name~='r.ScreenPercentage' then console(name..' '..tostring(value)) end end end
 if v and v.production then console('t.MaxFPS 60');console('r.VSync 1') elseif v then console('t.MaxFPS 0');console('r.VSync 0') end
 -- Scalability changes may touch the render scale; always pin it last.
 console('r.ScreenPercentage '..tostring(set and set['r.ScreenPercentage'] or B.original['r.ScreenPercentage']))
end
local function benchPose(t)
 if not C or not B.pose then return end
 local p=B.pose
 local ry=math.rad(p.yaw);local rx,rgt=-math.sin(ry),math.cos(ry)
 local s=PATH.speed*t
 C.pos.X=p.X+rx*s;C.pos.Y=p.Y+rgt*s;C.pos.Z=p.Z
 C.rotation.Yaw=p.yaw;C.rotation.Pitch=p.pitch;C.targetRotation.Yaw=p.yaw;C.targetRotation.Pitch=p.pitch
 C.velocity.X=0;C.velocity.Y=0;C.velocity.Z=0
end
local benchNext
local function benchFinish(state)
 if not B then return end
 local ok=pcall(benchApply,nil)
 if bokehSaved then for _,c in ipairs(BOKEH_CVARS) do console(c[1]..' '..c[2]) end end -- bokeh switch still on
 pcall(benchPose,0)
 local file=B.file
 write(ROOT..'/'..file,{suite='presets-final',state=state,mode='moving',path=PATH,started=B.started,finished=os.time(),world=S.world,freecam=S.freecam,startPose=B.pose,bokehSwitch=S.bokeh,bokehOffBaseline=B.bokehOffBaseline,fov=S.fov,lensBlur=S.lensBlur,dofQuality=S.dofQuality,baseline=B.original,restored=ok,warmup=BENCH_WARMUP,measure=BENCH_MEASURE,results=B.results})
 S.bench={state=state,file=file,results=B.results}
 B=nil;appliedFrameCap=nil -- framePacing re-applies FPS cap, VSync and render scale
end
benchNext=function()
 B.index=B.index+1
 local v=benchVariants[B.index]
 if not v then benchFinish('done');return end
 benchApply(v);B.phaseStart=benchNow();B.last=nil;B.samples={}
 S.bench={state='running',step=B.index,total=#benchVariants,name=v.name}
end
local function benchStep()
 local now=benchNow()
 if not (S.freecam and C) then benchFinish('aborted');return end
 benchPose(now-B.phaseStart)
 if B.last and now-B.phaseStart>=BENCH_WARMUP then table.insert(B.samples,now-B.last) end
 B.last=now
 if now-B.phaseStart<BENCH_WARMUP+BENCH_MEASURE then return end
 local s=B.samples;local n=#s;local sum=0;local miss=0;local hitch=0
 for _,dt in ipairs(s) do sum=sum+dt; if dt>1/58 then miss=miss+1 end; if dt>1/30 then hitch=hitch+1 end end
 local sorted={};for i,dt in ipairs(s) do sorted[i]=dt end;table.sort(sorted)
 local function pct(p) return n>0 and sorted[math.max(1,math.ceil(p*n))] or 0 end
 local v=benchVariants[B.index]
 table.insert(B.results,{id=v.id,name=v.name,production=v.production or false,frames=n,avgFps=n>0 and math.floor(n/sum*10+.5)/10 or 0,
  medianMs=math.floor(pct(.5)*10000+.5)/10,p99Ms=math.floor(pct(.99)*10000+.5)/10,maxMs=math.floor(pct(1)*10000+.5)/10,low1Fps=n>0 and math.floor(1/pct(.99)*10+.5)/10 or 0,
  missed60=n>0 and math.floor(miss/n*1000+.5)/10 or 0,hitches=hitch})
 pcall(write,ROOT..'/'..B.file,{suite='presets-final',state='running',started=B.started,world=S.world,startPose=B.pose,fov=S.fov,lensBlur=S.lensBlur,bokehSwitch=S.bokeh,baseline=B.original,results=B.results})
 benchNext()
end
local function benchStart()
 if B then benchFinish('aborted');return {bench='aborted'} end
 assert(S.ready,'Откройте игровой уровень и дождитесь загрузки игрушек.')
 assert(S.freecam and C,'Включите свободную камеру и поставьте её в начальную точку пролёта.')
 local k=H:GetKismetSystemLibrary();local original={}
 for _,name in ipairs(benchCvars) do
  if name=='r.ScreenPercentage' then original[name]=math.floor(k:GetConsoleVariableFloatValue(name)+.5)
  elseif BENCH_FLOAT_CVARS[name] then original[name]=math.floor(k:GetConsoleVariableFloatValue(name)*1000+.5)/1000
  else original[name]=k:GetConsoleVariableIntValue(name) end
 end
 -- With the bokeh switch on, measure every variant without bokeh except the explicit "+ боке" ones.
 local bokehOffBaseline=bokehSaved~=nil
 if bokehOffBaseline then for _,c in ipairs(BOKEH_CVARS) do original[c[1]]=bokehSaved[c[1]] end end
 B={file='bench-'..os.date('%Y%m%d-%H%M%S')..'.json',bokehOffBaseline=bokehOffBaseline,original=original,index=0,results={},started=os.time(),pose={X=C.pos.X,Y=C.pos.Y,Z=C.pos.Z,yaw=C.targetRotation.Yaw,pitch=C.targetRotation.Pitch}}
 benchNext()
 return {bench='started',total=#benchVariants}
end
-- ===== end benchmark =====
local function command(r)
 if shelves.busy() then assert(r.action=='shot' or r.action=='camera' or r.action=='testInput','Дождитесь завершения операции с полками.')end
 if r.action:match('^replay') then return replay.command(r) end
 if r.action=='shot' then console('Shot');worldinfo();return {savedDir=S.savedDir} end
 if r.action=='camera' then if r.enabled then startcam() else stopcam() end; return {freecam=S.freecam}
 elseif r.action=='settings' then
  if r.presetEnabled~=nil then S.presetEnabled=r.presetEnabled==true end
  if r.bokeh~=nil then S.bokeh=r.bokeh==true; if S.bokeh and (tonumber(S.bokehBlades) or 0)==0 then S.bokehBlades=6 elseif not S.bokeh then S.bokehBlades=0 end end
  if r.bokehBlades~=nil then local b=tonumber(r.bokehBlades) or 0; S.bokehBlades=(b>=8 and 8) or (b>=6 and 6) or 0; S.bokeh=S.bokehBlades>0 end
  if r.glow~=nil then S.glow=math.max(0,math.min(3,math.floor(tonumber(r.glow) or 0))) end
  if r.preset~=nil and presetById(r.preset) then S.preset=r.preset end
  for k,limits in pairs({speed={20,20000},fov={20,150},sensitivity={0.01,2},smoothing={0,2},rotationSmoothing={0,2},focusDistance={0.1,50},lensBlur={0,10},batch={10,200},hands={-1,10000}}) do
   if r[k]~=nil then S[k]=clamp(tonumber(r[k]) or S[k],limits[1],limits[2]); if k=='batch' or k=='hands' then S[k]=math.floor(S[k]) end end
  end
  if r.focalLength~=nil then S.fov=clamp(math.deg(2*math.atan(18/clamp(tonumber(r.focalLength) or 18,5,200))),20,150) end
  if r.noCooldown~=nil then S.noCooldown=r.noCooldown and true or false end
  if r.tool~=nil then S.tool=r.tool and true or false; if S.tool then stopcam() end end
  if r.fov or r.focalLength then setfov(S.fov);if not S.freecam and S.cameraReady then local p=actor(); p.FirstPersonCamera:SetFieldOfView(S.fov) end end
  applyhands(); abilities(); return {}
 elseif r.action=='shelf' then return shelves.start(r)
 elseif r.action=='grab' then return grab()
 elseif r.action=='drop' then return drop()
 elseif r.action=='cheat' then
  if r.name=='shelves' or r.name=='clearShelves'then return shelves.start({kind=r.name=='shelves'and'fill'or'clear',count=r.value==nil and -1 or r.value,id=r.id})end
  if r.name=='bench' then return benchStart() end
  local cmd=allowed[r.name]; assert(cmd,'Неизвестная команда.')
  if r.name~='sky' and r.name~='randomize' and r.name~='fps' and r.name~='renderScale' and r.name~='motionBlur' and r.name~='depthOfField' and r.name~='screenMessages' and r.name~='enableMessages' then authority() end
  if r.value~=nil then cmd=cmd..' '..tostring(clamp(tonumber(r.value) or 0,-1,10000000)) end
  -- Keep the panel's FPS / render scale / DOF choices as the persistent recording settings.
  local v=tonumber(r.value)
  if v and r.name=='fps' then S.maxFps=math.max(0,math.floor(v)) end
  console(cmd); return {command=cmd}
 elseif r.action=='snapshot' then
  local p,pc=authority(); assert(S.ready,'Дождитесь появления всех игрушек.')
  finishcapture()
  local w=H:GetWorld(); local statics=H:GetGameplayStatics()
  capturePause={world=w,wasPaused=statics:IsGamePaused(w),deadline=os.time()+40}
  if not capturePause.wasPaused then statics:SetGamePaused(w,true) end
  worldinfo()
  StaticFindObject('/Script/MyToyStore.Default__TS_GameHelper'):SaveGame(pc)
  console('Shot')
  local defs={}; local stack=p.Interaction.HeldStack
  for k=1,#stack do defs[#defs+1]=stack[k]:GetFullName() end
  return {position=vec(p:K2_GetActorLocation()),rotation=rot(pc:GetControlRotation()),actorRotation=rot(p:K2_GetActorRotation()),world=S.world,mode=S.mode,savedDir=S.savedDir,held=p.Interaction:GetHeldCount(),heldDefinitions=defs,money=S.money,totalItems=S.totalItems,placedItems=S.placedItems}
 elseif r.action=='finishSnapshot' then finishcapture(); return {}
 elseif r.action=='menu' then
  authority(); stopcam(); S.tool=false
  local settings=StaticFindObject('/Script/MyToyStore.Default__TS_ToyStoreSettings')
  local menu=settings.MainMenuLevelName:ToString()
  StaticFindObject('/Script/MyToyStore.Default__TS_GameHelper'):LeaveSessionAndTravel(H:GetPlayerController(),menu)
  return {menu=menu}
 elseif r.action=='reload' then
  authority(); stopcam(); S.tool=false
  pendingPose=r.position and r or nil
  console('TS.LoadGame'); return {loading=true}
 elseif r.action=='start' then
  local gi=H:GetGameInstance(); gi:SetSelectedGameModeType(r.mode or 0); gi:StartGame(FName(r.world))
  pendingPose=r.position and r or nil; return {loading=true}
 elseif r.action=='pose' then restorepose(r); return {}
 elseif r.action=='quit' then replay.stop(true);stopcam(); console('quit'); return {}
 elseif config.test and r.action=='joinTestHost' then stopcam(); console('open 127.0.0.1'); return {loading=true}
 elseif config.test and r.action=='testListen' then
  H:GetGameplayStatics():OpenLevel(H:GetWorld(),FName('/Game/Level/L_ToyKingdom'),true,'listen'); return {loading=true}
 elseif config.test and r.action=='testNet' then
  local w=H:GetWorld();local n=w.NetDriver
  return {driver=valid(n) and n:GetClass():GetFName():ToString() or 'none',connection=valid(n) and valid(n.ServerConnection) or false}
 elseif config.test and r.action=='testInput' then testInput=r.input; if testInput then testInput.time=os.time(); testInput.deadline=os.time()+4 end; return {}
 elseif config.test and r.action=='testAbility' then
  local p=authority(); local asc=p.AbilitySystemComponent
  local specs=asc.ActivatableAbilities.Items
  local result={}
  local first,second=nil,nil
  for k=1,#specs do local a=specs[k].Ability
   if valid(a) and a:IsA('/Script/MyToyStore.TS_BaseActiveAbility') then
    local class=a.CooldownGameplayEffectClass
    result[#result+1]={name=a:GetClass():GetFName():ToString(),cooldownClass=valid(class),policy=valid(class) and class:GetCDO().DurationPolicy or -1}
   end
   if not r.checkOnly and valid(a) and a:IsA('/Script/MyToyStore.TS_GrabGrenadeAbility') then
    first=asc:TryActivateAbilityByClass(a:GetClass(),true)
    if r.count~=1 then second=asc:TryActivateAbilityByClass(a:GetClass(),true) end
   end
  end
  return {abilities=result,first=first,second=second}
 end
 error('Неизвестное действие.')
end
local cachedpc=nil
local previousTime=nil
local previousButtons={}
local previousMouse={dx=0,dy=0,wheel=0}
local previousCameraToggle=nil
local previousHotkeys={}
local previousSession=nil
local previousPadCombo=false
local function frame()
 if capturePause and os.time()>capturePause.deadline then finishcapture() end
 if testInput and os.time()<=testInput.deadline then input=testInput else testInput=nil end
 local now=H:GetGameplayStatics():GetRealTimeSeconds(H:GetWorld())
 if capturePause then previousTime=now; return end
 tool.update(now)
 shelves.update(now)
 local dt=previousTime and clamp(now-previousTime,0,0.25) or 0
 previousTime=now
 if C and (not valid(C.camera) or not valid(C.pawn) or H:GetPlayerController()~=C.pc) then stopcam() end
 if input and input.session and input.session~=previousSession then previousSession=input.session;previousMouse={dx=input.dx,dy=input.dy,wheel=input.wheel};previousCameraToggle=input.cameraToggle;previousHotkeys={tool=input.toolToggle,record=input.recordToggle,play=input.playToggle,stop=input.stopToggle} end
 local fresh=input and input.seq~=lastseq
 if fresh then lastseq=input.seq end
 local focused=input and input.focused and os.time()-input.time<2
 local toggle=input and input.cameraToggle or 0
 if previousCameraToggle==nil then previousCameraToggle=toggle end
 if fresh and toggle~=previousCameraToggle then
  previousCameraToggle=toggle
  if focused and S.cameraReady then if S.freecam then stopcam() else startcam() end end
 end
 -- Gamepad: Back(View)+Y toggles the free camera.
 local pad=focused and type(input.pad)=='table' and input.pad or nil
 local padButtons=pad and math.floor(tonumber(pad.buttons) or 0) or 0
 local function padBit(v,b) return math.floor(v/b)%2==1 end
 local combo=padBit(padButtons,0x20) and padBit(padButtons,0x8000)
 if combo and not previousPadCombo and S.cameraReady then if S.freecam then stopcam() else startcam() end end
 previousPadCombo=combo
 if focused and fresh then
  for key,field in pairs({tool='toolToggle',record='recordToggle',play='playToggle',stop='stopToggle'}) do
   local value=input[field] or 0
   if previousHotkeys[key]~=nil and value~=previousHotkeys[key] and S.cameraReady then
    if key=='tool' then authority();S.tool=not S.tool;if S.tool then stopcam() end
    elseif key=='record' then replay.toggleRecord()
    elseif key=='play' then replay.togglePlay()
    elseif key=='stop' then replay.stop(true) end
   end
   previousHotkeys[key]=value
  end
 end
 local keys=focused and input.keys or {}
 local dx,dy,wheel=0,0,0
 if fresh then
  dx=input.dx-previousMouse.dx; dy=input.dy-previousMouse.dy; wheel=input.wheel-previousMouse.wheel
  previousMouse={dx=input.dx,dy=input.dy,wheel=input.wheel}
 end
 if S.freecam and C and not replay.isCameraPlayback() then
  if focused and fresh then
   C.targetRotation.Yaw=C.targetRotation.Yaw+dx*S.sensitivity
   C.targetRotation.Pitch=clamp(C.targetRotation.Pitch-dy*S.sensitivity,-89.9,89.9)
   if wheel~=0 then
    if keys.alt then S.fov=clamp(S.fov+wheel*2,20,150)
    elseif keys.ctrl then S.focusDistance=clamp(S.focusDistance*1.12^wheel,.1,50)
    elseif keys.shift then S.lensBlur=clamp(S.lensBlur+wheel*.25,0,10)
    else S.speed=clamp(S.speed*1.12^wheel,20,20000) end
   end
  end
  local ra=S.rotationSmoothing==0 and 1 or 1-math.exp(-dt/S.rotationSmoothing)
  C.rotation.Yaw=C.rotation.Yaw+(C.targetRotation.Yaw-C.rotation.Yaw)*ra
  C.rotation.Pitch=C.rotation.Pitch+(C.targetRotation.Pitch-C.rotation.Pitch)*ra
  local pitch=math.rad(C.rotation.Pitch); local yaw=math.rad(C.rotation.Yaw)
  local fw=(keys.w and 1 or 0)-(keys.s and 1 or 0); local right=(keys.d and 1 or 0)-(keys.a and 1 or 0); local up=(keys.e and 1 or 0)-(keys.q and 1 or 0)
  local padBoost=false
  if pad and not combo then
   -- Left stick: fly, right stick: look, RT/LT: up/down, LB/RB: speed, L3: x5 boost, D-pad up/down: FOV.
   local function n(v) return tonumber(v) or 0 end
   fw=clamp(fw+n(pad.ly),-1,1); right=clamp(right+n(pad.lx),-1,1); up=clamp(up+n(pad.rt)-n(pad.lt),-1,1)
   local look=160*(S.sensitivity/0.12)
   C.targetRotation.Yaw=C.targetRotation.Yaw+n(pad.rx)*look*dt
   C.targetRotation.Pitch=clamp(C.targetRotation.Pitch+n(pad.ry)*look*dt,-89.9,89.9)
   local spd=(padBit(padButtons,0x200) and 1 or 0)-(padBit(padButtons,0x100) and 1 or 0)
   if spd~=0 then S.speed=clamp(S.speed*2^(spd*dt*1.5),20,20000) end
   local zoom=(padBit(padButtons,0x2) and 1 or 0)-(padBit(padButtons,0x1) and 1 or 0)
   if zoom~=0 then S.fov=clamp(S.fov+zoom*40*dt,20,150) end
   padBoost=padBit(padButtons,0x40)
  end
  local x=math.cos(pitch)*math.cos(yaw)*fw-math.sin(yaw)*right
  local y=math.cos(pitch)*math.sin(yaw)*fw+math.cos(yaw)*right
  local z=math.sin(pitch)*fw+up; local n=math.sqrt(x*x+y*y+z*z)
  local speed=S.speed*((keys.shift or padBoost) and 5 or 1); if n>1 then x=x/n;y=y/n;z=z/n end
  local alpha=S.smoothing==0 and 1 or 1-math.exp(-dt/S.smoothing)
  for axis,v in pairs({X=x,Y=y,Z=z}) do
   if not focused then C.velocity[axis]=0 else C.velocity[axis]=C.velocity[axis]+(v*speed-C.velocity[axis])*alpha end
   C.pos[axis]=C.pos[axis]+C.velocity[axis]*dt
  end
  C.camera:K2_SetWorldLocationAndRotation(C.pos,C.rotation,false,{},true)
  C.camera:SetFieldOfView(S.fov);setfov(S.fov);optics(C.camera,S.lensBlur>0)
 elseif S.tool and not shelves.busy() and focused and fresh then
  if wheel~=0 then S.batch=math.floor(clamp(S.batch+wheel*10,10,200)) end
  if keys.lmb and not previousButtons.lmb then grab() end
  if keys.rmb and not previousButtons.rmb then drop() end
 end
 previousButtons={lmb=keys.lmb,rmb=keys.rmb}
 if C then observerMeshes() end
end
local function safe(f)
 local ok,e=pcall(f); if not ok then S.error=message(e); print('[Toybox] '..tostring(e)..'\n') end
end
RegisterKeyBind(Key.P,{ModifierKey.CONTROL},function()
 if not (input and input.focused and os.time()-input.time<2 and S.cameraReady) then return end
 ExecuteInGameThread(function() safe(function() if S.freecam then stopcam() else startcam() end end) end)
end)
RegisterLoadMapPreHook(function() safe(function()benchFinish('aborted')end); safe(finishcapture); safe(stopcam);safe(function()shelves.cancel(true)end);safe(function()replay.stop(true)end); tool.cancel();cachedController=nil;lastFov=nil; S.ready=false; S.travel=(S.travel or 0)+1; previousTime=nil end)
local waiting=false
local ticks=0
local pendingRequest=nil
local lastStateWrite=0
-- Recording-friendly frame pacing: cap FPS and enable VSync once per level (0 disables).
local function framePacing()
 local cap=math.floor(tonumber(S.maxFps) or 0)
 local key=table.concat({cap,S.presetEnabled and tostring(S.preset) or 'off',tostring(S.travel)},'@')
 if appliedFrameCap==key or not S.ready then return end
 appliedFrameCap=key
 if cap>0 then console('t.MaxFPS '..cap);console('r.VSync 1') else console('t.MaxFPS 0') end
 local p=S.presetEnabled and presetById(S.preset)
 if p then
  if not presetOriginal then presetOriginal=captureGame() end
  S.dofQuality=p.values.dof
  local set=presetSet(p); if not next(opticsOriginal) then set['r.DepthOfFieldQuality']=nil elseif bokehSaved then set['r.DepthOfFieldQuality']=math.max(2,set['r.DepthOfFieldQuality']) end
  applyCvars(set)
 else
  S.dofQuality=nil
  if presetOriginal then applyCvars(presetOriginal);presetOriginal=nil end
 end
end
local function tick()
 local r=pendingRequest
 if r and r.id~=lastrequest then
  lastrequest=r.id
  local ok,result=pcall(function() return command(r) end)
  if ok then S.error=nil end
  write(BRIDGE..'response.json',{id=r.id,ok=ok,result=ok and result or nil,error=not ok and message(result) or nil})
 end
 ticks=ticks+1
 if B then benchStep() end
 frame()
 replay.update(input)
 local t=previousTime or 0 -- real (unpaused) seconds of the current world
 if t<lastStateWrite then lastStateWrite=-1 end
 local replayActive=S.replay and S.replay.state~='idle'
 if t-lastStateWrite>=(replayActive and 0.05 or 0.1) then
  lastStateWrite=t
  worldinfo()
  if pendingPose and S.ready and S.world==pendingPose.world then restorepose(pendingPose); pendingPose=nil end
  write(BRIDGE..'state.json',S)
  if not B then framePacing() end
 end
 if ticks%32==0 then applyhands(); abilities() end
 if ticks%120==1 then pcall(publishGameSettings) end
end
if LoopInGameThreadAfterFrames then
 -- v4.1.0: the camera and mod logic run once per rendered frame (smooth video);
 -- file polling stays on the async timer, off the game thread.
 LoopAsync(12,function()
  input=read(BRIDGE..'input.json') or input
  local r=read(BRIDGE..'request.json'); if r then pendingRequest=r end
  return false
 end)
 LoopInGameThreadAfterFrames(1,function() safe(tick); return false end)
else
 LoopAsync(12,function()
  if waiting then return end
  waiting=true
  input=read(BRIDGE..'input.json') or input
  pendingRequest=read(BRIDGE..'request.json')
  ExecuteInGameThread(function() safe(tick); waiting=false end)
 end)
end
if config.settings then for k,v in pairs(config.settings) do if S[k]~=nil and k~='freecam' and k~='tool' then S[k]=v end end end
if S.bokeh and (tonumber(S.bokehBlades) or 0)==0 then S.bokehBlades=6 end -- older settings had only the on/off switch
if not presetById(S.preset) then S.preset='medium' end -- the POV preset was removed
if not config.test and config.installDir then
 os.execute('wscript.exe //B "'..config.installDir..'/Start.vbs"')
end
print('[Toybox] v4 loaded\n')
