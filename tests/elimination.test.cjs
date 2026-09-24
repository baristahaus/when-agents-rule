const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
function setup(){
 // The training tables are the subject here, so they are loaded rather than stubbed:
 // canAffordAnyMilitary reads BUILDING_TRAIN_TIERS through getTrainOptionsForBuilding now,
 // exactly as the training panel and the model-facing vocabulary do. A stub of
 // getBuildingDef/getUnitDefFor used to be enough while the predicate carried its own copy
 // of that list — which is precisely the copy that was wrong.
 const scope={console:{log(){}},performance:{now:()=>Date.now()},
  localStorage:{getItem:()=>null,setItem(){},removeItem(){}}};
 vm.createContext(scope);
 for(const f of ['js/civilizations.js','js/units.js','js/buildings.js','js/resources.js','js/i18n.js'])
  vm.runInContext(fs.readFileSync(path.join(__dirname,'..',f),'utf8'),scope,{filename:f});
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../js/game.js'),'utf8').split('\nconst WAR_PRIVATE_HOST')[0],scope,{filename:'js/game.js'});
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../js/openai-ai.js'),'utf8'),scope,{filename:'js/openai-ai.js'});
 const game=Object.create(vm.runInContext('Game.prototype',scope));
 // Food for one scout cavalry (100f/30g) twice over and the gold for it, but no wood and no
 // stone — so a rebuilt town center is never what keeps this seat alive.
 const funds={food:200,gold:100,stone:0};
 const ai={id:'a',civilization:'yamato',age:'iron',units:[],buildings:[],resources:{hasResources:cost=>Object.entries(cost).every(([k,v])=>(funds[k]||0)>=v)}};
 const stable={owner:'a',type:'stable',health:50,underConstruction:true};
 const worker={owner:'a',type:'worker',health:50,task:'building',buildTarget:stable};
 ai.units.push(worker);ai.buildings.push(stable);
 const manager=Object.create(vm.runInContext('OpenAIAIManager.prototype',scope));
 Object.assign(manager,{game,askFinalWord(){},abortLanes(){},commitDecision(){},decisionLog:[],maxLogEntries:400});
 const controller={aiPlayer:ai,id:'a'};controller.seat=controller;
 return {game,ai,stable,worker,funds,manager,controller};
}
test('last finished trainer can fall while a staffed affordable stable keeps the player active',()=>{
 const h=setup();const old={type:'stable',health:100};h.ai.buildings.push(old);
 assert.equal(h.game.isPlayerEliminated(h.ai),false);
 old.health=0;
 assert.equal(h.manager.isControllerDefeated(h.controller),false);
 h.stable.underConstruction=false;h.worker.task=null;
 assert.equal(h.game.isPlayerEliminated(h.ai),false);
 assert.equal(h.controller.defeated,undefined);
});
test('dead builders, abandoned or destroyed sites, and unaffordable training do not preserve survival',()=>{
 for(const change of [h=>h.worker.health=0,h=>h.worker.task='idle',h=>h.worker.buildTarget={},h=>h.stable.health=0,h=>h.funds.gold=0,h=>h.ai.age='stone']){
  const h=setup();change(h);assert.equal(h.game.isPlayerEliminated(h.ai),true);
 }
});
test('paid military production keeps a penniless player alive until the unit emerges',()=>{
 const h=setup();h.ai.units=[];h.stable.underConstruction=false;
 h.stable.isProducing=true;h.stable.productionType='scout_cavalry';h.funds.food=h.funds.gold=0;
 assert.equal(h.game.isPlayerEliminated(h.ai),false);
 h.stable.isProducing=false;h.ai.units.push({type:'scout_cavalry',health:100});
 assert.equal(h.game.isPlayerEliminated(h.ai),false);
 h.ai.units[0].health=0;assert.equal(h.game.isPlayerEliminated(h.ai),true);
});
test('retired controller cannot become alive again when old construction finishes',()=>{
 const h=setup();h.worker.task='idle';assert.equal(h.manager.isControllerDefeated(h.controller),true);
 h.manager.markDefeated(h.controller);
 h.stable.underConstruction=false;
 assert.equal(h.controller.defeated,true);assert.equal(h.game.isPlayerEliminated(h.ai),true);
 const winner={units:[{type:'warrior',health:100}],buildings:[]};
 h.game.aiManager={aiPlayers:[h.ai,winner]};let result;
 h.game.endArena=(ai,reason)=>result={ai,reason};h.game.checkArenaEnd(50);
 assert.equal(result.ai,winner);assert.equal(result.reason,'last_standing');
});
test('active construction prevents premature arena victory; losing the builder allows it',()=>{
 const h=setup(),winner={units:[{type:'warrior',health:100}],buildings:[]};
 h.game.aiManager={aiPlayers:[h.ai,winner]};let result;
 h.game.endArena=(ai,reason)=>result={ai,reason};h.game.checkArenaEnd(50);
 assert.equal(result,undefined);assert.equal(h.ai._eliminated,undefined);
 h.worker.health=0;h.game.checkArenaEnd(50);
 assert.equal(result.ai,winner);assert.equal(h.ai._eliminated,true);
});
test('a defeated seat cannot win through a leftover wonder',()=>{
 const h=setup();h.ai._eliminated=true;h.ai.buildings.push({isWonder:true,health:100});h.ai._wonderHold=599999;
 const winner={units:[{type:'warrior',health:100}],buildings:[]};h.game.aiManager={aiPlayers:[h.ai,winner]};
 let result;h.game.endArena=(ai,reason)=>result={ai,reason};h.game.checkArenaEnd(100);
 assert.equal(result.ai,winner);assert.equal(result.reason,'last_standing');
});

test('opponent snapshots expose defeat independently of discovery, including human opponents',()=>{
 const source=fs.readFileSync(path.join(__dirname,'../js/openai-ai.js'),'utf8');
 const start=source.indexOf('const met = ai._metRivals');
 const end=source.indexOf('// --- Threats',start);
 const opponents=new Function('game','ai',source.slice(start,end)+'return aiOpponents;');
 const h=setup(),viewer={id:'viewer',_metRivals:new Set(['known'])};
 const known={id:'known',civilization:'greek',age:'bronze',units:[{type:'warrior',health:100}],buildings:[]};
 h.ai._eliminated=true;
 h.game.seatLabel=o=>o.id;h.game.spectatorMode=false;
 h.game.player={id:'player',civilization:'persian',age:'iron',units:[],buildings:[],_eliminated:true};
 h.game.aiManager={aiPlayers:[viewer,h.ai,known]};
 const rows=opponents(h.game,viewer);
 assert.equal(rows.length,3);
 assert.deepEqual(rows[0],{id:'a',civilization:'yamato',age:'iron',discovered:false,defeated:true});
 assert.deepEqual(rows[1],{id:'known',civilization:'greek',age:'bronze',discovered:true,defeated:false,population:1,buildings:0});
 assert.equal(rows[2].defeated,true);assert.equal(rows[2].discovered,false);
 assert.equal('population' in rows[2],false);assert.equal('buildings' in rows[2],false);
 viewer._metRivals.add('a');const discovered=opponents(h.game,viewer)[0];
 assert.equal(discovered.defeated,true);assert.equal(discovered.discovered,true);
});
