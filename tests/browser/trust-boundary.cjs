// Optional real-browser regression for the three trust boundaries the unit suite cannot
// reach, because all three are properties of the rendered DOM rather than of a return
// value. Same contract as shared-updates.cjs: WAR_PLAYWRIGHT_PATH points at Playwright,
// WAR_CHROME_PATH may select an installed Chrome, WAR_QA_DIR receives screenshots.
//
// Everything asserted here was demonstrated broken first, in this harness, before it was
// fixed: a hostile /models response executed script in the page, and a hostile .jsonl
// executed on open and again on hover. The catalogue-import path shares the same helper and
// the same one-character payload, so it is covered by the helper rather than re-run here.
// No model connection is used — every endpoint is intercepted.
//
// One browser per scenario. Each scenario boots the whole app, which regenerates every
// procedural texture on a software rasteriser; three of those boots inside ONE Chromium
// process degrade until the third misses its own timeout. Isolation makes the run
// deterministic and makes each assertion mean something on its own.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),os=require('node:os');
const assert=require('node:assert/strict');
const {chromium}=require(process.env.WAR_PLAYWRIGHT_PATH||'playwright');
const root=path.resolve(__dirname,'../..');
const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.svg':'image/svg+xml','.png':'image/png','.ico':'image/x-icon','.jsonl':'application/x-ndjson'};
const relOf=u=>decodeURIComponent(new URL(u,'http://x').pathname).replace(/^\/+/,'')||'index.html';
const typeOf=rel=>mime[path.extname(rel)]||'application/octet-stream';
const read=rel=>{try{return fs.readFileSync(path.join(root,rel));}catch(e){return null;}};
// The same bytes through two transports: a real server on loopback, and a fulfil-route under
// a public hostname. Stripping the leading slash has to happen BEFORE the extension is read
// — handing a browser index.html as application/octet-stream aborts the navigation outright.
const server=http.createServer((req,res)=>{const rel=relOf(req.url),b=read(rel);
 if(!b){res.writeHead(404);return res.end('nf');}
 res.writeHead(200,{'Content-Type':typeOf(rel),'Cache-Control':'no-store'});res.end(b);});
const serveUnder=async(ctx)=>{await ctx.route('**/*',route=>{
 const rel=relOf(route.request().url()),b=read(rel);
 return b?route.fulfill({contentType:typeOf(rel),body:b}):route.fulfill({status:404,body:'nf'});});};

// Each payload closes the attribute it lands in and opens a handler of its own.
const H='window.__warPwned=1';
const HOSTILE_ID=`q" onmouseover="${H}" data-x="`;
const HOSTILE_ROW=`1" onmouseover="${H}" x="`;
const launch=()=>chromium.launch({headless:true,
 ...(process.env.WAR_CHROME_PATH?{executablePath:process.env.WAR_CHROME_PATH}:{}),
 // WAR_CHROME_ARGS: run against a real GPU (`--use-gl=angle --use-angle=vulkan`) instead of
 // software rasterisation. Defaults unchanged.
 args:['--enable-unsafe-swiftshader',...(process.env.WAR_CHROME_ARGS?process.env.WAR_CHROME_ARGS.split(' '):[])]});
// Works on a Browser or a BrowserContext — both expose newPage, and a scenario that
// intercepts requests needs the context one.
const newPage=async(scope)=>{const page=await scope.newPage({viewport:{width:1400,height:900}});
 // Low quality keeps the boot honest but cheap; English so the assertions can name strings.
 await page.addInitScript(()=>{localStorage.setItem('warGraphicsQuality','low');
  localStorage.setItem('warUiLang','en');window.__warPwned=0;});
 return page;};
const booted=page=>page.waitForFunction(()=>typeof game!=='undefined'&&game.renderer,null,{timeout:240000});
const parsed=()=>!!(game.ui.analyzer&&game.ui.analyzer.order&&game.ui.analyzer.order.length>0);
const GATED=['startScreen','gameModeScreen','arenaSetupScreen','modelLibraryScreen'];

