/* ═══ MULTIVERSE ═══ */

function showMvLoading(status){
  var o=document.getElementById('mvLoadingOverlay');
  o.style.display='flex';
  o.style.opacity='';
  o.style.transition='';
  updateMvLoading(status||'Initializing...',0);
}

function updateMvLoading(status,percent){
  var s=document.getElementById('mvLoadingStatus');
  var b=document.getElementById('mvLoadingBarFill');
  if(s)s.textContent=status;
  if(b)b.style.width=percent+'%';
}

function hideMvLoading(){
  var o=document.getElementById('mvLoadingOverlay');
  o.style.opacity='0';
  o.style.transition='opacity 0.4s ease';
  setTimeout(function(){
    o.style.display='none';
    o.style.opacity='';
    o.style.transition='';
  },400);
}

function setMvView(mode){
  // Save current model's UI state before switching
  if(currentMvView && currentMvView!=='ab'){
    mvState[currentMvView]={vis:{},isoCats:ISO_CATS?JSON.parse(JSON.stringify(ISO_CATS)):null,fiso:FISO,openCats:JSON.parse(JSON.stringify(openCats)),openSubs:JSON.parse(JSON.stringify(openSubs)),asmvis:JSON.parse(JSON.stringify(ASMVIS))};
    for(var k in VIS)if(VIS.hasOwnProperty(k))mvState[currentMvView].vis[k]=VIS[k];
  } else if(currentMvView==='ab'){
    // Save split panel visibility into per-model mvState
    if(!mvState['a'])mvState['a']={vis:{},isoCats:null,fiso:false,openCats:{},openSubs:{},asmvis:{}};
    if(!mvState['b'])mvState['b']={vis:{},isoCats:null,fiso:false,openCats:{},openSubs:{},asmvis:{}};
    for(var k in splitVis.a)if(splitVis.a.hasOwnProperty(k))mvState['a'].vis[k]=splitVis.a[k];
    for(var k in splitVis.b)if(splitVis.b.hasOwnProperty(k))mvState['b'].vis[k]=splitVis.b[k];
  }
  // Restore target model's state (or initialize fresh)
  if(mode!=='ab' && mvState[mode]){
    var s=mvState[mode];VIS={};for(var k in s.vis)if(s.vis.hasOwnProperty(k))VIS[k]=s.vis[k];
    ISO_CATS=s.isoCats;FISO=s.fiso;openCats=JSON.parse(JSON.stringify(s.openCats));openSubs=JSON.parse(JSON.stringify(s.openSubs));ASMVIS=JSON.parse(JSON.stringify(s.asmvis||{}));
  } else {
    if(ISO_CATS){call('clearIsolation');}
    VIS={};ISO_CATS=null;FISO=false;containerIsolate=null;openCats={};openSubs={};ASMVIS={};
  }
  currentMvView=mode;
  pendingVisReapply=true;
  updateFisoBtn();
  // Reset split-only state when leaving A+B
  if(mode!=='ab'){
    matchedFilterActive=false;matchedCats=null;
    splitContainerIsolate={a:null,b:null};
    var mbtn=document.getElementById('mvMatchedToggle');
    if(mbtn)mbtn.classList.remove('active');
  }
  // Toggle split mode
  if(mode==='ab'){enterSplitMode();}else{exitSplitMode();}
  document.querySelectorAll('.mv-btn').forEach(function(b){
    b.classList.toggle('active',b.dataset.view===mode);
  });
  var lbl=document.getElementById('mvLabel');
  if(mode==='a') lbl.textContent='Model A: '+mvModelA;
  else if(mode==='b') lbl.textContent='Model B: '+mvModelB;
  else lbl.textContent='Comparing A + B';
  // Compare + Graph hidden for release
  // var cmpBtn=document.getElementById('mvCompareBtn');
  // if(cmpBtn)cmpBtn.style.display=(mode==='ab')?'inline-block':'none';
  // var gBtn=document.getElementById('mvGraphBtn');
  // if(gBtn)gBtn.style.display=(mode==='ab')?'inline-block':'none';
  // Clear diff state when leaving A+B
  if(mode!=='ab'){
    diffActive=false;diffComputed=false;comparisonResults=null;
    graphCats={};closeGraph();
    var dt=document.getElementById('mvDiffToggle');if(dt)dt.style.display='none';
    document.getElementById('compResults').classList.remove('active');
    call('clearCompareHighlights');
    // Clear smart diff UI (Ruby-side exit handled by setMultiverseView)
    onSmartDiffRemoved();
  }
  call('setMultiverseView',mode);
}
/* Update MV button styling + exit split mode without triggering Ruby callback.
   Called from Ruby after accept_compare switches to view 'a'. */
function setMvViewUI(mode){
  currentMvView=mode;
  document.querySelectorAll('.mv-btn').forEach(function(b){
    b.classList.toggle('active',b.dataset.view===mode);
  });
  var lbl=document.getElementById('mvLabel');
  if(mode==='a') lbl.textContent='Model A: '+mvModelA;
  else if(mode==='b') lbl.textContent='Model B: '+mvModelB;
  else lbl.textContent='Comparing A + B';
  if(mode==='ab'){enterSplitMode();}else{exitSplitMode();}
}

/* Re-apply saved VIS state to Ruby after mode switch (Ruby resets all visible) */
function reapplyVisToRuby(){
  var hideIds=[];
  for(var i=0;i<D.length;i++){
    if(VIS[D[i].entityId]===false) hideIds.push(D[i].entityId);
  }
  if(hideIds.length) call('hideEntities',hideIds.join(','));
}
/* Apply saved A/B visibility states into split panels after entering AB mode */
function applySavedVisToSplit(){
  var hideIds=[];
  if(mvState['a']&&mvState['a'].vis){
    var saved=mvState['a'].vis;
    for(var k in saved){if(saved.hasOwnProperty(k)&&saved[k]===false){splitVis.a[k]=false;hideIds.push(k);}}
  }
  if(mvState['b']&&mvState['b'].vis){
    var saved=mvState['b'].vis;
    for(var k in saved){if(saved.hasOwnProperty(k)&&saved[k]===false){splitVis.b[k]=false;hideIds.push(k);}}
  }
  if(hideIds.length) call('hideEntities',hideIds.join(','));
}

function receiveMultiverseData(data){
  var d=typeof data==='string'?JSON.parse(data):data;
  var bar=document.getElementById('mvBar');
  var empty=document.getElementById('mvEmpty');
  var active=document.getElementById('mvActive');
  var nsEl=document.getElementById('mvNeedsScan');
  var sdPanel=document.getElementById('smartDiffPanel');
  if(d.models&&d.models.length>1){
    currentMvView=d.activeView||'a';
    bar.style.display='flex';
    empty.style.display='none';
    active.style.display='block';
    if(nsEl) nsEl.style.display=d.needsScan?'flex':'none';
    if(sdPanel) sdPanel.style.display='block';
    mvModelA=d.models[0].name;
    mvModelB=d.models[1].name;
    document.querySelectorAll('.mv-btn').forEach(function(b){
      b.classList.toggle('active',b.dataset.view===currentMvView);
    });
    renderMvModels(d.models);
    renderMvComparison(d.comparison||[]);
    renderCommitLog(d.commitLog||[]);
    call('getTemplateList');
    var diff=0;(d.comparison||[]).forEach(function(c){diff+=c.diff;});
    document.getElementById('mvSummary').textContent=(diff>=0?'+':'')+diff+' items';
    var lbl=document.getElementById('mvLabel');
    if(currentMvView==='a') lbl.textContent='Model A: '+mvModelA;
    else if(currentMvView==='b') lbl.textContent='Model B: '+mvModelB;
    else lbl.textContent='Comparing A + B';
    // Activate split mode if loaded into ab view
    if(currentMvView==='ab'){
      enterSplitMode();
      // Data may already be loaded — populate split panels from D
      if(D.length>0){
        splitData.a.rows=[];splitData.b.rows=[];
        for(var si=0;si<D.length;si++){
          if(D[si].category==='_IGNORE')continue;
          if(D[si].modelSource==='model_a')splitData.a.rows.push(D[si]);
          else splitData.b.rows.push(D[si]);
        }
        buildSplitCatDD('a');buildSplitCatDD('b');
        renderSplitPanels();
      }
    } else exitSplitMode();
  } else {
    currentMvView=null;
    mvState={};
    exitSplitMode();
    bar.style.display='none';
    active.style.display='none';
    if(nsEl) nsEl.style.display='none';
    if(sdPanel) sdPanel.style.display='none';
    // Show commit log even when multiverse is inactive
    var cl=d.commitLog||[];
    if(cl.length>0){
      empty.style.display='none';
      active.style.display='block';
      renderCommitLog(cl);
    } else {
      empty.style.display='flex';
    }
  }
  heartbeatOff();
}

