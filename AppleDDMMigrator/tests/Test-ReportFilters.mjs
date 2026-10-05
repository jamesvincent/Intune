// Executes the generated report's actual JavaScript with its rendered rows/buttons.
// Run: node tests/Test-ReportFilters.mjs samples/Apple-Results/Apple-DDM-Assessment.html
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html=fs.readFileSync(process.argv[2],'utf8');
const decode=s=>s.replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');
const attrs=s=>Object.fromEntries([...s.matchAll(/([\w-]+)="([^"]*)"/g)].map(m=>[m[1],decode(m[2])]));
function element(tag,a,text=''){
 return {tagName:tag,id:a.id,dataset:Object.fromEntries(Object.entries(a).filter(([k])=>k.startsWith('data-')).map(([k,v])=>[k.slice(5),v])),textContent:decode(text.replace(/<[^>]+>/g,'')),hidden:false,value:'',a,handlers:{},hasAttribute(k){return k in this.a},setAttribute(k,v){this.a[k]=v},addEventListener(k,fn){this.handlers[k]=fn},closest(){return this}};
}
const rows=[...html.matchAll(/<tr class="setting-row"([^>]*)>([\s\S]*?)<\/tr>/g)].map(m=>element('TR',attrs(m[1]),m[2]));
const buttons=[...html.matchAll(/<button([^>]*)>([\s\S]*?)<\/button>/g)].map(m=>element('BUTTON',attrs(m[1]),m[2]));
const ids={filter:element('INPUT',{}),'no-results':element('P',{}),'filter-state':element('P',{})};
const handlers={};
const document={getElementById:id=>ids[id],querySelectorAll:s=>s.startsWith('#settings-table')?rows:[...buttons,...rows],addEventListener:(k,fn)=>handlers[k]=fn};
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document});
const visible=()=>rows.filter(r=>!r.hidden),click=b=>handlers.click({target:b});
assert.equal(visible().length,rows.length);
click(buttons.find(b=>b.dataset.group==='candidates'));
assert.ok(visible().length>0);assert.ok(visible().every(r=>['DDM_DIRECT','DDM_SEMANTIC'].includes(r.dataset.status)));
const selected=visible()[0].dataset.profile;
click(buttons.find(b=>b.dataset.profile===selected));
assert.ok(visible().length>0);assert.ok(visible().every(r=>r.dataset.profile===selected));
const status=visible()[0].dataset.status;
click(buttons.find(b=>b.dataset.status===status));
assert.ok(visible().every(r=>r.dataset.status===status&&r.dataset.profile===selected));
ids.filter.value='not-a-real-setting-4b67';ids.filter.handlers.input();
assert.equal(visible().length,0);assert.equal(ids['no-results'].hidden,false);
click(buttons.find(b=>b.id==='clear-filters'));
assert.equal(visible().length,rows.length);assert.equal(ids.filter.value,'');
assert.equal(ids['no-results'].hidden,true);
click(buttons.find(b=>b.dataset.group==='review'));
assert.ok(visible().length>0);assert.ok(visible().every(r=>r.dataset.status==='REQUIRES_REVIEW'));
click(buttons.find(b=>b.id==='clear-filters'));
click(buttons.find(b=>b.dataset.status==='DDM_DIRECT'));
assert.ok(visible().length>0);assert.ok(visible().every(r=>r.dataset.status==='DDM_DIRECT'));
click(buttons.find(b=>b.dataset.status==='DDM_DIRECT'));
assert.equal(visible().length,rows.length);
console.log('PASS: generated report filters: summary, profile, classification, combined search, no matches, clear, toggle.');
