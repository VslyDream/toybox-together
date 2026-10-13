-- The stock grab operation removes replicated entries. Shelf occupancy/counts
-- need explicit adjustment because its floor-only path does not release slots.
local M={}
function M.new(ctx)
 local H,S,valid,console=ctx.H,ctx.S,ctx.valid,ctx.console
 local queue=nil
 local repairs={}
 local legacyDefs={}
 local function repair(row)
  if valid(row) then repairs[row:GetAddress()]={row=row,untilTime=H:GetGameplayStatics():GetTimeSeconds(H:GetWorld())+3,next=0} end
 end
 local function each(fn)
  local gs=H:GetGameStateBase();assert(valid(gs.ItemManager),'Дождитесь загрузки игрушек.')
  local shards=gs.ItemManager.Shards
  for j=1,#shards do local a=shards[j].Entries.Items;for k=1,#a do fn(a[k]) end end
  return gs
 end
 local function dist(a,b) return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
 local function aimedShelf(p,pc)
  local proxy=p.Interaction.HoverProxy
  if not p.Interaction:IsHoverPickup() or not valid(proxy) or not valid(proxy.StaticMesh) then return nil end
  local origin=proxy:K2_GetComponentLocation()
  local nearest=nil;local best=25
  local gs=H:GetGameStateBase()
  each(function(it)
   local d=dist(it.Location,origin)
   if d<best then
    local def=gs:GetDefByIndex(it.DefIndex)
    if valid(def) and valid(def.StaticMesh) and def.StaticMesh:GetAddress()==proxy.StaticMesh:GetAddress() then
     nearest=it.bIsShelfItem and valid(it.ShelfRow) and it.ShelfRow:GetOwner() or nil;best=d
    end
   end
  end)
  return nearest
 end
 local function grabIds(ids)
  local p=ctx.authority();local gs=H:GetGameStateBase()
  local selected,masked,old={},{},{}
  local targets={}
  for _,id in ipairs(ids) do selected[id]=true end
  each(function(it)
   if selected[it.ItemId] then
    targets[#targets+1]={def=it.DefIndex,definition=gs:GetDefByIndex(it.DefIndex):GetFullName(),p={X=it.Location.X,Y=it.Location.Y,Z=it.Location.Z}}
    if it.bIsShelfItem then
     local row=it.ShelfRow;local def=gs:GetDefByIndex(it.DefIndex)
     local correct=valid(row) and valid(def) and valid(row:GetLockedType()) and row:GetLockedType():GetAddress()==def:GetAddress()
     old[it.ItemId]={row=row,point=it.ShelfPointIndex,def=it.DefIndex,correct=correct}
     it.bIsShelfItem=false
    end
   elseif not it.bIsShelfItem then masked[it.ItemId]=true;it.bIsShelfItem=true end
  end)
  local before=p.Interaction:GetHeldCount()
  local ok,err=pcall(function() console('TS.Items.Grab '..#ids) end)
  local remaining={}
  each(function(it)
   remaining[it.ItemId]=true
   if masked[it.ItemId] then it.bIsShelfItem=false end
   if old[it.ItemId] then it.bIsShelfItem=true end
  end)
  for id,it in pairs(old) do if not remaining[id] then
   if valid(it.row) and it.point>=0 and it.point<32 then
    it.row.OccupiedMask=it.row.OccupiedMask & (~(1 << it.point) & 0xffffffff)
    it.row:OnRep_OccupiedMask()
    repair(it.row)
   end
   if it.correct then
    gs.CorrectlyPlaced=math.max(0,gs.CorrectlyPlaced-1)
    local a=gs.ShelfPlacedPerDef
    if it.def+1<=#a then a[it.def+1]=math.max(0,a[it.def+1]-1) end
   end
  end end
  gs.bStoreComplete=gs.CorrectlyPlaced>=gs.TotalItems
  gs:OnRep_ToyCounts()
  if not ok then error(err) end
  local took=p.Interaction:GetHeldCount()-before
  assert(took==#ids,'Игра взяла '..took..' из '..#ids..' игрушек.')
  if ctx.recordGrab then ctx.recordGrab(p,targets) end
  return {taken=took}
 end
 local function grab()
  local p,pc=ctx.authority();local shelf=aimedShelf(p,pc)
  local prefetched=0
  -- Completed shelves may suppress HoverProxy. Use the real pickup to identify
  -- its rack, then take the remainder through the same replicated item path.
  if not valid(shelf) and p.Interaction:IsHoverPickup() and not valid(p.Interaction.HoverProxy) then
   local before={};each(function(it)before[it.ItemId]={target={def=it.DefIndex,p={X=it.Location.X,Y=it.Location.Y,Z=it.Location.Z}},row=it.bIsShelfItem and it.ShelfRow or nil,shelf=it.bIsShelfItem and valid(it.ShelfRow) and it.ShelfRow:GetOwner() or nil}end)
   local count=p.Interaction:GetHeldCount();local settings=p.Interaction.CharacterSettings;local capacity=settings.DefaultInventorSize
   settings.DefaultInventorSize=math.max(capacity,count+S.batch)
   local ok,e=pcall(function()ctx.withoutRecording(function()p.AbilitySystemComponent:PressInputID(1000);p.AbilitySystemComponent:ReleaseInputID(1000)end)end)
   settings.DefaultInventorSize=capacity;if not ok then error(e) end
   prefetched=p.Interaction:GetHeldCount()-count
   each(function(it)before[it.ItemId]=nil end)
   local targets={};for _,it in pairs(before) do it.target.definition=H:GetGameStateBase():GetDefByIndex(it.target.def):GetFullName();targets[#targets+1]=it.target;shelf=shelf or it.shelf;repair(it.row) end
   if prefetched>0 then
    if #targets>0 and ctx.recordGrab then ctx.recordGrab(p,targets)
    elseif ctx.recordNativePickup then ctx.recordNativePickup(p) end
   end
  end
  local location=p:K2_GetActorLocation();local candidates={}
  each(function(it)
   local sameShelf=shelf and it.bIsShelfItem and valid(it.ShelfRow) and it.ShelfRow:GetOwner():GetAddress()==shelf:GetAddress()
   if sameShelf or (not shelf and not it.bIsShelfItem) then candidates[#candidates+1]={id=it.ItemId,d=dist(it.Location,location)} end
  end)
  table.sort(candidates,function(a,b)return a.d<b.d end)
  local ids={};for i=1,math.min(S.batch-prefetched,#candidates) do ids[i]=candidates[i].id end
  local result=#ids>0 and grabIds(ids) or {taken=0};result.taken=result.taken+prefetched;result.shelf=valid(shelf) and true or false;result.shelfName=valid(shelf) and shelf:GetFName():ToString() or nil;return result
 end
 local function dropOne(p)
  local before=p.Interaction:GetHeldCount()
  local asc=p.AbilitySystemComponent;local class=StaticFindObject('/Script/MyToyStore.TS_DropItemAbility')
  asc:TryActivateAbilityByClass(class,true)
  if p.Interaction:GetHeldCount()<before then if ctx.recordThrow then ctx.recordThrow(p) end;return end
  for _,a in ipairs(FindAllOf('TS_DropItemAbility') or {}) do
   local avatar=a:GetAvatarActorFromActorInfo()
   if valid(avatar) and avatar:GetAddress()==p:GetAddress() then a:HandleThrowReleased(1);if ctx.recordThrow then ctx.recordThrow(p) end;return end
  end
  error('Способность броска не найдена.')
 end
 local function drop()
  local p,pc=ctx.authority();local count=math.min(S.batch,p.Interaction:GetHeldCount())
  if count==0 then return {dropped=0} end
  assert(not queue,'Предыдущая очередь броска ещё выполняется.')
  queue={pawn=p,pc=pc,left=count,total=count,next=0,index=0,rotation=pc:GetControlRotation()}
  S.throwRemaining=count
  return {queued=count}
 end
 local function update(now)
  if next(repairs) and S.ready then
   local t=H:GetGameplayStatics():GetTimeSeconds(H:GetWorld());local due={}
   for id,a in pairs(repairs) do if not valid(a.row) then repairs[id]=nil elseif t>=a.next then due[id]=0;a.next=t+.1 end end
   if next(due) then
    each(function(it)if it.bIsShelfItem and valid(it.ShelfRow) then local id=it.ShelfRow:GetAddress();if due[id] and it.ShelfPointIndex>=0 and it.ShelfPointIndex<32 then due[id]=due[id]|(1<<it.ShelfPointIndex) end end end)
    for id,mask in pairs(due) do local a=repairs[id];if a.row.OccupiedMask~=mask then a.row.OccupiedMask=mask;a.row:OnRep_OccupiedMask() end;if t>=a.untilTime then repairs[id]=nil end end
   end
  end
  if not queue then return end
  if not valid(queue.pawn) or not valid(queue.pc) or not S.ready then queue=nil;S.throwRemaining=0;return end
  if now<queue.next then return end
  local p=queue.pawn;local seen={}
  for _,it in ipairs(FindAllOf('TS_ItemActor') or {}) do seen[it:GetAddress()]=true end
  local before=p.Interaction:GetHeldCount()
  for i=1,math.min(8,queue.left,before) do dropOne(p) end
  local right=H:GetKismetMathLibrary():GetRightVector(queue.pc:GetControlRotation())
  for _,it in ipairs(FindAllOf('TS_ItemActor') or {}) do if not seen[it:GetAddress()] and valid(it.Mesh) then
   local lane=queue.index%8;queue.index=queue.index+1
   local side=(lane%4-1.5)*35;local up=(math.floor(lane/4)-0.5)*35
   local pos=it.Mesh:K2_GetComponentLocation()
   it.Mesh:K2_SetWorldLocation({X=pos.X+right.X*side,Y=pos.Y+right.Y*side,Z=pos.Z+up},false,{},true)
   -- Toys are PhysicsBody (5). They keep collisions with floors, walls and
   -- shelves, but do not push one another apart while this batch is in flight.
   it.Mesh:SetCollisionResponseToChannel(5,0)
  end end
  local took=before-p.Interaction:GetHeldCount()
  queue.left=queue.left-math.max(1,took);queue.next=now+0.03
  S.throwRemaining=math.max(0,queue.left)
  if queue.left<=0 or p.Interaction:GetHeldCount()==0 then queue=nil end
 end
 local function resolveTargets(targets,legacy)
  local selected={};local used={}
  for _,target in ipairs(targets) do
   local best,id=2500,nil
   local gs=H:GetGameStateBase();local definition=target.definition or legacy and legacyDefs[target.def]
   each(function(it,unused)
    if not used[it.ItemId] then
     local def=definition and gs:GetDefByIndex(it.DefIndex)or nil
     local match=definition and valid(def)and def:GetFullName()==definition or not definition and not legacy and it.DefIndex==target.def
     if match then local d=dist(it.Location,target.p);if d<best then best=d;id=it.ItemId end end
    end
   end)
   if not id and legacy and not definition then
    local candidates={};local nearest=25
    each(function(it)if not used[it.ItemId] then local d=dist(it.Location,target.p);if d<nearest then nearest=d;id=it.ItemId end;if d<25 then candidates[#candidates+1]=it end end end)
    if id then
     local defIndex=nil
     for _,it in ipairs(candidates)do if defIndex and defIndex~=it.DefIndex then error('Не удалось однозначно сопоставить игрушку старого повтора.')end;defIndex=it.DefIndex end
     definition=H:GetGameStateBase():GetDefByIndex(defIndex):GetFullName();legacyDefs[target.def]=definition
    end
   end
   assert(id,'Игрушка из записи не найдена. Загрузите исходный уровень повтора.');used[id]=true;selected[#selected+1]=id
  end
  return grabIds(selected)
 end
 return {grab=grab,grabIds=grabIds,resolveTargets=resolveTargets,drop=drop,dropOne=dropOne,update=update,cancel=function() queue=nil;repairs={};legacyDefs={};S.throwRemaining=0 end,aimedShelf=aimedShelf}
end
return M