function renderMvModels(models){
  var c=document.getElementById('mvModels');
  var h='';
  for(var i=0;i<models.length;i++){
    var m=models[i];
    var color=i===0?'#a6e3a1':'#89b4fa';
    var label=i===0?'A':'B';
    h+='<div class="mv-model-row">';
    h+='<div class="mv-dot" style="background:'+color+'"></div>';
    h+='<span class="mv-model-label">Model '+label+'</span>';
    h+='<span class="mv-model-name">'+X(m.name||'Unknown')+'</span>';
    h+='</div>';
  }
  c.innerHTML=h;
}

function renderCommitLog(log){
  var el=document.getElementById('mvCommitLog');
  var countEl=document.getElementById('mvCommitCount');
  if(!el)return;
  if(!log||!log.length){
    el.innerHTML='<div style="color:#6c7086;font-size:11px;padding:6px">No items committed yet.</div>';
    if(countEl)countEl.textContent='';
    return;
  }
  var total=0;
  for(var i=0;i<log.length;i++)total+=log[i].items.length;
  if(countEl)countEl.textContent='('+total+' items)';
  var h='';
  for(var i=0;i<log.length;i++){
    var g=log[i];
    h+='<div style="margin-bottom:6px;border:1px solid #313244;border-radius:6px;padding:6px 8px;background:#181825">';
    h+='<div style="display:flex;align-items:center;gap:6px;margin-bottom:4px">';
    var isFF=g.category.indexOf('FF Import')===0;
    h+='<span class="src-badge '+(isFF?'':' b')+'" style="'+(isFF?'background:#a6e3a1;color:#1e1e2e':'')+'">'+( isFF?'FF':'B')+'</span>';
    h+='<span style="font-size:11px;font-weight:600;color:#cdd6f4">'+X(g.category)+'</span>';
    h+='<span style="font-size:10px;color:#6c7086;margin-left:auto">'+X(g.date)+'</span>';
    h+='</div>';
    h+='<div style="display:flex;flex-wrap:wrap;gap:3px">';
    var max=g.items.length>12?12:g.items.length;
    for(var j=0;j<max;j++){
      var it=g.items[j];
      var tc=it.type==='modified'?'#f9e2af':it.type==='measurement'?'#a6e3a1':'#89b4fa';
      h+='<span style="font-size:9px;padding:1px 5px;border-radius:3px;background:rgba(137,180,250,.08);color:'+tc+';border:1px solid rgba(137,180,250,.15);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:140px" title="'+X(it.name)+'">'+X(it.name.length>18?it.name.substring(0,18)+'…':it.name)+'</span>';
    }
    if(g.items.length>12)h+='<span style="font-size:9px;color:#6c7086;padding:1px 4px">+'+(g.items.length-12)+' more</span>';
    h+='</div></div>';
  }
  el.innerHTML=h;
}

function renderMvComparison(comparison){
  var c=document.getElementById('mvComparisonList');
  if(!comparison||!comparison.length){
    c.innerHTML='<div style="color:#6c7086;font-size:11px;padding:8px">No comparison data yet.</div>';
    return;
  }
  var h='';
  var totalA=0,totalB=0,totalDiff=0;
  for(var i=0;i<comparison.length;i++){
    var r=comparison[i];
    totalA+=r.countA;totalB+=r.countB;totalDiff+=r.diff;
    var cls=r.diff>0?'mv-gained':(r.diff<0?'mv-lost':'mv-same');
    var sign=r.diff>0?'+':'';
    h+='<div class="mv-comp-row">';
    h+='<span class="mv-comp-cat">'+X(r.category)+'</span>';
    h+='<span class="mv-comp-a">'+r.countA+'</span>';
    h+='<span class="mv-comp-b">'+r.countB+'</span>';
    h+='<span class="mv-comp-diff '+cls+'">'+sign+r.diff+'</span>';
    h+='</div>';
  }
  // Total row
  var tCls=totalDiff>0?'mv-gained':(totalDiff<0?'mv-lost':'mv-same');
  var tSign=totalDiff>0?'+':'';
  h+='<div class="mv-comp-row mv-comp-total">';
  h+='<span class="mv-comp-cat">Total</span>';
  h+='<span class="mv-comp-a">'+totalA+'</span>';
  h+='<span class="mv-comp-b">'+totalB+'</span>';
  h+='<span class="mv-comp-diff '+tCls+'">'+tSign+totalDiff+'</span>';
  h+='</div>';
  c.innerHTML=h;
}

function confirmRemoveMv(){
  showPortalConfirm('Remove Model B','Remove comparison model? All Model B entities will be deleted.',function(){
    call('removeComparisonModel');
  });
}

function scanBWithTemplate(){
  var sel=document.getElementById('mvTplSelectScan');
  var tpl=sel?sel.value:'';
  if(tpl) call('rescanModelBWithTemplate',tpl);
  else call('rescanModelB');
}

function rescanBWithTemplate(){
  var sel=document.getElementById('mvTplSelect');
  var tpl=sel?sel.value:'';
  if(tpl) call('rescanModelBWithTemplate',tpl);
  else call('rescanModelB');
}

function receiveTemplateList(data){
  var d=typeof data==='string'?JSON.parse(data):data;
  var templates=d.templates||[];
  var current=d.current||'';
  var selScan=document.getElementById('mvTplSelectScan');
  var selMgmt=document.getElementById('mvTplSelect');
  if(selScan){
    var h='<option value="">No template</option>';
    for(var i=0;i<templates.length;i++){
      var sel=templates[i]===current?' selected':'';
      h+='<option value="'+templates[i]+'"'+sel+'>'+templates[i]+'</option>';
    }
    selScan.innerHTML=h;
  }
  if(selMgmt){
    var h2='<option value="">None (use Model A categories)</option>';
    for(var j=0;j<templates.length;j++){
      var sel2=templates[j]===current?' selected':'';
      h2+='<option value="'+templates[j]+'"'+sel2+'>'+templates[j]+'</option>';
    }
    selMgmt.innerHTML=h2;
  }
}

/* ═══ SMART DIFF ═══ */
var SD_COLORS={a:'#f38ba8',b:'#89b4fa'};
var SD_LABELS={a:'Model A',b:'Model B'};
var SD_OPACITY={a:70,b:70};
var SD_VIS={a:true,b:true};

function populateSDCatFilter(){
  var sel=document.getElementById('sdCatFilter');
  if(!sel)return;
  var cats={};
  for(var i=0;i<D.length;i++){
    var c=D[i].category;
    if(c&&c!=='_IGNORE'&&c!=='Uncategorized')cats[c]=true;
  }
  var sorted=Object.keys(cats).sort();
  var h='<option value="">All Categories</option>';
  /* Add containers as optgroups */
  var contCats={};
  for(var ci=0;ci<CONTAINERS.length;ci++){
    contCats[CONTAINERS[ci].name]=[];
  }
  for(var si=0;si<sorted.length;si++){
    var info=CAT_TO_CONT[sorted[si]];
    var cn=info?info.name:'Other';
    if(!contCats[cn])contCats[cn]=[];
    contCats[cn].push(sorted[si]);
  }
  for(var cn2 in contCats){
    if(!contCats.hasOwnProperty(cn2)||contCats[cn2].length===0)continue;
    h+='<optgroup label="'+X(cn2)+'">';
    h+='<option value="__cont__'+X2(cn2)+'" style="font-weight:700;color:#cba6f7;">'+X(cn2)+' (all)</option>';
    for(var k=0;k<contCats[cn2].length;k++){
      h+='<option value="'+X2(contCats[cn2][k])+'">'+X(contCats[cn2][k])+'</option>';
    }
    h+='</optgroup>';
  }
  sel.innerHTML=h;
}

function getSDCatFilter(){
  var sel=document.getElementById('sdCatFilter');
  if(!sel||!sel.value)return null;
  var v=sel.value;
  if(v.indexOf('__cont__')===0){
    /* Container selected — return all cats in it */
    var cn=v.substring(8);
    var cats=[];
    for(var c in CAT_TO_CONT){
      if(CAT_TO_CONT.hasOwnProperty(c)&&CAT_TO_CONT[c].name===cn) cats.push(c);
    }
    return cats;
  }
  return [v];
}

function applySmartDiffCatFilter(){
  var cats=getSDCatFilter();
  callJSON('smartDiffFilterCategory',{categories:cats});
}

function sdIsolateWithCat(key){
  var cats=getSDCatFilter();
  callJSON('smartDiffIsolateWithCat',{state:key,categories:cats});
}

function sdShowAllWithCat(){
  var cats=getSDCatFilter();
  SD_VIS={a:true,b:true};
  callJSON('smartDiffShowAllWithCat',{categories:cats});
}

