// There is no bundler and no module system: index.html is the module graph, by hand.
// A script file that exists but is not referenced fails at runtime with a ReferenceError
// from whichever file uses it, and a referenced file that does not exist fails the same
// way. Neither is caught by any other test here, because every other test loads the files
// it needs itself rather than through the page. This is the cheapest guard against the one
// failure mode a folder of classic <script> tags has.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.join(__dirname,'..');
const html=p=>fs.readFileSync(path.join(root,p),'utf8');
const SRC=/src="(js\/[^"]+?)(?:\?v=(\d+))?"/g;

const onDisk=[];
(function walk(dir){
 for(const e of fs.readdirSync(path.join(root,dir),{withFileTypes:true})){
  const rel=path.join(dir,e.name);
  if(e.isDirectory())walk(rel);
  else if(e.name.endsWith('.js'))onDisk.push(rel.split(path.sep).join('/'));
 }
})('js');

// engine-test.html is the standalone pipeline demo: it loads a subset of the engine by
// design and carries no cache-busting tags, because nobody ships it and nobody caches it.
// Only index.html is held to the full contract.
const PAGES=['index.html','engine-test.html'];

for(const page of PAGES){
 const refs=[...html(page).matchAll(SRC)].map(m=>({file:m[1],tag:m[2]}));

 test(`${page}: every referenced script exists`,()=>{
  assert.ok(refs.length>0,`${page} references no js/ file at all — did the src= pattern change?`);
  const missing=refs.map(r=>r.file).filter(f=>!fs.existsSync(path.join(root,f)));
  assert.deepEqual(missing,[],`${page} loads files that are not in the repo: ${missing.join(', ')}`);
 });

 if(page!=='index.html') continue;

 test('index.html: every script tag carries a cache-busting version',()=>{
  // A js file with no ?v= is cached by URL for as long as the browser holds it: the
  // user keeps running the previous build and every bug report against it is unreal.
  const untagged=refs.filter(r=>!r.tag).map(r=>r.file);
  assert.deepEqual(untagged,[],`cached with no way to invalidate them: ${untagged.join(', ')}`);
  for(const r of refs)
   assert.ok(Number(r.tag)>0,`${r.file} carries a nonsense version tag v=${r.tag}`);
 });

 test('index.html loads every shipped script exactly once',()=>{
  const names=refs.map(r=>r.file);
  const dupes=names.filter((f,i)=>names.indexOf(f)!==i);
  assert.deepEqual(dupes,[],'loaded twice means two copies of every global: '+dupes.join(', '));
  // A file on disk that nothing loads is dead code that still costs a clone, a review,
  // and an afternoon wondering why the new module never runs — in this architecture that
  // is a ReferenceError at the first call site, not a compile error.
  const orphaned=onDisk.filter(f=>!names.includes(f));
  assert.deepEqual(orphaned,[],`not referenced by index.html: ${orphaned.join(', ')}`);
 });

 test('the build number in the badge is the game.js tag, by the same rule as the app',()=>{
  // UIManager.buildVersion() reads exactly this tag. If the two derivations ever disagree,
  // the transcript header and the on-screen build stop meaning the same thing.
  const m=html('index.html').match(/src="js\/game\.js\?v=(\d+)"/);
  assert.ok(m,'index.html must reference js/game.js with a ?v= tag');
  assert.ok(Number(m[1])>0,'the build number should be a positive integer');
 });
}
