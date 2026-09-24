// Guards the two places the action vocabulary is stated twice: OpenAIAIManager.ACTIONS
// (what models are OFFERED, and the tool schemas generated from it) and the switch in
// executeAction (what the engine will ACCEPT). js/openai-ai.js:69-70 promises this test
// by name; without it a `case` added to the dispatcher is an action no model is ever
// told about, which silently changes what a score means from one build to the next.
// The README action set is pinned here too, because it is the third copy.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const src=fs.readFileSync(path.join(__dirname,'../js/openai-ai.js'),'utf8');
const scope={console:{log(){},warn(){},error(){}},Math,JSON,Date,Object,Array,String,Number,Boolean,Set,Map,RegExp,Error,Promise,
 isNaN,parseInt,parseFloat,setTimeout,clearTimeout,setInterval:()=>0,clearInterval(){},performance:{now:()=>Date.now()},
 localStorage:{getItem:()=>null,setItem(){},removeItem(){}},document:undefined};
 vm.createContext(scope);
 for(const f of ['js/civilizations.js','js/units.js','js/buildings.js','js/resources.js','js/i18n.js'])
  vm.runInContext(fs.readFileSync(path.join(__dirname,'..',f),'utf8'),scope,{filename:f});
 // game.js up to its WAR_PRIVATE_HOST tail: the class is what the handlers talk to,
 // and the tail reads location, which a test context has no business faking.
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../js/game.js'),'utf8')
  .split('\nconst WAR_PRIVATE_HOST')[0],scope,{filename:'js/game.js'});
 vm.runInContext(src,scope);
const M=vm.runInContext('OpenAIAIManager',scope);

test('every dispatched action is offered, and every offered action dispatches',()=>{
 // Arrays built inside the vm carry that realm's Array.prototype; deepStrictEqual
 // compares prototypes, so spread them into host arrays before comparing or two
 // empty lists never equal each other.
 const offered=[...M.ACTIONS].map(a=>a.name);
 const dispatched=[...M.prototype.executeAction.toString().matchAll(/case\s+'([a-z_]+)'/g)].map(m=>m[1]);
 assert.ok(offered.length>=12,'ACTIONS should list the full vocabulary, got '+offered.length);
 assert.ok(dispatched.length>=12,'executeAction should handle the full vocabulary, got '+dispatched.length);
 const missing=dispatched.filter(c=>!offered.includes(c));
 const unhandled=offered.filter(n=>!dispatched.includes(n));
 assert.deepEqual(missing,[],'dispatched but never advertised to a model: '+missing.join(', '));
 assert.deepEqual(unhandled,[],'advertised to models but not dispatched: '+unhandled.join(', '));
});

test('the README action set names exactly the implemented actions',()=>{
 const md=fs.readFileSync(path.join(__dirname,'../README.md'),'utf8');
 const line=md.split('\n').find(l=>l.startsWith('**Action set:**'));
 assert.ok(line,'README must keep its **Action set:** line, or this test should be deleted with it');
 // Only the list itself: the sentence after it goes on to name train_unit and
 // build_structure a second time while explaining villagers and the Wonder.
 const documented=[...line.split('**Action set:**')[1].split('. ')[0].matchAll(/`([a-z_]+)`/g)].map(m=>m[1]);
 assert.deepEqual(documented,[...M.ACTIONS].map(a=>a.name),
  'README and OpenAIAIManager.ACTIONS disagree — one of the three copies of this list drifted');
});

test('"count" is refused when it is not a number, never read as NaN',()=>{
 // Math.min("all",20) is NaN, and every consumer compares against it:
 // `removed < NaN` deleted nothing while answering "OK", `.slice(0,NaN)` sent no
 // worker and blamed the workers that were building, `moved >= NaN` reassigned
 // every worker the seat owned. All three read as a successful or misattributed
 // turn, which is the one thing a per-command success rate must never do.
 const P=M.parseCount;
 assert.equal(P(undefined,3,20),3,'absent falls back to the default');
 assert.equal(P(null,3,20),3);assert.equal(P('',3,20),3);assert.equal(P(0,3,20),3);
 assert.equal(P('7',3,20),7);assert.equal(P(7.9,3,20),7,'fractional truncates');
 assert.equal(P(999,3,20),20,'clamped to the handler ceiling');
 for(const bad of ['all','two',NaN,Infinity,'1,2',{},[1,2],'3x'])
  assert.equal(P(bad,3,20),null,JSON.stringify(bad)+' is not a count and must be refused');
});

test('a refused count reports a rejection, not a success',()=>{
 const game=Object.create(vm.runInContext('Game',scope).prototype);
 game.terrain={size:800,resources:[],isWalkable:()=>true};
 const mk=id=>({id,type:'worker',health:60,maxHealth:60,x:0,z:0,task:'idle',owner:null,farmRef:null,harvestTarget:null});
 const ai={id:'greek',civilization:'greek',age:'iron',researchedTechs:{},
  units:[mk('w0'),mk('w1'),mk('w2')],
  buildings:[{type:'town_center',x:0,z:0,health:1700,maxHealth:1700,underConstruction:false},
   {type:'farm',x:3,z:3,health:100,maxHealth:500,underConstruction:false}],
  resources:{food:9999,wood:9999,stone:9999,gold:9999,population:3,maxPopulation:20,
   hasResources(c){return Object.entries(c).every(([k,v])=>(this[k]||0)>=v);}}};
 ai.units.forEach(u=>u.owner=ai);
 game.units=ai.units;game.isIdleWorker=()=>true;game.deleteOwnUnit=u=>{u.health=0;return true;};
 const mgr=Object.create(M.prototype);
 Object.assign(mgr,{game,outcome(){},decisionLog:[],commitDecision(){},noTownCenterAdvice:()=>null,
  discoveredNodesOfType:()=>[{x:5,z:5}],discoveredResourceSummary:()=>'food',workerSourceMatches:()=>true});
 const alive=()=>ai.units.filter(u=>u.health>0).length;

 const del=mgr.executeDeleteUnit(ai,game,{unitType:'worker',count:'all'});
 assert.match(del,/^\[ERROR\]/,'delete_unit must not answer OK to a value it could not read');
 assert.ok(!/OK/.test(del),'no "OK" may reach a turn that did nothing: '+del);
 assert.equal(alive(),3,'no unit may be deleted on a refused count');

 const rep=mgr.executeRepairBuilding(ai,game,{count:'all'});
 assert.match(rep,/^\[ERROR\] "count"/,'repair must name the bad parameter, not blame idle workers');
 assert.doesNotMatch(rep,/all are constructing/,'the old message invented a cause that was not true');

 const asg=mgr.executeAssignWorkers(ai,game,{resourceType:'food',count:'all'});
 assert.match(asg,/^\[ERROR\]/);
 assert.ok(ai.units.every(u=>u.task==='idle'),'a refused count must not reassign anyone: '+
  ai.units.map(u=>u.task).join(','));
});
