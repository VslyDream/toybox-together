-- Shelf operations use stock pickup and native resting/placement registration.
-- Only the native item manager inserts or removes replicated entries/instances.
local M={}
function M.new(ctx)
 local H,S,valid,console=ctx.H,ctx.S,ctx.valid,ctx.console
 local job=nil
 local spawnFloor=nil
 local nullColor={R=0,G=0,B=0,A=0}
 local function vec(v)return {X=v.X,Y=v.Y,Z=v.Z}end
 local function entries(fn)
  local gs=H:GetGameStateBase();assert(valid(gs.ItemManager),'Дождитесь загрузки игрушек.')
  for j=1,#gs.ItemManager.Shards do local a=gs.ItemManager.Shards[j].Entries.Items;for k=1,#a do fn(a[k],gs)end end
  return gs
 end
 local function countShelf()
  local n=0;entries(function(it)if it.bIsShelfItem then n=n+1 end end);return n
 end
 local function countEntries()
  local n=0;entries(function()n=n+1 end);return n
 end
 local function trace(a,b,ignore)
  local hit={};local ok=H:GetKismetSystemLibrary():LineTraceSingle(H:GetWorld(),a,b,0,false,ignore or {},0,hit,true,nullColor,nullColor,0)
  return ok and hit or nil
 end
 local function hitOwner(hit)
  if hit and hit.Component then local c=hit.Component:Get();if valid(c)then return c:GetOwner()end end
 end
 local function aim(p,pc)
  local cam=pc.PlayerCameraManager;local start=vec(cam:GetCameraLocation());local forward=H:GetKismetMathLibrary():GetForwardVector(cam:GetCameraRotation())
  local hit=trace(start,{X=start.X+forward.X*1800,Y=start.Y+forward.Y*1800,Z=start.Z+forward.Z*1800},{p})
  local owner=hitOwner(hit)
  if valid(owner) and owner:IsA('/Script/MyToyStore.TS_BaseShelf')then return owner end
  -- Toys are HISM instances owned by the manager, not by the shelf actor.
  if hit then
   local result,best=nil,6400
   entries(function(it)if it.bIsShelfItem and valid(it.ShelfRow)then
    local v=it.Location;local q=hit.ImpactPoint;local d=(v.X-q.X)^2+(v.Y-q.Y)^2+(v.Z-q.Z)^2
    if d<best then best=d;result=it.ShelfRow:GetOwner()end
   end end)
   if valid(result)then return result end
  end
  error('Наведите прицел на шкаф или игрушку на его полке.')
 end
 local function restore(j)
  if j.bank and #j.bank>0 and j.grid and #j.grid.points>0 then
   -- Pending definitions still represent removed, real toys. Publish those
   -- toys even when a later batch fails, before removing the carrier.
   while #j.bank>0 do local def=table.remove(j.bank);spawnFloor(def,j)end
  end
  if valid(j.carrierPC)then H:GetGameplayStatics():RemovePlayer(j.carrierPC,true)end
  if j.splitSettings then j.splitSettings.bUseSplitscreen=j.split end
  for _,a in ipairs(j.blocked or {})do if valid(a.row)then a.row.OccupiedMask=a.occupied;a.row.PendingMask=a.pending end end
  if j.masked then entries(function(it)if j.masked[it.ItemId]then it.bIsShelfItem=false end end)end
  if valid(j.manager) and j.releaseLimit then j.manager.MaxReleasedItems=j.releaseLimit end
 end
 local function finish(state,message)
  local j=job;if not j then return end
  restore(j);S.shelfBusy=false
  S.shelfOperation={id=j.id,state=state,kind=j.kind,total=j.total,completed=j.completed or 0,message=tostring(message):gsub('^[^\r\n]*%.lua:%d+:%s*',''),elapsed=j.started and j.now-j.started or 0}
  job=nil
 end
 -- A stratified grid is shuffled before use. Each candidate must hit a flat
 -- floor near existing floor items, with room for a toy above it.
 local function floorPoints(p,manager,n)
  local bounds={};assert(StaticFindObject('/Script/MyToyStore.Default__TS_GameHelper'):FindMapBounds(H:GetWorld(),bounds),'Не удалось определить границы магазина.')
  local references={};entries(function(it)if not it.bIsShelfItem and it.Location.Z>=bounds.min.Z-100 and it.Location.Z<=bounds.max.Z+100 then references[#references+1]=vec(it.Location)end end)
  if #references==0 then local pos=p:K2_GetActorLocation();references[1]={X=pos.X,Y=pos.Y,Z=pos.Z-92}end
  local min,max=bounds.min,bounds.max
  local width,height=max.X-min.X,max.Y-min.Y
  local spacing=math.max(35,math.min(85,math.sqrt(width*height/math.max(80,n))*.7))
  local cols=math.max(1,math.ceil(width/spacing));local rows=math.max(1,math.ceil(height/spacing))
  local candidates={}
  for y=0,rows-1 do for x=0,cols-1 do candidates[#candidates+1]={X=min.X+(x+.25+math.random()*.5)*width/cols,Y=min.Y+(y+.25+math.random()*.5)*height/rows}end end
  for i=#candidates,2,-1 do local k=math.random(i);candidates[i],candidates[k]=candidates[k],candidates[i]end
  return {candidates=candidates,references=references,points={},index=1,ignore={p,manager},needed=math.min(#candidates,math.max(80,n)),bounds=bounds}
 end
 local function sampleFloor(grid,budget)
  local done=0
  while grid.index<=#grid.candidates and done<budget and #grid.points<grid.needed do
   done=done+1;local q=grid.candidates[grid.index];grid.index=grid.index+1
   local nearest,best=nil,math.huge
   -- Sampling references is sufficient here: the floor height is locally
   -- checked by collision traces and cannot be inferred from map bounds.
   local step=math.max(1,math.floor(#grid.references/300))
   for k=1,#grid.references,step do local r=grid.references[k];local d=(q.X-r.X)^2+(q.Y-r.Y)^2;if d<best then best=d;nearest=r end end
   local z=nearest.Z
   local hit=trace({X=q.X,Y=q.Y,Z=z+85},{X=q.X,Y=q.Y,Z=z-180},grid.ignore)
   local owner=hitOwner(hit)
   -- UE4SS exposes packed HitResult booleans as their shared byte in this
   -- engine build. Time/Distance distinguish penetration without that bit.
   if hit and hit.Time>.001 and hit.ImpactNormal.Z>.95 and math.abs(hit.ImpactPoint.Z-z)<75 and not(valid(owner)and owner:IsA('/Script/MyToyStore.TS_BaseShelf'))then
    local center={X=q.X,Y=q.Y,Z=hit.ImpactPoint.Z+28};local clear=true
    for _,v in ipairs({{X=30,Y=0},{X=-30,Y=0},{X=0,Y=30},{X=0,Y=-30}})do
     if trace(center,{X=center.X+v.X,Y=center.Y+v.Y,Z=center.Z},grid.ignore)then clear=false;break end
    end
    if clear then grid.points[#grid.points+1]={X=q.X,Y=q.Y,Z=hit.ImpactPoint.Z}end
   end
  end
  return #grid.points>=grid.needed or grid.index>#grid.candidates
 end
 local function putOnFloor(actor,j)
  local i=j.scattered+1;j.scattered=i
  local q=j.grid.points[(i-1)%#j.grid.points+1];local mesh=actor.Mesh
  if i>#j.grid.points then
   local x,y=q.X+(math.random()-.5)*24,q.Y+(math.random()-.5)*24
   local hit=trace({X=x,Y=y,Z=q.Z+60},{X=x,Y=y,Z=q.Z-30},j.grid.ignore)
   if hit and hit.Time>.001 and hit.ImpactNormal.Z>.95 and math.abs(hit.ImpactPoint.Z-q.Z)<8 then q={X=x,Y=y,Z=hit.ImpactPoint.Z}end
  end
  local def=actor.Definition;local bottom=3
  if valid(def)and valid(def.StaticMesh)then local b=def.StaticMesh:GetBounds();bottom=math.max(1,(b.BoxExtent.Z-b.Origin.Z)*def.MeshScale)end
  local target={X=q.X,Y=q.Y,Z=q.Z+bottom+2};local r={Pitch=0,Yaw=math.random()*360,Roll=0}
  if valid(def)then mesh:SetWorldScale3D({X=def.MeshScale,Y=def.MeshScale,Z=def.MeshScale})end
  mesh:SetCollisionResponseToChannel(5,0)
  mesh:SetCollisionResponseToChannel(1,0)
  mesh:SetCollisionResponseToChannel(2,0)
  mesh:K2_SetWorldLocationAndRotation(target,r,false,{},true)
  mesh:SetPhysicsLinearVelocity({X=0,Y=0,Z=0},false,FName('None'))
  mesh:SetPhysicsAngularVelocityInDegrees({X=0,Y=0,Z=0},false,FName('None'))
  mesh:PutRigidBodyToSleep(FName('None'))
  actor:OnMeshSleep(mesh,FName('None'))
  j.inFlight[#j.inFlight+1]={actor=actor,p=target,r=r,time=j.now}
 end
 spawnFloor=function(def,j)
  local q=j.grid.points[(j.scattered)%#j.grid.points+1]
  local class=valid(def.ItemActorClassOverride)and def.ItemActorClassOverride or StaticFindObject('/Script/MyToyStore.TS_ItemActor')
  local a=H:GetWorld():SpawnActor(class,{X=q.X,Y=q.Y,Z=q.Z+50},{Pitch=0,Yaw=0,Roll=0})
  assert(valid(a),'Игра не создала предмет на полу.')
  a.Definition=def;a:OnRep_Definition();assert(valid(a.Mesh),'У игрушки нет модели.')
  putOnFloor(a,j);a:ForceNetUpdate()
 end
 local function carrier(j)
  j.splitSettings=StaticFindObject('/Script/EngineSettings.Default__GameMapsSettings');j.split=j.splitSettings.bUseSplitscreen;j.splitSettings.bUseSplitscreen=false
  j.carrierPC=H:GetGameplayStatics():CreatePlayer(H:GetWorld(),-1,true)
  assert(valid(j.carrierPC)and valid(j.carrierPC.Pawn),'Не удалось подготовить перенос игрушек.')
  j.carrier=j.carrierPC.Pawn;j.carrier:SetActorHiddenInGame(true);j.carrier:SetActorEnableCollision(false)
  if valid(j.carrierPC.MyHUD)then j.carrierPC.MyHUD.bShowHUD=false end
  j.carrier.CharacterMovement:SetComponentTickEnabled(false);j.carrierPC:DisableInput(j.carrierPC);j.carrier:DisableInput(j.carrierPC)
  j.bank={}
 end
 local function start(r)
  local p,pc=ctx.authority();assert(S.ready,'Дождитесь загрузки игрушек.');assert(not job,'Дождитесь завершения операции с полками.')
  assert(not H:GetGameplayStatics():IsGamePaused(H:GetWorld()),'Снимите паузу перед изменением полок.')
  local replay=S.replay or {};assert(replay.kind~='players' or replay.state=='idle','Завершите повтор игроков перед изменением полок.')
  assert((S.throwRemaining or 0)==0,'Дождитесь завершения броска.')
  assert(r.kind=='fill' or r.kind=='clear' or r.kind=='aimed','Неизвестная операция с полками.')
  local count=tonumber(r.count);assert(count and count==math.floor(count)and(count==-1 or count>=0 and count<=1000000),'Введите количество игрушек или выберите «Все».')
  local j={id=r.operationId or r.id,kind=r.kind,pawn=p,pc=pc,manager=H:GetGameStateBase().ItemManager,total=0,completed=0,scattered=0,blocked={},masked={},inFlight={},now=0,initialHeld=p.Interaction:GetHeldCount()}
  if r.kind=='clear'then
   j.ids={};entries(function(it)if it.bIsShelfItem then j.ids[#j.ids+1]=it.ItemId end end)
   -- Removing from across the store avoids clearing only its first rack.
   for i=#j.ids,2,-1 do local k=math.random(i);j.ids[i],j.ids[k]=j.ids[k],j.ids[i]end
   j.total=count==-1 and #j.ids or math.min(count,#j.ids);j.cursor=1;j.pending=0;j.entryCount=countEntries()
   if j.total>0 then j.grid=floorPoints(p,j.manager,j.total);j.phase='sampling';j.releaseLimit=j.manager.MaxReleasedItems end
  else
   j.before=countShelf();local target=r.kind=='aimed'and aim(p,pc)or nil
   local types={};local rows=FindAllOf('TS_ShelfRowComponent')or{}
   if target then
    target.PlannedItems:ForEach(function(key,value)local def=key:get();if valid(def)and value:get()>0 then types[def:GetAddress()]=true end end)
    local hasPlan=next(types)~=nil
    for _,row in ipairs(rows)do if valid(row)and valid(row:GetOwner())and row:GetOwner():GetAddress()==target:GetAddress()then
     local def=row:GetLockedType()
     if valid(def)then types[def:GetAddress()]=true elseif not hasPlan then for k=1,#row.TypePresets do local a=row.TypePresets[k].ItemType;if valid(a)then types[a:GetAddress()]=true end end end
    end end
   end
   local floor=0
   entries(function(it,gs)if not it.bIsShelfItem then
    local allowed=not target or types[gs:GetDefByIndex(it.DefIndex):GetAddress()]
    if allowed then floor=floor+1 else j.masked[it.ItemId]=true end
   end end)
   j.total=count==-1 and floor or math.min(count,floor)
   if target and j.total>0 then
    for _,row in ipairs(rows)do if valid(row)and valid(row:GetOwner())and row:GetOwner():GetAddress()~=target:GetAddress()then
     j.blocked[#j.blocked+1]={row=row,occupied=row.OccupiedMask,pending=row.PendingMask}
    end end
   end
   j.phase='fill';j.target=target;j.stall=0
  end
  job=j;S.shelfBusy=true;S.shelfOperation={id=j.id,state='running',kind=j.kind,total=j.total,completed=0,message=j.phase=='sampling'and'Ищу свободные участки пола…'or'Расставляю игрушки…'}
  local ok,e=pcall(function()
   if j.total==0 then finish('done','Подходящих игрушек нет.')
   elseif j.phase=='fill'then
    for _,a in ipairs(j.blocked)do a.row.OccupiedMask=0xffffffff;a.row.PendingMask=0xffffffff end
    entries(function(it)if j.masked[it.ItemId]then it.bIsShelfItem=true end end)
    console('TS.Items.MoveToShelfs '..j.total)
   else j.manager.MaxReleasedItems=math.max(j.releaseLimit,128)end
  end)
  if not ok then finish('error',tostring(e));error(e)end
  return {operation=j.id,total=j.total}
 end
 local function step(now)
  local j=job;if not j then return end;j.now=now
  assert(valid(j.pawn)and valid(j.pc)and valid(j.manager)and S.ready,'Карта закрылась. Операция остановлена.')
  if not j.started then j.started=now;j.lastProgress=now end
  if j.phase=='fill'then
   -- Masked floor entries were not moved and must not count as placements.
   local n=countShelf();local masked=0;for _ in pairs(j.masked)do masked=masked+1 end
   local progress=math.max(0,n-j.before-masked)
   if progress>j.completed then j.completed=progress;j.lastProgress=now end
   if j.completed>=j.total or now-j.lastProgress>3 then finish('done',j.completed>0 and('Расставлено: '..j.completed..'.')or'На полках нет свободных мест для подходящих игрушек.');return end
  elseif j.phase=='sampling'then
   if sampleFloor(j.grid,30)then assert(#j.grid.points>0,'Не найдены свободные участки пола. Игрушки не сняты.');carrier(j);j.phase='clear';S.shelfOperation.message='Снимаю игрушки и распределяю по полу…'end
  else
   -- Bound transient physics actors while native settling publishes entries.
   local outstanding={}
   for _,f in ipairs(j.inFlight)do if valid(f.actor)and not f.actor.bSettled then
    if now-f.time>.05 then
     -- These actors have no thrower or hand animation. Reapply the pose after
     -- the initial physics body has been created, then let native settling
     -- publish the replicated resting entry.
     f.actor.Mesh:K2_SetWorldLocationAndRotation(f.p,f.r,false,{},true)
     f.actor.Mesh:SetPhysicsLinearVelocity({X=0,Y=0,Z=0},false,FName('None'))
     f.actor.Mesh:SetPhysicsAngularVelocityInDegrees({X=0,Y=0,Z=0},false,FName('None'))
     f.actor.Mesh:PutRigidBodyToSleep(FName('None'));f.actor:OnMeshSleep(f.actor.Mesh,FName('None'))
    end
    assert(now-f.time<12,'Игра не подтвердила игрушки на полу. Операция остановлена.');outstanding[#outstanding+1]=f
   end end
   j.inFlight=outstanding
   if j.pending==0 and j.cursor<=j.total and #j.inFlight<128 then
    local ids={};for k=j.cursor,math.min(j.total,j.cursor+63)do ids[#ids+1]=j.ids[k]end
    ctx.withoutRecording(function()ctx.withTrack(j.carrier,j.carrierPC,function()ctx.tool.grabIds(ids)end)end)
    local held=j.carrier.Interaction.HeldStack;assert(#held==#ids,'Игра не подтвердила подбор игрушек.')
    for k=1,#held do j.bank[#j.bank+1]=held[k]end
    j.carrier.Interaction.HeldStack={};j.carrier.Interaction.EffectiveHeldStack={}
    assert(j.carrier.Interaction:GetHeldCount()==0,'Игра не освободила переносчик игрушек.')
    j.pending=#ids;j.cursor=j.cursor+#ids
   end
   if j.pending>0 then
    for k=1,math.min(16,j.pending)do
     local def=j.bank[#j.bank];spawnFloor(def,j);table.remove(j.bank)
     j.pending=j.pending-1;j.completed=j.completed+1
    end
   end
   if j.completed>=j.total and j.pending==0 and #j.inFlight==0 then
    if not j.confirmStarted then j.confirmStarted=now end
    assert(now-j.confirmStarted<12,'Игра ещё не подтвердила все игрушки на полу. Операция остановлена.')
    if countEntries()==j.entryCount then
     assert(j.pawn.Interaction:GetHeldCount()==j.initialHeld,'Состав игрушек в руках изменился.')
     finish('done','Снято и распределено по полу: '..j.completed..'.');return
    end
   end
  end
  if job then S.shelfOperation.completed=j.completed end
 end
 local function update(now)
  if not job then return end
  local ok,e=pcall(step,now);if not ok then finish('error',tostring(e))end
 end
 local function cancel(travel)
  if job then if travel then finish('error','Загрузка карты остановила операцию с полками.')else finish('error','Операция остановлена.')end end
 end
 return {start=start,update=update,cancel=cancel,aim=aim,busy=function()return job~=nil end}
end
return M