(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const origin='http://127.0.0.1:'+server.address().port;
 const out=process.env.WAR_QA_DIR||fs.mkdtempSync(path.join(os.tmpdir(),'war-trust-'));
 fs.mkdirSync(out,{recursive:true});
 const done=[];
 try{
  // ---- 1. A copy served from a PUBLIC host stays a viewer. ----------------------
  // WAR_PRIVATE_HOST is what decides this, and until the guard moved into showScreen the
  // only enforcement was `body.demo-only .an-back { display:none }` — hiding the doorknob.
  {
   const browser=await launch();done.push(browser);
   try{
    const ctx=await browser.newContext();
    await serveUnder(ctx);
    const page=await newPage(ctx);
    await page.goto('http://war-public.example/?_='+Date.now(),{waitUntil:'load'});
    await page.waitForFunction(()=>typeof game!=='undefined'&&!!game,null,{timeout:240000});
    assert.ok(await page.evaluate(()=>document.body.classList.contains('demo-only')),
     'a copy on a public hostname must open in showcase mode');
    assert.equal(await page.evaluate(()=>[...document.querySelectorAll('.screen.active')].map(s=>s.id).join(',')),
     'analyzeScreen','the analyzer is the whole app here');
    const gated=await page.evaluate(ids=>{
     const missing=ids.filter(id=>!document.getElementById(id)),opened=[];
     for(const id of ids){game.ui.showScreen(id);
      if(document.getElementById(id).classList.contains('active'))opened.push(id);}
     return {missing,opened};},GATED);
    // Compare as strings: arrays from page.evaluate carry the page's Array.prototype and
    // deepStrictEqual compares prototypes, so [] !== [] across the bridge.
    assert.equal(gated.missing.join(','),'','these screen ids were renamed — update the guard in showScreen too');
    assert.equal(gated.opened.join(','),'','showcase mode must not render a screen that asks for credentials; reached: '+gated.opened.join(', '));
    await page.screenshot({path:path.join(out,'showcase-mode.png')});
   }finally{await browser.close();}
  }
  // ?full=1 is the documented opt-out for self-hosters, so the gate must not be sticky.
  {
   const browser=await launch();done.push(browser);
   try{
    const ctx=await browser.newContext();
    await serveUnder(ctx);
    const page=await newPage(ctx);
    await page.goto('http://war-public.example/?full=1&_='+Date.now(),{waitUntil:'load'});
    await page.waitForFunction(()=>typeof game!=='undefined',null,{timeout:240000});
    assert.equal(await page.evaluate(()=>document.body.classList.contains('demo-only')),false,
     '?full=1 must restore the full app');
    assert.equal(await page.evaluate(id=>{game.ui.showScreen(id);
     return document.getElementById(id).classList.contains('active');} ,'modelLibraryScreen'),true,
     'and the credential screens must be reachable again — the guard is conditional, not a disable');
   }finally{await browser.close();}
  }
  // ---- 2. An endpoint's model list is data. -------------------------------------
  {
   const browser=await launch();done.push(browser);
   try{
    const ctx=await browser.newContext();
    await ctx.route('**/models*',route=>route.fulfill({status:200,contentType:'application/json',
     body:JSON.stringify({object:'list',data:[{id:HOSTILE_ID,object:'model'}]})}));
    const page=await newPage(ctx);
    await page.goto(origin+'/?full=1',{waitUntil:'domcontentloaded'});
    await booted(page);
    // Built through the app's own factory and its own Test connection button, so the value
    // arrives over a real fetch and is rendered by the real library code.
    const id=await page.evaluate(async()=>{
     const ui=game.ui;
     if(!ui._arenaConfig)ui._arenaConfig=await ui.loadArenaConfig();
     ui.showScreen('modelLibraryScreen');
     const m=ui.makeArenaModel({name:'probe',endpoint:'http://127.0.0.1:1/v1',model:''});
     m.provider='openai';m.auth={type:'bearer',key:'k'};
     ui._arenaConfig.models.push(m);ui.renderArenaLibrary();
     await ui.testArenaModel(m.id);
     return m.id;});
    const row=await page.evaluate(async(id)=>{
     game.ui.mdlShow(id);                                  // the app's own picker
     await new Promise(r=>setTimeout(r,200));
     const el=document.querySelector('#mdlPop-'+id+' .mdl-row');
     if(!el)return {found:false};
     el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));
     await new Promise(r=>setTimeout(r,50));
     return {found:true,dataV:el.getAttribute('data-v'),injected:el.getAttribute('onmouseover'),pwned:window.__warPwned};},id);
    assert.ok(row.found,'the picker should have listed the served model');
    assert.equal(row.injected,null,'a model id must not become an event handler; got '+JSON.stringify(row.injected));
    assert.equal(row.pwned,0,'an endpoint must not be able to run script in the page');
    assert.equal(row.dataV,HOSTILE_ID,'the id must survive verbatim AS data — escaping, not truncation');
   }finally{await browser.close();}
  }
  // ---- 3. A transcript someone hands you is data. --------------------------------
  // The analyzer's stated purpose is a match "recorded, downloaded, handed on, and opened
  // here", and on a hosted copy it is the only surface — so the file is the attack surface
  // by design and has to be treated as untrusted input.
  {
   const browser=await launch();done.push(browser);
   try{
    const hostile=path.join(out,'hostile.jsonl');
    fs.writeFileSync(hostile,[
     JSON.stringify({type:'match',matchId:'match-trust',simSpeed:`<img src="q" onerror="${H}">`,mapSeed:'s',promptVersion:'v'}),
     JSON.stringify({playerId:'greek',turn:HOSTILE_ROW,at:Date.now(),state:{clock:{matchSeconds:30}}}),
     JSON.stringify({type:'results',build:`<b onmouseover="${H}">x</b>`})].join('\n')+'\n');
    const page=await newPage(browser);
    const errors=[];page.on('pageerror',e=>errors.push(String(e.message).split('\n')[0]));
    await page.goto(origin+'/?full=1',{waitUntil:'domcontentloaded'});
    await booted(page);
    await page.evaluate(()=>game.ui.anOpen());
    await page.setInputFiles('#anFile',hostile);
    // Poll on a timer: the app owns a heavy rAF loop, and Playwright's default raf-polling
    // can starve long enough to time out on work that has plainly already happened. A
    // predicate that throws (reading .length off a field not created yet) also aborts the
    // wait instead of retrying, so every link in the chain is checked.
    let loaded=false;
    for(const attempt of [1,2]){
     try{await page.waitForFunction(parsed,null,{timeout:90000,polling:100});loaded=true;break;}
     catch(e){
      if(attempt===2)break;
      console.log('  (first selection did not parse — the sample index is still loading; re-selecting)');
      await page.setInputFiles('#anFile',hostile);
     }
    }
    if(!loaded){
     const why=await page.evaluate(()=>({analyzer:typeof game.ui.analyzer,
      body:document.body.innerText.slice(0,140)}));
     assert.fail('the hostile transcript never parsed: '+JSON.stringify(why)+' pageErrors: '+errors.join(' | '));
    }
    await page.waitForSelector('.tv-turn',{state:'attached',timeout:60000});
    const seen=await page.evaluate(()=>({
     metaChildren:[...document.getElementById('anMeta').children].map(c=>c.tagName).join(','),
     metaText:document.getElementById('anMeta').textContent,
     rowAttr:(document.querySelector('.tv-turn')||{getAttribute:()=>null}).getAttribute('onmouseover'),
     turns:game.ui.analyzer.order.length,pwned:window.__warPwned}));
    await page.hover('.tv-turn',{force:true}).catch(()=>{});
    await page.waitForTimeout(300);
    seen.pwnedAfterHover=await page.evaluate(()=>window.__warPwned);
    assert.equal(seen.turns,1,'the hostile file still has to PARSE — the fix is escaping, not rejecting data');
    assert.equal(seen.metaChildren,'','the header line must render as text, not elements; got <'+seen.metaChildren+'>');
    assert.match(seen.metaText,/×/,'the value must still be readable to a spectator: '+JSON.stringify(seen.metaText.slice(0,120)));
    assert.equal(seen.rowAttr,null,'a transcript turn number must not become an attribute; got '+JSON.stringify(seen.rowAttr));
    assert.equal(seen.pwned,0,'opening a file must not be able to run script');
    assert.equal(seen.pwnedAfterHover,0,'nor may interacting with what it rendered');
    assert.equal(errors.join(' | '),'','loading a minimal transcript must not throw: '+errors.join(' | '));
    await page.screenshot({path:path.join(out,'untrusted-transcript.png')});
   }finally{await browser.close();}
  }
  console.log('PASS: showcase gate (and its ?full=1 opt-out), endpoint model list, and untrusted transcript all stay data. Screenshots: '+out);
 }finally{
  // A thrown assertion skips its own close(), so sweep every browser launched this run.
  for(const b of done)await b.close().catch(()=>{});
  server.close();
 }
})();
