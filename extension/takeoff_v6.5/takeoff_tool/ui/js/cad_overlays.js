/* ═══ CAD OVERLAYS ═══ */
var CAD_SHEETS=[];
var CAD_COL={};
var CAD_ISO=null;
var CAD_DRAG_EID=null;
var CAD_CATS={
  site:      {label:'Site Plans',  icon:'SP',color:'#94e2d5',glow:'rgba(148,226,213,0.15)'},
  plans:     {label:'Floor Plans', icon:'FP',color:'#89b4fa',glow:'rgba(137,180,250,0.15)'},
  elevations:{label:'Elevations',  icon:'EL',color:'#a6e3a1',glow:'rgba(166,227,161,0.15)'},
  sections:  {label:'Sections',    icon:'SC',color:'#fab387',glow:'rgba(250,179,135,0.15)'},
  details:   {label:'Details',     icon:'DT',color:'#cba6f7',glow:'rgba(203,166,247,0.15)'},
  structural:{label:'Structural',  icon:'ST',color:'#f9e2af',glow:'rgba(249,226,175,0.15)'}
};
var CAD_ORDER=['site','plans','elevations','sections','details','structural'];
var CAD_SVG_CHEV='<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M4 2L8 6L4 10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
var CAD_SVG_ISO='<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><rect x="1" y="1" width="10" height="10" rx="2" stroke="currentColor" stroke-width="1.2"/><circle cx="6" cy="6" r="2" fill="currentColor"/></svg>';
var CAD_SVG_ZOOM='<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><circle cx="5.5" cy="5.5" r="3.5" stroke="currentColor" stroke-width="1.2"/><path d="M8.5 8.5L11 11" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>';
var CAD_SVG_ALIGN='<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M6 1v10M1 6h10" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>';
var CAD_SVG_TRASH='<svg width="11" height="11" viewBox="0 0 11 11" fill="none"><path d="M2 3H9L8.3 9.5C8.25 10 7.85 10.3 7.35 10.3H3.65C3.15 10.3 2.75 10 2.7 9.5L2 3Z" stroke="currentColor" stroke-width="1"/><path d="M1 3H10" stroke="currentColor" stroke-width="1" stroke-linecap="round"/><path d="M4 3V1.5C4 1.2 4.2 1 4.5 1H6.5C6.8 1 7 1.2 7 1.5V3" stroke="currentColor" stroke-width="1"/></svg>';
var CAD_SVG_GRIP='<svg width="8" height="12" viewBox="0 0 8 12" fill="currentColor"><circle cx="2" cy="2" r="1.2"/><circle cx="6" cy="2" r="1.2"/><circle cx="2" cy="6" r="1.2"/><circle cx="6" cy="6" r="1.2"/><circle cx="2" cy="10" r="1.2"/><circle cx="6" cy="10" r="1.2"/></svg>';

function receiveCadSheets(data){try{CAD_SHEETS=typeof data==='string'?JSON.parse(data):data;if(!CAD_SHEETS)CAD_SHEETS=[];}catch(e){CAD_SHEETS=[];}renderCadPanel();}