function onSmartDiffComplete(counts){
  hideLoading();
  populateSDCatFilter();
  document.getElementById('sdResults').style.display='block';
  // Enter analysis mode — swap A/A+B/B for Exit button
  document.getElementById('mvToggle').style.display='none';
  document.getElementById('mvExitAnalysis').style.display='inline-block';
  var cmpBtn=document.getElementById('mvCompareBtn');if(cmpBtn)cmpBtn.style.display='none';
  var dt=document.getElementById('mvDiffToggle');if(dt)dt.style.display='none';
  var lbl=document.getElementById('mvLabel');if(lbl)lbl.textContent='Smart Diff Analysis';
  var h='';
  var models=['a','b'];
  for(var i=0;i<models.length;i++){
    var k=models[i];
    var cnt=counts[k]||0;
    var vis=SD_VIS[k];
    var op=SD_OPACITY[k];
    h+='<div style="display:flex;align-items:center;gap:8px;padding:4px 0;border-bottom:1px solid #313244;">';
    h+='<button class="ey'+(vis?'':' off')+'" onclick="toggleSDVis(\''+k+'\')" style="flex-shrink:0;" title="'+(vis?'Hide':'Show')+'">'+(vis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
    h+='<span style="width:10px;height:10px;border-radius:50%;background:'+SD_COLORS[k]+';flex-shrink:0;"></span>';
    h+='<span style="color:'+SD_COLORS[k]+';font-size:12px;font-weight:600;min-width:100px;">'+SD_LABELS[k]+'</span>';
    h+='<span style="color:#a6adc8;font-size:11px;min-width:40px;">'+cnt+'</span>';
    h+='<input type="range" min="0" max="100" value="'+op+'" oninput="setSDOpacity(\''+k+'\',this.value)" style="flex:1;accent-color:'+SD_COLORS[k]+';">';
    h+='<span id="sdOp_'+k+'" style="color:#6c7086;font-size:10px;min-width:30px;">'+op+'%</span>';
    h+='</div>';
  }
  document.getElementById('sdRows').innerHTML=h;
}

function toggleSDVis(key){
  SD_VIS[key]=!SD_VIS[key];
  var cats=getSDCatFilter();
  callJSON('setSmartDiffVisibility',{state:key,visible:SD_VIS[key],categories:cats});
}

function setSDOpacity(key,val){
  val=parseInt(val);
  SD_OPACITY[key]=val;
  var el=document.getElementById('sdOp_'+key);
  if(el) el.textContent=val+'%';
  var cats=getSDCatFilter();
  callJSON('setSmartDiffOpacity',{state:key,value:val/100.0,categories:cats});
}

function onSmartDiffVisUpdate(vis){
  SD_VIS=vis;
  var models=['a','b'];
  for(var i=0;i<models.length;i++){
    var k=models[i];
    var rows=document.querySelectorAll('#sdRows .ey');
    if(rows[i]){
      if(SD_VIS[k]){rows[i].classList.remove('off');rows[i].innerHTML=ICO_EYE_OPEN;}
      else{rows[i].classList.add('off');rows[i].innerHTML=ICO_EYE_CLOSED;}
    }
  }
}

function onSmartDiffRemoved(){
  document.getElementById('sdResults').style.display='none';
  SD_VIS={a:true,b:true};
  SD_OPACITY={a:70,b:70};
  // Restore normal controls
  document.getElementById('mvToggle').style.display='';
  document.getElementById('mvExitAnalysis').style.display='none';
}

function exitAnalysisMode(){
  // Clear stale visibility so Model A starts fresh (no SmartDiff leftovers)
  mvState['a']=null;
  splitVis={a:{},b:{}};
  setMvView('a');
}

/* ═══ SPLIT VERTICAL DASHBOARD ═══ */
function enterSplitMode(){
  if(splitMode)return;
  splitMode=true;
  splitIsolateState={a:null,b:null};
  splitContainerIsolate={a:null,b:null};
  var fbar=document.querySelector('.fbar');
  var fbar2=document.getElementById('fbar2');
  var catBar=document.querySelector('.cat-bar');
  var dpWrap=document.getElementById('dpWrap');
  var sc=document.getElementById('splitContainer');
  var mmt=document.getElementById('mvMatchedToggle');
  if(fbar)fbar.style.display='none';
  if(fbar2)fbar2.style.display='none';
  if(catBar)catBar.style.display='none';
  if(dpWrap)dpWrap.style.display='none';
  if(sc)sc.style.display='flex';
  if(mmt)mmt.style.display='';
  // var gBtn=document.getElementById('mvGraphBtn');if(gBtn)gBtn.style.display='inline-block'; // hidden for release
  // Populate panel headers
  document.getElementById('panelAName').textContent=mvModelA||'';
  document.getElementById('panelBName').textContent=mvModelB||'';
}
function exitSplitMode(){
  if(!splitMode)return;
  splitMode=false;
  if(comparisonResults)clearCompareUI();
  var fbar=document.querySelector('.fbar');
  var catBar=document.querySelector('.cat-bar');
  var dpWrap=document.getElementById('dpWrap');
  var sc=document.getElementById('splitContainer');
  var mmt=document.getElementById('mvMatchedToggle');
  if(mmt)mmt.style.display='none';
  if(fbar)fbar.style.display='';
  if(catBar)catBar.style.display='';
  if(dpWrap)dpWrap.style.display='';
  if(sc)sc.style.display='none';
}
function buildSplitCatDD(panel){
  var rows=splitData[panel].rows;
  var cats={},i;
  for(i=0;i<rows.length;i++){
    var c=rows[i].category||'Uncategorized';
    if(c!=='_IGNORE')cats[c]=true;
  }
  var sel=document.getElementById('splitCat'+panel.toUpperCase());
  if(!sel)return;
  var cur=sel.value;
  var h='<option value="">All</option>';
  if(CONTAINERS&&CONTAINERS.length>0){
    for(var ci=0;ci<CONTAINERS.length;ci++){
      var cont=CONTAINERS[ci];if(!cont.categories||!cont.categories.length)continue;
      var inCont=cont.categories.filter(function(c){return cats[c.name];}).sort(function(a,b){return a.name.toLowerCase().localeCompare(b.name.toLowerCase());});
      if(!inCont.length)continue;
      h+='<optgroup label="'+X(cont.name)+'">';
      for(var j=0;j<inCont.length;j++)h+='<option value="'+X2(inCont[j].name)+'">'+X(inCont[j].name)+'</option>';
      h+='</optgroup>';
    }
    // Any categories not in containers
    var contCatSet={};
    for(var ci2=0;ci2<CONTAINERS.length;ci2++){(CONTAINERS[ci2].categories||[]).forEach(function(c){contCatSet[c.name]=true;});}
    var orphans=Object.keys(cats).filter(function(c){return !contCatSet[c];}).sort();
    if(orphans.length){h+='<optgroup label="Other">';for(i=0;i<orphans.length;i++)h+='<option value="'+X2(orphans[i])+'">'+X(orphans[i])+'</option>';h+='</optgroup>';}
  }else{
    var sorted=Object.keys(cats).sort();
    for(i=0;i<sorted.length;i++)h+='<option value="'+X2(sorted[i])+'">'+X(sorted[i])+'</option>';
  }
  sel.innerHTML=h;
  sel.value=cur;
}
function renderSplitPanels(){
  /* Compute matched categories for filter */
  if(matchedFilterActive){
    var catsA={},catsB={};
    for(var i=0;i<splitData.a.rows.length;i++){var c=splitData.a.rows[i].category;if(c&&c!=='_IGNORE')catsA[c]=true;}
    for(var i=0;i<splitData.b.rows.length;i++){var c=splitData.b.rows[i].category;if(c&&c!=='_IGNORE')catsB[c]=true;}
    matchedCats={};
    for(var k in catsA){if(catsA.hasOwnProperty(k)&&catsB[k])matchedCats[k]=true;}
  }else{matchedCats=null;}
  renderSplitPanel('a');
  renderSplitPanel('b');
  document.getElementById('panelAName').textContent=mvModelA||'';
  document.getElementById('panelBName').textContent=mvModelB||'';
  document.getElementById('panelACount').textContent=splitData.a.rows.length+' items';
  document.getElementById('panelBCount').textContent=splitData.b.rows.length+' items';
  updateMatchedCount();
}
function renderSplitPanel(panel){
  var rows=splitData[panel].rows;
  var searchEl=document.getElementById('splitSearch'+panel.toUpperCase());
  var catEl=document.getElementById('splitCat'+panel.toUpperCase());
  var search=searchEl?searchEl.value.toLowerCase():'';
  var catFilter=catEl?catEl.value:'';
  var vis=splitVis[panel];
  var oc=splitOpenCats[panel];
  // Filter
  var filtered=[],i,r;
  for(i=0;i<rows.length;i++){
    r=rows[i];
    if(r.category==='_IGNORE')continue;
    if(catFilter&&r.category!==catFilter)continue;
    if(search){
      var x=((r.definitionName||'')+' '+(r.category||'')+' '+(r.subcategory||'')+' '+(r.material||'')).toLowerCase();
      if(x.indexOf(search)===-1)continue;
    }
    filtered.push(r);
  }
  splitData[panel].filtered=filtered;
  // Group by category
  var groups={},order=[];
  for(i=0;i<filtered.length;i++){
    var cat=filtered[i].category||'Uncategorized';
    if(!groups[cat]){groups[cat]=[];order.push(cat);}
    groups[cat].push(filtered[i]);
  }
  order.sort();
  // Render helper for one category in split panel
  function renderSplitCat(gk,items){
    var catH='';
    var isOpen2=!!oc[gk];
    var catVis2=false;
    for(var ci2=0;ci2<items.length;ci2++){if(vis[items[ci2].entityId]!==false){catVis2=true;break;}}
    catH+='<div class="cg'+(isOpen2?' open':'')+'">';
    catH+='<div class="cgh'+(isOpen2?'':' closed')+'" onclick="togSplitCat(\''+panel+'\',\''+X2(gk)+'\')">';
    catH+='<button class="ey'+(catVis2?'':' off')+'" onclick="event.stopPropagation();togSplitCatVis(\''+panel+'\',\''+X2(gk)+'\')">'+(catVis2?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
    var isIso2=(splitIsolateState[panel]===gk);
    catH+='<button class="split-iso-btn'+(isIso2?' iso-active':'')+'" data-cat="'+X2(gk)+'" onclick="event.stopPropagation();isolateSplitCat(\''+X2(gk)+'\',\''+panel+'\')" title="Isolate">&#8857;</button>';
    if(panel==='b'){catH+='<button class="split-commit-btn" onclick="event.stopPropagation();commitCategory(\''+X2(gk)+'\')" title="Commit to Model A">&#8599;</button>';}
    // hidden for release: apple graph selector
    // var isAppled=!!graphCats[gk];
    // catH+='<button class="apple-btn'+(isAppled?' sel':'')+'" onclick="event.stopPropagation();toggleGraphCat(\''+X2(gk)+'\')" title="Select for graph comparison">&#127822;</button>';
    catH+='<span class="arr">&#9660;</span>';
    catH+=catNameSpan(gk);
    catH+='<span style="color:#6c7086;font-size:10px">('+items.length+')</span>';
    catH+='<span class="cinfo">'+items.length+' EA</span>';
    catH+=catSrcBadge(items);
    catH+='</div>';
    catH+='<div class="cgb">';
    if(isOpen2){
      for(var si=0;si<items.length;si++){
        var sr=items[si];
        var rv2=vis[sr.entityId]!==false;
        var qty2=splitFmtQty(sr);
        catH+='<div class="sp-row">';
        catH+='<button class="ey'+(rv2?'':' off')+'" onclick="togSplitItemVis(\''+panel+'\','+sr.entityId+')">'+(rv2?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
        catH+='<span class="sp-name" title="'+X(sr.definitionName||'')+'">'+X(T(sr.definitionName||'',40))+'</span>';
        catH+='<span class="sp-qty">'+qty2+'</span>';
        catH+='</div>';
      }
    }
    catH+='</div></div>';
    return catH;
  }
  // Render with containers or flat
  var h='';
  if(CONTAINERS.length>0){
    /* Build container→categories map via keyword matching */
    var spBuckets={};
    for(i=0;i<order.length;i++){
      var spCatKey=order[i];
      if(spCatKey==='_IGNORE')continue;
      var spInfo=CAT_TO_CONT[spCatKey]||{name:'Other',color:'#6c7086',order:999};
      var spBn=spInfo.name;
      if(!spBuckets[spBn])spBuckets[spBn]={name:spInfo.name,color:spInfo.color,order:spInfo.order,cats:[]};
      spBuckets[spBn].cats.push(spCatKey);
    }
    /* Ensure ALL master containers appear, even empty ones */
    for(var spci=0;spci<CONTAINERS.length;spci++){
      var spCn=CONTAINERS[spci];
      if(!spBuckets[spCn.name]){
        spBuckets[spCn.name]={name:spCn.name,color:spCn.color,order:typeof spCn.order==='number'?spCn.order:998,cats:[]};
      }
    }
    var spContMap=[];
    for(var spBk in spBuckets){if(spBuckets.hasOwnProperty(spBk))spContMap.push(spBuckets[spBk]);}
    spContMap.sort(function(a,b){return a.order-b.order;});
    /* Apply matched filter — remove unmatched categories from container maps */
    if(matchedCats){
      for(var mfi=0;mfi<spContMap.length;mfi++){
        spContMap[mfi].cats=spContMap[mfi].cats.filter(function(c){return !!matchedCats[c];});
      }
    }
    var soc=splitOpenConts[panel];
    for(var sci3=0;sci3<spContMap.length;sci3++){
      var scm=spContMap[sci3];
      if(matchedCats&&scm.cats.length===0)continue; /* skip empty containers when filtering */
      var sContOpen=soc[scm.name]!==false;
      var sTotalCnt=0;
      for(var ski=0;ski<scm.cats.length;ski++)sTotalCnt+=(groups[scm.cats[ski]]||[]).length;
      /* Container visibility */
      var sContVis=false;
      for(var ski2=0;ski2<scm.cats.length;ski2++){
        var sitems=groups[scm.cats[ski2]]||[];
        for(var svi2=0;svi2<sitems.length;svi2++){if(vis[sitems[svi2].entityId]!==false){sContVis=true;break;}}
        if(sContVis)break;
      }
      if(sTotalCnt===0)sContVis=true;
      var sContIso=(splitContainerIsolate[panel]===scm.name);
      h+='<div class="sp-cont'+(sContOpen?' open':'')+'">';
      h+='<div class="sp-cont-hdr" onclick="togSplitCont(\''+panel+'\',\''+X2(scm.name)+'\')">';
      h+='<button class="ey'+(sContVis?'':' off')+'" onclick="event.stopPropagation();togSplitContVis(\''+panel+'\',\''+X2(scm.name)+'\')">'+(sContVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
      h+='<button class="sp-cont-iso'+(sContIso?' iso-active':'')+'" onclick="event.stopPropagation();isoSplitCont(\''+panel+'\',\''+X2(scm.name)+'\')" title="Isolate container">&#8857;</button>';
      h+='<span class="sp-cont-badge" style="--cc:'+scm.color+'">'+X(scm.name)+'</span>';
      h+='<span class="arr">&#9660;</span>';
      h+='<span class="sp-cont-cnt">('+sTotalCnt+')</span>';
      h+='</div>';
      h+='<div class="sp-cont-body">';
      if(sContOpen){
        for(var ski3=0;ski3<scm.cats.length;ski3++){
          h+=renderSplitCat(scm.cats[ski3],groups[scm.cats[ski3]]||[]);
        }
      }
      h+='</div></div>';
    }
  } else {
    for(var gi=0;gi<order.length;gi++){
      if(matchedCats&&!matchedCats[order[gi]])continue;
      h+=renderSplitCat(order[gi],groups[order[gi]]);
    }
  }
  var target=document.getElementById('catList'+panel.toUpperCase());
  if(target)target.innerHTML=h||'<div style="padding:12px;color:#6c7086;font-size:11px;font-style:italic">No items</div>';
}
function splitFmtQty(r){
  var mt=r.measurementType||'volume';
  if(mt==='ea'||mt==='ea_bf'||mt==='ea_sf')return 1+uLabel(mt);
  if(mt==='lf')return ((r.linearFt||0)).toFixed(1)+uLabel(mt);
  if(mt==='sf'||mt==='sf_cy'||mt==='sf_sheets')return (r.areaSF||0).toFixed(1)+uLabel(mt);
  return (r.volumeFt3||0).toFixed(2)+uLabel(mt);
}
function filterSplitPanel(panel){
  renderSplitPanel(panel);
}
function togSplitCont(panel,name){splitOpenConts[panel][name]=(splitOpenConts[panel][name]===false);renderSplitPanel(panel);}
function togSplitContVis(panel,contName){
  var catSet=getContainerCats(contName);
  var rows2=splitData[panel].rows;
  var vis2=splitVis[panel];
  var anyVis2=false,ids2=[];
  for(var i2=0;i2<rows2.length;i2++){
    if(rows2[i2].category&&catSet[rows2[i2].category]){
      ids2.push(rows2[i2].entityId);
      if(vis2[rows2[i2].entityId]!==false)anyVis2=true;
    }
  }
  for(var j2=0;j2<ids2.length;j2++)vis2[ids2[j2]]=!anyVis2;
  if(ids2.length)call(anyVis2?'hideEntities':'showEntities',ids2.join(','));
  renderSplitPanel(panel);
}
function isoSplitCont(panel,contName){
  var modelId=(panel==='b')?'model_b':'model_a';
  if(splitContainerIsolate[panel]===contName){
    /* Un-isolate — show all */
    splitContainerIsolate[panel]=null;
    splitIsolateState[panel]=null;
    var vis3=splitVis[panel];
    var rows3=splitData[panel].rows;
    for(var i3=0;i3<rows3.length;i3++)vis3[rows3[i3].entityId]=true;
    call('showAllForModel',modelId);
  }else{
    /* Isolate this container */
    splitContainerIsolate[panel]=contName;
    splitIsolateState[panel]=null;
    var catSet3=getContainerCats(contName);
    var vis3=splitVis[panel];
    var rows3=splitData[panel].rows;
    var showIds=[],hideIds=[];
    for(var i3=0;i3<rows3.length;i3++){
      var inCont=!!(rows3[i3].category&&catSet3[rows3[i3].category]);
      vis3[rows3[i3].entityId]=inCont;
      if(inCont)showIds.push(rows3[i3].entityId);
      else hideIds.push(rows3[i3].entityId);
    }
    if(hideIds.length)call('hideEntities',hideIds.join(','));
    if(showIds.length)call('showEntities',showIds.join(','));
  }
  renderSplitPanel(panel);
}
function togSplitCat(panel,cat){
  splitOpenCats[panel][cat]=!splitOpenCats[panel][cat];
  renderSplitPanel(panel);
}
function togSplitCatVis(panel,cat){
  var rows=splitData[panel].rows;
  var vis=splitVis[panel];
  var anyVis=false,ids=[];
  for(var i=0;i<rows.length;i++){
    if(rows[i].category===cat){ids.push(rows[i].entityId);if(vis[rows[i].entityId]!==false)anyVis=true;}
  }
  for(var j=0;j<ids.length;j++)vis[ids[j]]=!anyVis;
  if(ids.length)call(anyVis?'hideEntities':'showEntities',ids.join(','));
  renderSplitPanel(panel);
}
function togSplitItemVis(panel,eid){
  var vis=splitVis[panel];
  var cur=vis[eid]!==false;
  vis[eid]=!cur;
  call(cur?'hideEntities':'showEntities',''+eid);
  renderSplitPanel(panel);
}
function isolateSplitCat(cat,panel){
  var modelId=(panel==='b')?'model_b':'model_a';
  splitContainerIsolate[panel]=null;
  if(splitIsolateState[panel]===cat){
    splitIsolateState[panel]=null;
    var vis=splitVis[panel];
    var rows=splitData[panel].rows;
    for(var i=0;i<rows.length;i++)vis[rows[i].entityId]=true;
    call('showAllForModel',modelId);
  }else{
    splitIsolateState[panel]=cat;
    var vis=splitVis[panel];
    var rows=splitData[panel].rows;
    for(var i=0;i<rows.length;i++)vis[rows[i].entityId]=(rows[i].category===cat);
    callJSON('isolateCategoryForModel',{category:cat,modelId:modelId});
  }
  renderSplitPanel(panel);
}
function showAllSplitPanel(panel){
  var modelId=(panel==='b')?'model_b':'model_a';
  splitIsolateState[panel]=null;
  splitContainerIsolate[panel]=null;
  var vis=splitVis[panel];
  var rows=splitData[panel].rows;
  for(var i=0;i<rows.length;i++)vis[rows[i].entityId]=true;
  call('showAllForModel',modelId);
  renderSplitPanel(panel);
}
/* ═══ MATCHED FILTER ═══ */
function toggleMatchedFilter(){
  matchedFilterActive=!matchedFilterActive;
  var btn=document.getElementById('mvMatchedToggle');
  if(btn)btn.classList.toggle('active',matchedFilterActive);
  renderSplitPanels();
}
function updateMatchedCount(){
  var btn=document.getElementById('mvMatchedToggle');
  if(!btn)return;
  var catsA={},catsB={},countA=0,countB=0,matched=0;
  for(var i=0;i<splitData.a.rows.length;i++){var c=splitData.a.rows[i].category;if(c&&c!=='_IGNORE'&&!catsA[c]){catsA[c]=true;countA++;}}
  for(var i=0;i<splitData.b.rows.length;i++){var c=splitData.b.rows[i].category;if(c&&c!=='_IGNORE'&&!catsB[c]){catsB[c]=true;countB++;}}
  for(var k in catsA){if(catsA.hasOwnProperty(k)&&catsB[k])matched++;}
  var total=Math.max(countA,countB);
  if(matchedFilterActive) btn.textContent='Matched ('+matched+')';
  else btn.textContent='Matched Only ('+matched+'/'+total+')';
}
/* ═══ COMPARE + DIFF FUNCTIONS ═══ */
function runCompare(){
  showPortalLoading('Comparing','Computing quantity deltas...');
  call('runCompare');
}
var compFlipped=false;
function receiveComparisonResults(data){
  var d;
  try{d=typeof data==='string'?JSON.parse(data):data;}catch(e){console.error('Comparison parse error',e);return;}
  if(d.error){hidePortal();showPortalError('Compare Error',d.error);return;}
  comparisonResults=d;
  compFlipped=false;
  renderCompTable();
  document.getElementById('compResults').classList.add('active');
  updatePortalProgress(50,'Computing visual diff...');
}
function renderCompTable(){
  if(!comparisonResults)return;
  var d=comparisonResults;
  var tb=document.getElementById('compTableBody');
  var title=document.getElementById('compTitle');
  var colA=document.getElementById('compColA');
  var colB=document.getElementById('compColB');
  if(title)title.innerHTML='Quantity Delta &mdash; '+(compFlipped?'B vs A':'A vs B');
  if(colA)colA.textContent=compFlipped?'B':'A';
  if(colB)colB.textContent=compFlipped?'A':'B';
  var h='';
  for(var i=0;i<d.length;i++){
    var r=d[i];
    var qBase=compFlipped?r.qtyB:r.qtyA;
    var qComp=compFlipped?r.qtyA:r.qtyB;
    var delta=qComp-qBase;
    var roundDelta=Math.round(delta*100)/100;
    var pct=qBase>0?(delta/qBase*100):(qComp>0?999.9:0);
    var roundPct=Math.round(pct*10)/10;
    var dc=roundDelta>0?'delta-pos':(roundDelta<0?'delta-neg':'delta-zero');
    var pctStr=Math.abs(roundPct)>999?'NEW':((roundPct>0?'+':'')+roundPct+'%');
    h+='<tr><td>'+X(r.category)+'</td>';
    h+='<td class="r">'+qBase+' <span class="pct">'+X(r.unit)+'</span></td>';
    h+='<td class="r">'+qComp+' <span class="pct">'+X(r.unit)+'</span></td>';
    h+='<td class="r '+dc+'">'+(roundDelta>0?'+':'')+roundDelta+'</td>';
    h+='<td class="r '+dc+'">'+pctStr+'</td></tr>';
  }
  tb.innerHTML=h;
}
function flipCompBaseline(){
  compFlipped=!compFlipped;
  renderCompTable();
}
function receiveDiffResults(data){
  var d;
  try{d=typeof data==='string'?JSON.parse(data):data;}catch(e){console.error('Diff parse error',e);return;}
  diffComputed=true;
  diffActive=d.diffActive;
  updateDiffToggle();
}
function setDiffToggle(isOn){
  diffActive=isOn;
  updateDiffToggle();
}
function updateDiffToggle(){
  return; // hidden for release
  var el=document.getElementById('mvDiffToggle');
  if(!el)return;
  if(diffComputed){
    el.style.display='inline-flex';
    el.classList.toggle('active',diffActive);
    el.textContent=diffActive?'Diff ON':'Diff';
  } else {
    el.style.display='none';
  }
}
function toggleDiff(){
  if(!diffComputed)return;
  call('toggleDiff');
}
function closeCompResults(){
  document.getElementById('compResults').classList.remove('active');
}
function clearCompareUI(){
  comparisonResults=null;diffActive=false;diffComputed=false;compFlipped=false;
  document.getElementById('compResults').classList.remove('active');
  updateDiffToggle();
  graphCats={};closeGraph();
}
/* ═══ GRAPH — APPLES TO APPLES ═══ */
var graphCats={};
function toggleGraphCat(cat){
  graphCats[cat]=!graphCats[cat];
  if(!graphCats[cat])delete graphCats[cat];
  renderSplitPanel('a');renderSplitPanel('b');
  updateGraphBtnLabel();
}
function updateGraphBtnLabel(){
  var btn=document.getElementById('mvGraphBtn');if(!btn)return;
  var n=Object.keys(graphCats).length;
  btn.innerHTML=n>0?'&#127822; Graph ('+n+')':'&#127822; Graph';
}
function showGraph(){
  if(!splitData||!splitData.a||!splitData.b)return;
  var selected=Object.keys(graphCats);
  if(selected.length===0){
    var allCats={};
    for(var i=0;i<splitData.a.rows.length;i++){var c=splitData.a.rows[i].category;if(c&&c!=='_IGNORE')allCats[c]=true;}
    for(var i=0;i<splitData.b.rows.length;i++){var c=splitData.b.rows[i].category;if(c&&c!=='_IGNORE')allCats[c]=true;}
    selected=Object.keys(allCats);
  }
  selected.sort();
  var data=[];
  for(var i=0;i<selected.length;i++){
    var cat=selected[i],aItems=[],bItems=[];
    for(var j=0;j<splitData.a.rows.length;j++){if(splitData.a.rows[j].category===cat)aItems.push(splitData.a.rows[j]);}
    for(var j=0;j<splitData.b.rows.length;j++){if(splitData.b.rows[j].category===cat)bItems.push(splitData.b.rows[j]);}
    var allI=aItems.concat(bItems);
    if(allI.length===0)continue;
    var mt=allI[0].measurementType||'volume';
    var qA=graphSum(aItems,mt),qB=graphSum(bItems,mt);
    var delta=qB-qA;
    var pct=qA>0?(delta/qA*100):(qB>0?100:0);
    data.push({category:cat,qtyA:qA,qtyB:qB,delta:delta,pct:pct,unit:uLabel(mt),mt:mt,countA:aItems.length,countB:bItems.length});
  }
  renderGraphChart(data);
}
function graphSum(items,mt){
  var t=0;
  for(var i=0;i<items.length;i++){var r=items[i];if(r.cosmetic)continue;
    if(mt==='ea'||mt==='ea_bf'||mt==='ea_sf')t+=1;
    else if(mt==='lf')t+=(r.linearFt||0);
    else if(mt==='sf'||mt==='sf_cy'||mt==='sf_sheets')t+=(r.areaSF||0);
    else t+=(r.volumeFt3||0);
  }
  return t;
}
function graphFmt(val,mt){
  if(mt==='ea'||mt==='ea_bf'||mt==='ea_sf')return Math.round(val).toString();
  if(mt==='lf'||mt==='sf'||mt==='sf_cy'||mt==='sf_sheets')return val.toFixed(1);
  return val.toFixed(2);
}
function renderGraphChart(data){
  if(data.length===0)return;
  var maxQ=0;
  for(var i=0;i<data.length;i++){maxQ=Math.max(maxQ,data[i].qtyA,data[i].qtyB);}
  if(maxQ===0)maxQ=1;
  var h='';
  for(var i=0;i<data.length;i++){
    var d=data[i];
    var pA=Math.max(0.5,d.qtyA/maxQ*100),pB=Math.max(0.5,d.qtyB/maxQ*100);
    var dc=d.delta>0?'delta-pos':(d.delta<0?'delta-neg':'delta-zero');
    var ps;
    if(d.qtyA===0&&d.qtyB>0)ps='NEW';
    else if(d.qtyB===0&&d.qtyA>0)ps='REMOVED';
    else if(d.delta===0)ps='—';
    else ps=(d.pct>0?'+':'')+d.pct.toFixed(1)+'%';
    h+='<div class="graph-row">';
    h+='<div class="graph-cat" title="'+X(d.category)+'">'+X(d.category)+'</div>';
    h+='<div class="graph-bars">';
    h+='<div class="graph-bar-wrap"><div class="graph-bar bar-a" style="width:'+pA.toFixed(1)+'%"></div>';
    h+='<span class="graph-val">'+graphFmt(d.qtyA,d.mt)+d.unit+' <span class="graph-count">('+d.countA+')</span></span></div>';
    h+='<div class="graph-bar-wrap"><div class="graph-bar bar-b" style="width:'+pB.toFixed(1)+'%"></div>';
    h+='<span class="graph-val">'+graphFmt(d.qtyB,d.mt)+d.unit+' <span class="graph-count">('+d.countB+')</span></span></div>';
    h+='</div>';
    h+='<div class="graph-delta '+dc+'">'+(d.delta>0?'+':'')+graphFmt(d.delta,d.mt)+'<br><span style="font-size:9px">'+ps+'</span></div>';
    h+='</div>';
  }
  document.getElementById('graphBody').innerHTML=h;
  // Average % change across all categories that have a computable delta
  var pctSum=0,pctN=0;
  for(var i=0;i<data.length;i++){
    var d=data[i];
    if(d.qtyA>0){pctSum+=d.pct;pctN++;}
    else if(d.qtyB>0){pctSum+=100;pctN++;}
  }
  var avg=pctN>0?(pctSum/pctN):0;
  var ac=avg>0?'avg-pos':(avg<0?'avg-neg':'avg-zero');
  var sign=avg>0?'+':'';
  document.getElementById('graphAvg').innerHTML='<span class="graph-avg-label">Average Change</span> <span class="graph-avg-val '+ac+'">'+sign+avg.toFixed(1)+'%</span>';
  document.getElementById('graphOverlay').classList.add('active');
}
function closeGraph(){
  document.getElementById('graphOverlay').classList.remove('active');
}
function recallFromVault(){call('recallFromVault');}
function receiveRecallResult(s){
  var d=JSON.parse(s);
  if(d.error){showPortalError('Recall Error',d.error);return;}
  hidePortal();
  clearCompareUI();
}
function receiveVaultSummary(s){/* future: render vault panel */}
/* ═══ COMMIT TO MAIN FUNCTIONS ═══ */
function commitCategory(cat){
  var count=0;
  if(splitData&&splitData.b&&splitData.b.rows){
    for(var i=0;i<splitData.b.rows.length;i++){
      var rc=splitData.b.rows[i].category||'Uncategorized';
      if(rc===cat)count++;
    }
  }
  showPortalConfirm('Commit to Main','Move '+(count||'all')+' "'+cat+'" entities from Model B into Model A',function(){
    call('commitToMain',cat);
  });
}
function receiveCommitResult(s){
  var d;
  try{d=JSON.parse(s);}catch(e){console.error('Commit parse error',e);return;}
  if(d.error){hidePortal();showPortalError('Commit Error',d.error);return;}
  var msg='';
  if(d.stashed)msg+=d.stashed+' stashed';
  if(d.committed)msg+=(msg?', ':'')+d.committed+' committed';
  updatePortalProgress(100,msg||'Complete!');
  setTimeout(function(){hidePortal();},800);
}
/* Split divider drag */
(function(){
  var divider=null,dragging=false,startX=0,startWidthA=0;
  document.addEventListener('mousedown',function(e){
    if(!e.target.closest||!e.target.closest('#splitDivider'))return;
    divider=document.getElementById('splitDivider');
    dragging=true;startX=e.clientX;
    startWidthA=document.getElementById('panelA').offsetWidth;
    divider.classList.add('dragging');
    document.body.style.cursor='col-resize';document.body.style.userSelect='none';
    e.preventDefault();
  });
  document.addEventListener('mousemove',function(e){
    if(!dragging)return;
    var container=document.getElementById('splitContainer');
    var totalW=container.offsetWidth-5;// subtract divider
    var delta=e.clientX-startX;
    var newW=Math.min(totalW*0.75,Math.max(totalW*0.25,startWidthA+delta));
    document.getElementById('panelA').style.width=newW+'px';
    document.getElementById('panelB').style.width=(totalW-newW)+'px';
  });
  document.addEventListener('mouseup',function(){
    if(!dragging)return;
    dragging=false;
    if(divider)divider.classList.remove('dragging');
    document.body.style.cursor='';document.body.style.userSelect='';
  });
})();

/* ═══════════════════════════════════════════════════════════
   SCANNER MODE — Visual Classifier
   ═══════════════════════════════════════════════════════════ */

var esc=function(s){return s?String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'):'';};

function receiveScannerBanner(data){
  var d=typeof data==='string'?JSON.parse(data):data;
  var el=document.getElementById('scannerBanner');
  var txt=document.getElementById('sbText');
  txt.innerHTML='<b>'+d.low_confidence_groups+' group'+(d.low_confidence_groups!==1?'s':'')+
    '</b> ('+d.low_confidence_items+' items) need classification';
  el.classList.add('active');
}

function dismissScannerBanner(){
  document.getElementById('scannerBanner').classList.remove('active');
}

var NE_ENTITIES=[];  // full new entity list from template comparison
var NE_OPEN_GROUPS={};
var NE_ISOLATED=false;
var NE_ISOLATED_CAT=null;  // track which group is isolated
var NE_APPROVED={};  // eid → true for manually approved items

function receiveNewEntitiesBanner(data){
  var d=typeof data==='string'?JSON.parse(data):data;
  NE_ENTITIES=d.entities||[];
  var el=document.getElementById('newEntitiesBanner');
  var txt=document.getElementById('nebText');
  var cats=document.getElementById('nebCats');
  var remaining=neCountRemaining();
  txt.innerHTML='<b>'+d.count+'</b> new entit'+(d.count!==1?'ies':'y')+' detected (not in template)';
  var html='';
  (d.categories||[]).forEach(function(c){
    html+='<span class="neb-cat">'+esc(c.name)+': '+c.count+'</span>';
  });
  cats.innerHTML=html;
  el.classList.add('active');
}

function dismissNewEntitiesBanner(){
  if(NE_ISOLATED){
    call('showAll');
  }
  document.getElementById('newEntitiesBanner').classList.remove('active');
  document.getElementById('neReviewPanel').classList.remove('active');
  NE_ISOLATED=false;
  NE_ISOLATED_CAT=null;
}

function toggleNewEntitiesReview(){
  var panel=document.getElementById('neReviewPanel');
  if(panel.classList.contains('active')){
    panel.classList.remove('active');
    return;
  }
  renderNewEntitiesReview();
  panel.classList.add('active');
}

function renderNewEntitiesReview(){
  if(!NE_ENTITIES.length)return;
  // Group by scanner category
  var groups={},order=[];
  NE_ENTITIES.forEach(function(e){
    var cat=e.scannerCat||'Uncategorized';
    if(!groups[cat]){groups[cat]=[];order.push(cat);}
    groups[cat].push(e);
  });
  var remaining=neCountRemaining();
  var total=NE_ENTITIES.length;
  var done=total-remaining;

  var html='<div class="ne-review-header">';
  html+='<span class="ne-title">New Entities Review</span>';
  html+='<span class="ne-progress"><b>'+done+'</b>/'+total+' reviewed</span>';
  html+='<button class="ne-iso-btn'+(NE_ISOLATED?' active':'')+'" onclick="neIsolateAll()" title="Isolate all new entities in viewport">Isolate All</button>';
  html+='</div>';

  order.forEach(function(cat){
    var items=groups[cat];
    var catDone=0;
    var catRemaining=0;
    items.forEach(function(e){if(neIsDone(e))catDone++;else catRemaining++;});
    var isOpen=NE_OPEN_GROUPS[cat]||false;
    var allDone=catRemaining===0;
    html+='<div class="ne-group">';
    html+='<div class="ne-group-hdr">';
    html+='<span class="ne-arrow'+(isOpen?' open':'')+'" onclick="neToggleGroup(\''+escQ(cat)+'\')">&#9654;</span>';
    html+='<span class="ne-gname" onclick="neToggleGroup(\''+escQ(cat)+'\')">'+esc(cat)+'</span>';
    if(catDone>0)html+='<span class="ne-gdone">'+catDone+'/'+items.length+'</span>';
    html+='<span class="ne-gcount">'+items.length+'</span>';
    html+='<span class="ne-group-actions">';
    if(!allDone){
      html+='<button class="ne-gbtn iso" onclick="event.stopPropagation();neIsolateGroup(\''+escQ(cat)+'\')" title="Isolate this category in viewport">Isolate</button>';
      html+='<button class="ne-gbtn appr" onclick="event.stopPropagation();neApproveGroup(\''+escQ(cat)+'\')" title="Approve all in this category">Approve All</button>';
    }else{
      html+='<span class="ne-gdone" style="font-style:italic">all reviewed</span>';
    }
    html+='</span>';
    html+='</div>';
    html+='<div class="ne-items'+(isOpen?' open':'')+'">';
    items.forEach(function(e){
      var isDone=neIsDone(e);
      var currentCat=neCurrentCat(e);
      html+='<div class="ne-item'+(isDone?' done':'')+'" onclick="neClickItem('+e.eid+')">';
      html+='<span class="ne-check">'+(isDone?'&#10003;':'')+'</span>';
      html+='<span class="ne-iname" title="'+esc(e.name)+'">'+esc(neShortName(e.name))+'</span>';
      if(e.tag)html+='<span class="ne-itag">'+esc(e.tag)+'</span>';
      if(isDone&&currentCat!==e.scannerCat)html+='<span class="ne-icat">&#8594; '+esc(currentCat)+'</span>';
      if(!isDone){
        html+='<select class="ne-cat-sel" onclick="event.stopPropagation()" onchange="neSetCat('+e.eid+',this.value)">'+buildGroupedCatOptionsSelected(currentCat,false)+'</select>';
        html+='<button class="ne-approve" onclick="event.stopPropagation();neApproveItem('+e.eid+')" title="Approve — scanner got it right">&#10003;</button>';
      }
      html+='<button class="ne-zoom" onclick="event.stopPropagation();call(\'zoomToEntity\',\''+e.eid+'\')" title="Zoom">&#128269;</button>';
      html+='</div>';
    });
    html+='</div></div>';
  });
  document.getElementById('neReviewPanel').innerHTML=html;
}

function neToggleGroup(cat){
  NE_OPEN_GROUPS[cat]=!NE_OPEN_GROUPS[cat];
  renderNewEntitiesReview();
}

function neClickItem(eid){
  call('selectEntity',''+eid);
  call('zoomToEntity',''+eid);
}

function neIsolateAll(){
  if(NE_ISOLATED){
    call('showAll');
    NE_ISOLATED=false;
    NE_ISOLATED_CAT=null;
  }else{
    var ids=[];
    NE_ENTITIES.forEach(function(e){
      if(!neIsDone(e))ids.push(e.eid);
    });
    if(ids.length)call('isolateEntities',ids.join(','));
    NE_ISOLATED=true;
    NE_ISOLATED_CAT=null;
  }
  renderNewEntitiesReview();
}

function neIsolateGroup(cat){
  var ids=[];
  NE_ENTITIES.forEach(function(e){
    if((e.scannerCat||'Uncategorized')===cat && !neIsDone(e))ids.push(e.eid);
  });
  if(ids.length){
    call('isolateEntities',ids.join(','));
    NE_ISOLATED=true;
    NE_ISOLATED_CAT=cat;
    renderNewEntitiesReview();
  }
}

function neSetCat(eid,val){
  if(!val)return;
  // Use the dashboard's standard setCategory flow
  callJSON('setCategory',{eid:eid,val:val});
  // Update local data
  for(var i=0;i<D.length;i++){if(D[i].entityId===eid){D[i].category=val;D[i].subcategory='';break;}}
  NE_APPROVED[eid]=true;
  renderNewEntitiesReview();
  neUpdateBanner();
}

function neApproveItem(eid){
  NE_APPROVED[eid]=true;
  // Commit scanner category as firm assignment in Ruby
  call('neApprove',JSON.stringify([eid]));
  renderNewEntitiesReview();
  neUpdateBanner();
}

function neApproveGroup(cat){
  var eids=[];
  NE_ENTITIES.forEach(function(e){
    if((e.scannerCat||'Uncategorized')===cat && !neIsDone(e)){
      NE_APPROVED[e.eid]=true;
      eids.push(e.eid);
    }
  });
  // Commit all scanner categories as firm assignments in Ruby
  if(eids.length)call('neApprove',JSON.stringify(eids));
  renderNewEntitiesReview();
  neUpdateBanner();
}

function neUpdateBanner(){
  var remaining=neCountRemaining();
  var txt=document.getElementById('nebText');
  if(remaining===0){
    txt.innerHTML='All new entities reviewed! <b>Template can be updated.</b>';
  }else{
    txt.innerHTML='<b>'+remaining+'</b> of '+NE_ENTITIES.length+' new entit'+(NE_ENTITIES.length!==1?'ies':'y')+' remaining';
  }
}

// Check if an entity is done: approved by user OR recategorized away from scanner default
function neIsDone(e){
  if(NE_APPROVED[e.eid])return true;
  if(!D||!D.length)return false;
  for(var i=0;i<D.length;i++){
    if(D[i].entityId===e.eid){
      var cur=D[i].category;
      return cur!==e.scannerCat && cur!=='Uncategorized';
    }
  }
  return false;
}

function neCurrentCat(e){
  if(!D||!D.length)return e.scannerCat;
  for(var i=0;i<D.length;i++){
    if(D[i].entityId===e.eid)return D[i].category;
  }
  return e.scannerCat;
}

function neCountRemaining(){
  var count=0;
  NE_ENTITIES.forEach(function(e){if(!neIsDone(e))count++;});
  return count;
}

function neShortName(name){
  if(!name)return '?';
  // Strip trailing hex instance ID (Revit pattern)
  var m=name.match(/^(.+?),\s*[0-9A-Fa-f]{4,}$/);
  if(m)return m[1];
  return name.length>50?name.substr(0,47)+'...':name;
}

// Called after receiveData to refresh the review panel state
function neRefreshReview(){
  if(!NE_ENTITIES.length)return;
  var panel=document.getElementById('neReviewPanel');
  if(!panel||!panel.classList.contains('active'))return;
  renderNewEntitiesReview();
  // Update banner count
  var remaining=neCountRemaining();
  var txt=document.getElementById('nebText');
  if(remaining===0){
    txt.innerHTML='All new entities reviewed! <b>Template can be updated.</b>';
    if(NE_ISOLATED){
      NE_ISOLATED=false;NE_ISOLATED_CAT=null;
      call('showAll');
    }
  }else{
    txt.innerHTML='<b>'+remaining+'</b> of '+NE_ENTITIES.length+' new entit'+(NE_ENTITIES.length!==1?'ies':'y')+' remaining';
  }
  // Re-isolate remaining new entities if isolation is active
  if(NE_ISOLATED && remaining>0){
    var ids=[];
    NE_ENTITIES.forEach(function(e){
      if(!neIsDone(e)){
        if(!NE_ISOLATED_CAT || (e.scannerCat||'Uncategorized')===NE_ISOLATED_CAT)
          ids.push(e.eid);
      }
    });
    if(ids.length)call('isolateEntities',ids.join(','));
  }
}

function enterScannerMode(){
  scannerMode=true;
  dismissScannerBanner();
  document.getElementById('scannerOverlay').classList.add('active');
  // Hide normal dashboard UI
  var fbar=document.querySelector('.fbar');if(fbar)fbar.style.display='none';
  var fbar2=document.getElementById('fbar2');if(fbar2)fbar2.style.display='none';
  var catBar=document.querySelector('.cat-bar');if(catBar)catBar.style.display='none';
  var dpWrap=document.getElementById('dpWrap');if(dpWrap)dpWrap.style.display='none';
  call('enterScannerMode');
}

function exitScannerMode(){
  scannerMode=false;
  scExpandedCard=-1;
  document.getElementById('scannerOverlay').classList.remove('active');
  // Restore normal dashboard UI
  var fbar=document.querySelector('.fbar');if(fbar)fbar.style.display='';
  var fbar2=document.getElementById('fbar2');if(fbar2)fbar2.style.display='';
  var catBar=document.querySelector('.cat-bar');if(catBar)catBar.style.display='';
  var dpWrap=document.getElementById('dpWrap');if(dpWrap)dpWrap.style.display='';
  // Reset group-by buttons
  scCurrentMode='name';
  var btns=document.querySelectorAll('.sc-group-btn');
  btns.forEach(function(b){b.classList.toggle('active',b.getAttribute('data-mode')==='name');});
  call('exitScannerMode');
}

function receiveScannerGroups(data){
  var d=typeof data==='string'?JSON.parse(data):data;
  scGroups=d.groups||[];
  scCategories=d.categories||[];
  scSubcategories=d.subcategories||{};
  renderScannerGroups();
}

function scGroupBy(mode){
  scCurrentMode=mode;
  scExpandedCard=-1;
  var btns=document.querySelectorAll('.sc-group-btn');
  btns.forEach(function(b){b.classList.toggle('active',b.getAttribute('data-mode')===mode);});
  call('regroupScanner',mode);
}

function renderScannerGroups(){
  var el=document.getElementById('scGroups');
  var total=scGroups.length;
  var remaining=0;
  scGroups.forEach(function(g){if(!g.applied)remaining++;});
  var prog=document.getElementById('scProgress');
  prog.textContent=remaining+' remaining of '+total;

  var html='';
  for(var i=0;i<scGroups.length;i++){
    html+=renderScCard(scGroups[i],i);
  }
  if(total===0) html='<div style="text-align:center;color:#a6adc8;padding:40px;font-size:13px">No uncategorized items to classify.</div>';
  if(remaining===0 && total>0) html='<div style="text-align:center;color:#a6e3a1;padding:40px;font-size:13px">All groups classified! Click <b>Finish</b> to return.</div>'+html;
  el.innerHTML=html;
}

function renderScCard(g,idx){
  var isExpanded=(scExpandedCard===idx);
  var confClass=g.confidence<30?'low':'med';
  var appliedClass=g.applied?'applied':'';
  var expandedClass=isExpanded?'expanded':'';

  var h='<div class="sc-card '+appliedClass+' '+expandedClass+'" id="scCard'+idx+'">';
  h+='<div class="sc-card-header" onclick="scToggleCard('+idx+')">';
  h+='<span class="sc-card-name" title="'+esc(g.name)+'">'+esc(g.name)+'</span>';
  if(g.material&&g.material!=='-') h+='<span class="sc-card-mat" title="'+esc(g.material)+'">'+esc(g.material)+'</span>';
  h+='<button class="sc-preview-btn" onclick="event.stopPropagation();scPreview('+idx+')" title="Highlight in viewport">&#128065;</button>';
  h+='<span class="sc-card-count">'+g.count+' item'+(g.count!==1?'s':'')+'</span>';
  h+='<span class="sc-card-conf '+confClass+'">'+g.confidence+'%</span>';
  h+='</div>';

  // Body (always rendered, shown via CSS .expanded)
  h+='<div class="sc-card-body">';

  // Guesses
  if(g.guesses&&g.guesses.length>0){
    h+='<div style="margin-bottom:6px;color:#6c7086;font-size:10px">Suggestions:</div>';
    for(var gi=0;gi<g.guesses.length;gi++){
      var gg=g.guesses[gi];
      h+='<div class="sc-guess-row" onclick="scQuickApply('+idx+',\''+escQ(gg.category)+'\',\''+(gg.subcategory?escQ(gg.subcategory):'')+'\');" title="Click to apply">';
      h+='<span class="sc-guess-cat">'+esc(gg.category)+'</span>';
      if(gg.subcategory) h+='<span class="sc-guess-sub">&rsaquo; '+esc(gg.subcategory)+'</span>';
      h+='<span class="sc-guess-src">'+esc(gg.source||'')+'</span>';
      h+='<span class="sc-guess-conf">'+gg.confidence+'%</span>';
      h+='</div>';
    }
  }

  // Manual assignment row
  h+='<div class="sc-assign-row">';
  h+='<select class="sc-assign-dd" id="scCat'+idx+'" onchange="scCatChanged('+idx+')">';
  h+='<option value="">Select category...</option>';
  if(CONTAINERS&&CONTAINERS.length>0){
    for(var cci=0;cci<CONTAINERS.length;cci++){
      var cont=CONTAINERS[cci];if(!cont.categories||!cont.categories.length)continue;
      var sorted=cont.categories.slice().sort(function(a,b){return a.name.toLowerCase().localeCompare(b.name.toLowerCase());});
      h+='<optgroup label="'+esc(cont.name)+'">';
      for(var cj=0;cj<sorted.length;cj++){if(sorted[cj].name==='_IGNORE')continue;h+='<option value="'+esc(sorted[cj].name)+'">'+esc(sorted[cj].name)+'</option>';}
      h+='</optgroup>';
    }
  }else{
    for(var ci=0;ci<scCategories.length;ci++){
      if(scCategories[ci]==='_IGNORE')continue;
      h+='<option value="'+esc(scCategories[ci])+'">'+esc(scCategories[ci])+'</option>';
    }
  }
  h+='</select>';
  h+='<select class="sc-assign-dd" id="scSub'+idx+'" style="max-width:120px"><option value="">Sub...</option></select>';
  h+='<button class="sc-apply-btn" onclick="scApply('+idx+')">Apply</button>';
  h+='<button class="sc-skip-btn" onclick="scSkip('+idx+')">Skip</button>';
  h+='</div>';

  // New category row
  h+='<div class="sc-new-cat-row">';
  h+='<input class="sc-new-cat-input" id="scNewCat'+idx+'" placeholder="New category name..." onkeydown="if(event.key===\'Enter\')scCreateCat('+idx+')">';
  h+='<button class="sc-new-cat-btn" onclick="scCreateCat('+idx+')">+ Add</button>';
  h+='</div>';

  h+='</div>'; // .sc-card-body
  h+='</div>'; // .sc-card
  return h;
}

function scToggleCard(idx){
  if(scExpandedCard===idx){
    scExpandedCard=-1;
    call('clearScannerHighlight');
  } else {
    scExpandedCard=idx;
    var g=scGroups[idx];
    if(g&&g.entityIds) call('highlightScannerGroup',g.entityIds.join(','));
  }
  renderScannerGroups();
}

function scPreview(idx){
  var g=scGroups[idx];
  if(g&&g.entityIds) call('highlightScannerGroup',g.entityIds.join(','));
}

function scCatChanged(idx){
  var catSel=document.getElementById('scCat'+idx);
  var subSel=document.getElementById('scSub'+idx);
  if(!catSel||!subSel)return;
  var cat=catSel.value;
  subSel.innerHTML='<option value="">Sub...</option>';
  var subs=scSubcategories[cat]||[];
  for(var i=0;i<subs.length;i++){
    subSel.innerHTML+='<option value="'+esc(subs[i])+'">'+esc(subs[i])+'</option>';
  }
}

function scQuickApply(idx,cat,sub){
  var payload=JSON.stringify({groupIdx:idx,category:cat,subcategory:sub||'',costCode:''});
  call('applyScannerGroup',payload);
}

function scApply(idx){
  var catSel=document.getElementById('scCat'+idx);
  var subSel=document.getElementById('scSub'+idx);
  if(!catSel||!catSel.value)return;
  var payload=JSON.stringify({groupIdx:idx,category:catSel.value,subcategory:subSel?subSel.value:'',costCode:''});
  call('applyScannerGroup',payload);
}

function scSkip(idx){
  call('skipScannerGroup',String(idx));
}

function scCreateCat(idx){
  var inp=document.getElementById('scNewCat'+idx);
  if(!inp||!inp.value.trim())return;
  call('createScannerCategory',inp.value.trim());
  inp.value='';
}

function escQ(s){return (s||'').replace(/'/g,"\\'").replace(/\\/g,"\\\\");}