function renderCadPanel(){
  var el=document.getElementById('cadBody'),emp=document.getElementById('cadEmpty');

  // Group by category
  var grouped={};
  for(var i=0;i<CAD_SHEETS.length;i++){
    var s=CAD_SHEETS[i],k=s.category||'plans';
    if(!grouped[k])grouped[k]=[];
    grouped[k].push(s);
  }

  // Build render order: all registered cats (including empty), plus any unregistered
  var renderOrder=CAD_ORDER.slice();
  for(var k in grouped){if(renderOrder.indexOf(k)<0)renderOrder.push(k);}

  // Check if anything to show (sheets or custom cats beyond defaults)
  var hasContent=CAD_SHEETS.length>0||CAD_ORDER.length>6;
  if(!hasContent){el.innerHTML='';emp.style.display='';return;}
  emp.style.display='none';

  // Save add-cat input value before re-render
  var addInp=document.getElementById('cadNewCatName');
  var addVal=addInp?addInp.value:'';

  var h='';
  for(var ci=0;ci<renderOrder.length;ci++){
    var k=renderOrder[ci],list=grouped[k]||[];
    var c=CAD_CATS[k]||{label:k,icon:k.substring(0,2).toUpperCase(),color:'#a6adc8',glow:'rgba(166,173,200,0.15)'};
    var col=!!CAD_COL[k];
    var catVis=list.length?list.some(function(s){return s.visible;}):false;
    var catIso=CAD_ISO&&CAD_ISO.type==='cat'&&CAD_ISO.id===k;

    h+='<div class="cad-cat'+(col?' col':'')+(catIso?' iso':'')+(catVis?' has-vis':'')+'" data-cat="'+X2(k)+'" style="--cc:'+c.color+';--cg:'+c.glow+'"';
    h+=' ondragover="cadDragOver(event)" ondragleave="cadDragLeave(event)" ondrop="cadDrop(event,\''+X2(k)+'\')">';
    h+='<div class="cad-cat-hdr" onclick="cadTogCol(\''+X2(k)+'\')">';
    h+='<div class="cad-chev">'+CAD_SVG_CHEV+'</div>';
    h+='<div class="cad-icon" style="background:'+c.color+'">'+c.icon+'</div>';
    h+='<span class="cad-lbl">'+X(c.label)+'</span>';
    if(list.length)h+='<span class="cad-cnt">'+list.length+'</span>';
    h+='<div class="cad-ctrl">';
    if(list.length)h+='<button onclick="event.stopPropagation();cadTogCatVis(\''+X2(k)+'\')" title="Toggle all" style="'+(catVis?'':'color:#585b70')+'">'+(catVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
    if(list.length)h+='<button onclick="event.stopPropagation();cadIsoCat(\''+X2(k)+'\')" title="Isolate" style="'+(catIso?'color:'+c.color:'')+'">'+CAD_SVG_ISO+'</button>';
    h+='</div></div>';

    var sheetH=list.length?list.length*32+4:28;
    h+='<div class="cad-sheets" style="max-height:'+(col?0:sheetH)+'px">';

    if(!list.length){
      h+='<div class="cad-drop-empty">Drop sheets here</div>';
    }

    for(var j=0;j<list.length;j++){
      var s=list[j],v=s.visible,sIso=CAD_ISO&&CAD_ISO.type==='sheet'&&CAD_ISO.id===s.eid;
      var isSection=s.sheet_type==='section';
      h+='<div class="cad-sh'+(!v&&!sIso?' off':'')+'" draggable="true" data-eid="'+s.eid+'"';
      h+=' ondragstart="cadDragStart(event,'+s.eid+')" ondragend="cadDragEnd(event)">';
      h+='<span class="cad-grip">'+CAD_SVG_GRIP+'</span>';
      h+='<button class="cad-sh-eye'+(v?'':' off')+'" onclick="togCad('+s.eid+','+(!v)+')" style="color:'+(v?c.color:'')+'">'+(v?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
      h+='<span class="cad-sh-name">'+X(s.name)+'</span>';
      if(s.elevation_label)h+='<span class="cad-sh-elev">'+X(s.elevation_label)+'</span>';
      h+='<div class="cad-sh-acts">';
      h+='<button class="cad-sh-btn" onclick="cadIsoSheet('+s.eid+')" title="Isolate" style="'+(sIso?'color:'+c.color:'')+'">'+CAD_SVG_ISO+'</button>';
      h+='<button class="cad-sh-btn" onclick="call(\'zoomCadSheet\',\''+s.eid+'\')" title="Zoom">'+CAD_SVG_ZOOM+'</button>';
      h+='<button class="cad-sh-btn" onclick="call(\'alignCadSheet\',\''+s.eid+'\')" title="Align" style="color:'+(isSection?'#fab387':'#89b4fa')+'">'+CAD_SVG_ALIGN+'</button>';
      h+='<button class="cad-sh-btn" onclick="delCad('+s.eid+',\''+X2(s.name)+'\')" title="Delete" style="color:#f38ba8">'+CAD_SVG_TRASH+'</button>';
      h+='</div></div>';
    }
    h+='</div></div>';
  }

  h+='<div class="cad-add-cat">';
  h+='<input type="text" id="cadNewCatName" placeholder="New category name..." value="'+X2(addVal)+'"';
  h+=' onkeydown="if(event.key===\'Enter\')cadAddCat()">';
  h+='<button onclick="cadAddCat()">Add</button>';
  h+='</div>';

  el.innerHTML=h;
}

/* ── Drag & Drop ── */
function cadDragStart(e,eid){
  CAD_DRAG_EID=eid;
  e.dataTransfer.effectAllowed='move';
  e.dataTransfer.setData('text/plain',''+eid);
  var row=e.target.closest('.cad-sh');
  if(row)setTimeout(function(){row.classList.add('dragging');},0);
}
function cadDragEnd(e){
  CAD_DRAG_EID=null;
  renderCadPanel();
}
function cadDragOver(e){
  e.preventDefault();
  e.dataTransfer.dropEffect='move';
  var cat=e.target.closest('.cad-cat');
  if(cat&&!cat.classList.contains('drag-over'))cat.classList.add('drag-over');
}
function cadDragLeave(e){
  var cat=e.target.closest('.cad-cat');
  if(!cat)return;
  var related=e.relatedTarget;
  if(related&&cat.contains(related))return;
  cat.classList.remove('drag-over');
}
function cadDrop(e,targetCat){
  e.preventDefault();
  var cat=e.target.closest('.cad-cat');
  if(cat)cat.classList.remove('drag-over');
  var eid=parseInt(e.dataTransfer.getData('text/plain'));
  if(!eid||isNaN(eid))return;
  cadMoveCat(eid,targetCat);
}

/* ── Actions ── */
function cadTogCol(k){CAD_COL[k]=!CAD_COL[k];renderCadPanel();}

function cadTogCatVis(k){
  var list=CAD_SHEETS.filter(function(s){return(s.category||'plans')===k;});
  var allOn=list.every(function(s){return s.visible;});
  for(var i=0;i<list.length;i++){
    list[i].visible=!allOn;
    callJSON('toggleCadSheet',{eid:list[i].eid,show:!allOn});
  }
  renderCadPanel();
}

function cadIsoCat(k){
  if(CAD_ISO&&CAD_ISO.type==='cat'&&CAD_ISO.id===k){
    CAD_ISO=null;
    call('showAllCad');
    for(var i=0;i<CAD_SHEETS.length;i++)CAD_SHEETS[i].visible=true;
  } else {
    CAD_ISO={type:'cat',id:k};
    for(var i=0;i<CAD_SHEETS.length;i++){
      var inCat=(CAD_SHEETS[i].category||'plans')===k;
      CAD_SHEETS[i].visible=inCat;
      callJSON('toggleCadSheet',{eid:CAD_SHEETS[i].eid,show:inCat});
    }
  }
  renderCadPanel();
}

function cadIsoSheet(eid){
  if(CAD_ISO&&CAD_ISO.type==='sheet'&&CAD_ISO.id===eid){
    CAD_ISO=null;
    call('showAllCad');
    for(var i=0;i<CAD_SHEETS.length;i++)CAD_SHEETS[i].visible=true;
  } else {
    CAD_ISO={type:'sheet',id:eid};
    for(var i=0;i<CAD_SHEETS.length;i++){
      var match=CAD_SHEETS[i].eid===eid;
      CAD_SHEETS[i].visible=match;
      callJSON('toggleCadSheet',{eid:CAD_SHEETS[i].eid,show:match});
    }
  }
  renderCadPanel();
}

function cadMoveCat(eid,newCat){
  callJSON('setCadCategory',{eid:eid,category:newCat});
  for(var i=0;i<CAD_SHEETS.length;i++){
    if(CAD_SHEETS[i].eid===eid){CAD_SHEETS[i].category=newCat;break;}
  }
  renderCadPanel();
}

function cadAddCat(){
  var inp=document.getElementById('cadNewCatName');
  var name=(inp?inp.value:'').trim();
  if(!name)return;
  var key=name.toLowerCase().replace(/[^a-z0-9]+/g,'_');
  if(!CAD_CATS[key]){
    CAD_CATS[key]={label:name,icon:name.substring(0,2).toUpperCase(),color:'#a6adc8',glow:'rgba(166,173,200,0.15)'};
    if(CAD_ORDER.indexOf(key)<0)CAD_ORDER.push(key);
  }
  renderCadPanel();
}

function togCad(eid,show){callJSON('toggleCadSheet',{eid:eid,show:show});for(var i=0;i<CAD_SHEETS.length;i++){if(CAD_SHEETS[i].eid===eid){CAD_SHEETS[i].visible=show;break;}}renderCadPanel();}
function delCad(eid,name){showConfirmModal('Delete CAD sheet "'+name+'"? This cannot be undone.',function(){call('deleteCadSheet',''+eid);CAD_SHEETS=CAD_SHEETS.filter(function(s){return s.eid!==eid;});renderCadPanel();});}

function editElevLabel(eid,span){
  var it=MEAS.find(function(m){return m.eid===eid;});
  if(!it)return;
  var cur=it.custom_label||'';
  var inp=document.createElement('input');
  inp.type='text';inp.value=cur;
  inp.style.cssText='background:#313244;color:#cdd6f4;border:1px solid #a6e3a1;border-radius:3px;padding:1px 4px;font-size:11px;width:100%;outline:none;';
  span.textContent='';span.appendChild(inp);
  inp.focus();inp.select();
  var done=false;
  function finish(){
    if(done)return;done=true;
    var val=inp.value.trim();
    it.custom_label=val;
    callJSON('updateElevLabel',{eid:eid,label:val});
    renderMeasPanel();
  }
  inp.addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();finish();}if(e.key==='Escape'){done=true;renderMeasPanel();}});
  inp.addEventListener('blur',finish);
}

function editNoteText(eid,span){
  var it=MEAS.find(function(m){return m.eid===eid;});
  if(!it)return;
  var cur=it.note||'';
  var inp=document.createElement('input');
  inp.type='text';inp.value=cur;
  inp.style.cssText='background:#313244;color:#cdd6f4;border:1px solid #89b4fa;border-radius:3px;padding:1px 4px;font-size:11px;width:100%;outline:none;';
  span.textContent='';span.appendChild(inp);
  inp.focus();inp.select();
  var done=false;
  function finish(){
    if(done)return;done=true;
    var val=inp.value.trim();
    it.note=val;
    callJSON('updateNoteText',{eid:eid,text:val});
    renderMeasPanel();
  }
  inp.addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();finish();}if(e.key==='Escape'){done=true;renderMeasPanel();}});
  inp.addEventListener('blur',finish);
}