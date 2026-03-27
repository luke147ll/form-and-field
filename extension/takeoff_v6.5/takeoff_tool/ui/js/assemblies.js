/* ═══ ASSEMBLY SYSTEM ═══ */
var expandedAssemblies={};
var ASM_TAGS={};
var asmVFormOpen={};
var ASM_PARTS_CAP=50;

function getAsmEids(a){
  if(a.entity_ids&&a.entity_ids.length)return a.entity_ids;
  if(a.parts&&a.parts.length){
    var ids=[];
    for(var i=0;i<a.parts.length;i++){
      if(a.parts[i].entity_id&&!a.parts[i].is_virtual)ids.push(a.parts[i].entity_id);
    }
    return ids;
  }
  return [];
}

function togAsmVis(id){
  var a=ASMB[id];if(!a)return;
  var ids=getAsmEids(a);if(!ids.length)return;
  var anyVis=false;
  for(var i=0;i<ids.length;i++){if(VIS[ids[i]]!==false){anyVis=true;break;}}
  for(var j=0;j<ids.length;j++)VIS[ids[j]]=!anyVis;
  if(ids.length)call(anyVis?'hideEntities':'showEntities',ids.join(','));
  ASMVIS[id]=!anyVis;
  filt();renderAsmPanel();
}
function togAsmPartVis(eid){
  var vis=VIS[eid]!==false;VIS[eid]=!vis;
  call(vis?'hideEntities':'showEntities',''+eid);
  renderAsmPanel();
}
function togPartGroupVis(eidsArg){
  var ids=Array.isArray(eidsArg)?eidsArg:String(eidsArg).split(',').map(Number);
  var allVis=true;
  for(var i=0;i<ids.length;i++){if(VIS[ids[i]]===false){allVis=false;break;}}
  var action=allVis?'hideEntities':'showEntities';
  for(var i=0;i<ids.length;i++){VIS[ids[i]]=!allVis;}
  call(action,ids.join(','));
  renderAsmPanel();
}
function isoPartGroup(eidsArg){
  var ids=Array.isArray(eidsArg)?eidsArg:String(eidsArg).split(',').map(Number);
  call('isolateEntities',ids.join(','));
  var idSet={};
  for(var i=0;i<ids.length;i++){idSet[ids[i]]=true;VIS[ids[i]]=true;}
  for(var i=0;i<D.length;i++){
    var eid=D[i].entityId;
    if(!idSet[eid])VIS[eid]=false;
  }
  ISO_CATS=null;FISO=false;updateFisoBtn();
  filt();renderAsmPanel();
}
function isoAsm(id){
  var a=ASMB[id];if(!a)return;
  // Use VisibilityManager on the Ruby side for proper isolation
  callJSON('isolateAssembly',{asmId:id});
  // Update local filter state to reflect isolation
  var aIds={};var ids=getAsmEids(a);
  for(var k=0;k<ids.length;k++){aIds[ids[k]]=true;VIS[ids[k]]=true;}
  for(var i=0;i<D.length;i++){
    var eid=D[i].entityId;
    if(!aIds[eid])VIS[eid]=false;
  }
  ISO_CATS=null;FISO=false;updateFisoBtn();
  document.getElementById('fAsm').value=id;
  filt();renderAsmPanel();
}

function receiveAssemblies(data){
  try{
    ASMB=typeof data==='string'?JSON.parse(data):data;
    if(!ASMB)ASMB={};
  }catch(e){ASMB={};console.error('receiveAssemblies parse error',e);}
  buildAsmDD();
  renderAsmPanel();
  heartbeatOff();
}
function toggleAsmPanel(){}

/* ═══ ASSEMBLY CARD RENDERING ═══ */
function renderAsmPanel(){
  if(_asmViewMode==='cards'){renderAsmPanelV2();return;}
  var body=document.getElementById('asmBody');
  var keys=Object.keys(ASMB).sort(function(a,b){
    var na=(ASMB[a].name||'').toLowerCase(),nb=(ASMB[b].name||'').toLowerCase();
    return na.localeCompare(nb);
  });
  document.getElementById('asmCount').textContent=keys.length+' assemblies';
  var atab=document.querySelector('.tab[data-tab="assemblies"]');
  if(atab)atab.textContent='Assemblies'+(keys.length?' ('+keys.length+')':'');
  if(!keys.length){body.innerHTML='<div class="asm-empty">No assemblies yet. Use "Create Assembly" or right-click in viewport.</div>';return;}
  var h='';
  var fasm=document.getElementById('fAsm').value;
  for(var i=0;i<keys.length;i++){
    h+=renderAsmCard(keys[i],ASMB[keys[i]],i,fasm);
  }
  body.innerHTML=h;
  setTimeout(function(){checkScrollFade('asmScroll','asmFade');},20);
}

function renderAsmCard(id,asm,idx,fasm){
  var active=fasm===id?' active':'';
  var eids=getAsmEids(asm);
  var aVis=eids.length?eids.some(function(eid){return VIS[eid]!==false;}):true;
  var isExp=!!expandedAssemblies[id];
  var name=asm.name||id;
  var zone=asm.zone||'';
  var eCnt=getAsmEids(asm).length;
  var pCnt=asm.part_count||0;
  var tagsOn=asm.tags_visible||false;
  var si="'"+id.replace(/'/g,"\\'")+"'";
  var h='<div class="asm-card'+active+'" id="asmCard_'+id+'">';
  // Header
  h+='<div class="asm-card-header" onclick="toggleAsmCard('+si+')">';
  h+='<button class="ey'+(aVis?'':' off')+'" onclick="event.stopPropagation();togAsmVis('+si+')" title="'+(aVis?'Hide':'Show')+'">'+(aVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
  h+='<button class="asm-iso" onclick="event.stopPropagation();isoAsm('+si+')" title="Isolate">Isolate</button>';
  h+='<span class="asm-expand-arrow'+(isExp?' expanded':'')+'">&#9654;</span>';
  h+='<span class="asm-name" ondblclick="event.stopPropagation();asmRename('+si+')" title="'+X(name)+'">'+X(name)+'</span>';
  if(zone)h+='<span class="asm-room-badge" ondblclick="event.stopPropagation();asmSetZone('+si+')" title="Zone: '+X(zone)+'">'+X(zone)+'</span>';
  h+='<span class="asm-entity-count">'+eCnt+' items</span>';
  h+='<span class="asm-part-count">'+pCnt+' parts</span>';
  h+='<div class="asm-card-actions">';
  h+='<button onclick="event.stopPropagation();asmExport('+si+')" title="Export CSV"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg></button>';
  h+='<button onclick="event.stopPropagation();asmRename('+si+')" title="Rename"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg></button>';
  h+='<button onclick="event.stopPropagation();editAssemblyNotes('+si+')" title="Edit notes"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg></button>';
  if(!zone)h+='<button onclick="event.stopPropagation();asmSetZone('+si+')" title="Set zone/room"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg></button>';
  h+='<button onclick="event.stopPropagation();deleteAssemblyConfirm('+si+')" title="Delete" style="color:#f38ba8"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg></button>';
  h+='</div></div>';
  // Body (collapsible)
  h+='<div class="asm-card-body'+(isExp?' open':'')+'" id="asmBody_'+id+'">';
  h+=renderAsmPartsInline(id,asm);
  h+='</div>';
  h+='</div>';
  return h;
}

/* ═══ INLINE GROUPED PARTS VIEW ═══ */
function renderAutoTagList(id){
  var tags=AUTO_TAGS[id];
  if(!tags||!tags.length)return'';
  var h='<div style="border-bottom:2px solid var(--surface1)">';
  h+='<div style="display:flex;align-items:center;padding:4px 10px;background:var(--mantle);border-bottom:1px solid var(--surface0)">';
  h+='<span style="font-size:9px;font-weight:600;color:var(--yellow)">AUTO TAGS ('+tags.length+')</span>';
  h+='<span style="flex:1"></span>';
  h+='<button class="hb" onclick="event.stopPropagation();AUTO_TAGS[\''+id+'\']=null;callJSON(\'clearAutoTags\',{asmId:\''+id+'\'});renderAsmPanel()" style="font-size:8px;padding:1px 6px;color:var(--red);border-color:var(--surface2)">Clear</button>';
  h+='</div>';
  for(var i=0;i<tags.length;i++){
    var t=tags[i];
    var eids=t.eid?JSON.stringify([t.eid]):'[]';
    h+='<div style="display:flex;align-items:center;gap:6px;padding:3px 10px;border-bottom:1px solid rgba(49,50,68,.4);font-size:10px">';
    h+='<span style="font-weight:700;color:var(--yellow);min-width:32px">'+X(t.label)+'</span>';
    h+='<span style="flex:1;color:var(--text);overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="'+X(t.name)+'">'+X(t.name)+'</span>';
    if(t.category)h+='<span style="font-size:9px;color:var(--overlay1);max-width:100px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+X(t.category)+'</span>';
    if(t.eid){
      h+='<button onclick="event.stopPropagation();isoPartGroup('+eids+')" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:0;font-family:inherit" title="Isolate">iso</button>';
    }
    h+='</div>';
  }
  h+='</div>';
  return h;
}

function renderAsmPartsInline(id,asm){
  var bi=asm.beamInventory||[];
  var parts=asm.parts||[];
  if(!bi.length&&!parts.length&&!AUTO_TAGS[id])return'<div class="asm-bd-empty">No parts</div>';

  // Auto tag list (if tags have been placed)
  var tagHtml=renderAutoTagList(id);

  // If no beam inventory, show simple grouped list
  if(!bi.length){
    return tagHtml+renderAsmPartsSimple(id,asm);
  }

  var h=tagHtml;
  var totalPcs=0,totalLF=0,totalBF=0;

  for(var i=0;i<bi.length;i++){
    var bm=bi[i];
    var sp=bm.section.split('x');var bW=parseFrac(sp[0]),bH=parseFrac(sp[1]);
    var secBF=0;for(var r=0;r<bm.rows.length;r++){secBF+=bW*bH*bm.rows[r].l*bm.rows[r].qty/12;}
    totalPcs+=bm.count;totalLF+=bm.totalLF;totalBF+=secBF;

    var secKey='abi_'+id+'_'+i;
    var secOpen=!!_beamInvOpen[secKey];
    var secEids=JSON.stringify(bm.eids||[]);

    // Section header
    h+='<div style="display:flex;align-items:center;gap:8px;padding:5px 10px;background:var(--mantle);border-bottom:1px solid var(--surface0);cursor:pointer;user-select:none" onclick="event.stopPropagation();_beamInvOpen[\''+secKey+'\']='+(secOpen?'false':'true')+';renderAsmPanel();">';
    h+='<span style="font-size:9px;color:var(--overlay0)">'+(secOpen?'&#9660;':'&#9654;')+'</span>';
    h+='<span style="font-size:11px;font-weight:700;color:var(--text)">'+bm.section+'"</span>';
    h+='<span style="font-size:10px;color:var(--overlay1);flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'+X(bm.defn)+'</span>';
    // Visibility toggle for this section
    var secVis=(bm.eids||[]).some(function(eid){return VIS[eid]!==false;});
    h+='<button onclick="event.stopPropagation();togPartGroupVis('+secEids+')" style="border:none;background:transparent;cursor:pointer;color:'+(secVis?'var(--blue)':'var(--surface2)')+';font-size:11px;padding:2px" title="Toggle visibility">';
    h+=(secVis?'\u25C9':'\u25CB')+'</button>';
    // Isolate
    h+='<button onclick="event.stopPropagation();isoPartGroup('+secEids+')" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:2px;font-family:inherit" title="Isolate">iso</button>';
    h+='<span style="font-size:10px;font-weight:700;color:var(--green)">'+bm.count+'</span>';
    h+='<span style="font-size:10px;font-weight:700;color:var(--sapphire)">'+bm.totalLF.toFixed(1)+'\'</span>';
    h+='<span style="font-size:10px;font-weight:600;color:var(--yellow)">'+Math.round(secBF)+' BF</span>';
    h+='</div>';

    // Length subgroups (when expanded)
    if(secOpen){
      for(var ri=0;ri<bm.rows.length;ri++){
        var rw=bm.rows[ri];
        var rwBF=bW*bH*rw.l*rw.qty/12;
        var rwEids=JSON.stringify(rw.eids||[]);
        h+='<div style="display:flex;align-items:center;gap:8px;padding:3px 10px 3px 32px;border-bottom:1px solid rgba(49,50,68,.5);position:relative;cursor:pointer">';
        h+='<span style="position:absolute;left:22px;top:0;bottom:0;width:1px;background:var(--surface0)"></span>';
        h+='<span style="position:absolute;left:22px;top:50%;width:6px;height:1px;background:var(--surface0)"></span>';
        // Vis toggle per length group
        var rwVis=(rw.eids||[]).some(function(eid){return VIS[eid]!==false;});
        h+='<button onclick="event.stopPropagation();togPartGroupVis('+rwEids+')" style="border:none;background:transparent;cursor:pointer;color:'+(rwVis?'var(--blue)':'var(--surface2)')+';font-size:10px;padding:0" title="Toggle">'+(rwVis?'\u25C9':'\u25CB')+'</button>';
        h+='<button onclick="event.stopPropagation();isoPartGroup('+rwEids+')" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:0;font-family:inherit" title="Isolate">iso</button>';
        h+='<span style="font-size:11px;font-weight:600;color:var(--peach);min-width:65px">'+bm.section+'"</span>';
        h+='<span style="color:var(--overlay0)">&times;</span>';
        h+='<span style="font-size:11px;font-weight:700;color:var(--sapphire);min-width:65px">'+fmtFtIn(rw.l)+'</span>';
        h+='<span style="color:var(--overlay0)">&times;</span>';
        h+='<span style="font-size:12px;font-weight:700;color:var(--green);min-width:28px">'+rw.qty+'</span>';
        h+='<span style="font-size:9px;color:var(--overlay0)">pcs</span>';
        h+='<span style="flex:1"></span>';
        h+='<span style="font-size:10px;font-weight:600;color:var(--yellow)">'+Math.round(rwBF)+' BF</span>';
        h+='</div>';
      }
    }
  }

  // Build set of eids already in beam inventory
  var beamEids={};
  for(var bei=0;bei<bi.length;bei++){
    var beids=bi[bei].eids||[];
    for(var bej=0;bej<beids.length;bej++) beamEids[beids[bej]]=true;
  }
  // Non-beam parts: exclude anything already in beam inventory
  var nonBeam=parts.filter(function(p){return !p.entity_id||!beamEids[p.entity_id];});
  if(nonBeam.length){
    h+='<div style="padding:4px 10px 2px;font-size:9px;font-weight:600;color:var(--overlay0);border-bottom:1px solid var(--surface0);background:var(--mantle)">OTHER PARTS ('+nonBeam.length+')</div>';
    // Group non-beam by category+name
    var nbGroups={};
    for(var ni=0;ni<nonBeam.length;ni++){
      var np=nonBeam[ni];
      var nk=(np.category||'')+'|'+(np.name||'');
      if(!nbGroups[nk])nbGroups[nk]={name:np.name||'',category:np.category||'',qty:0,eids:[],is_virtual:np.is_virtual||false};
      nbGroups[nk].qty+=(np.qty||1);
      if(np.entity_id)nbGroups[nk].eids.push(np.entity_id);
    }
    var nbItems=Object.values(nbGroups).sort(function(a,b){return a.category.localeCompare(b.category)||a.name.localeCompare(b.name);});
    for(var nbi=0;nbi<nbItems.length;nbi++){
      var nb=nbItems[nbi];
      var nbEids=JSON.stringify(nb.eids);
      var nbVis=nb.eids.length?nb.eids.some(function(eid){return VIS[eid]!==false;}):true;
      h+='<div style="display:flex;align-items:center;gap:8px;padding:3px 10px;border-bottom:1px solid rgba(49,50,68,.5);font-size:10px">';
      if(nb.eids.length){
        h+='<button onclick="event.stopPropagation();togPartGroupVis('+nbEids+')" style="border:none;background:transparent;cursor:pointer;color:'+(nbVis?'var(--blue)':'var(--surface2)')+';font-size:10px;padding:0">'+(nbVis?'\u25C9':'\u25CB')+'</button>';
        h+='<button onclick="event.stopPropagation();isoPartGroup('+nbEids+')" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:0;font-family:inherit">iso</button>';
      } else {
        h+='<span style="width:24px"></span>';
      }
      h+='<span style="flex:1;color:var(--text)">'+X(nb.name);
      if(nb.is_virtual)h+='<span class="asm-virt-badge">VIRTUAL</span>';
      h+='</span>';
      h+='<span style="font-size:9px;color:var(--overlay1)">'+X(nb.category)+'</span>';
      h+='<span style="font-weight:700;color:var(--green);min-width:28px;text-align:right">'+nb.qty+'</span>';
      h+='</div>';
    }
  }

  // Total row
  h+='<div style="display:flex;align-items:center;gap:8px;padding:5px 10px;background:var(--mantle);border-top:2px solid var(--surface1);font-weight:700;font-size:11px">';
  h+='<span style="color:var(--subtext1)">TOTAL</span><span style="flex:1"></span>';
  h+='<span style="color:var(--green)">'+totalPcs+' pcs</span>';
  h+='<span style="color:var(--sapphire)">'+totalLF.toFixed(1)+'\'</span>';
  h+='<span style="color:var(--yellow)">'+Math.round(totalBF).toLocaleString()+' BF</span>';
  h+='</div>';

  // Export button
  var ne=X2(asm.name||id);
  h+='<div style="padding:4px 10px;display:flex;gap:6px;justify-content:flex-end">';
  h+='<button class="hb" onclick="event.stopPropagation();call(\'exportPartsList\',\''+ne+'\')" style="font-size:9px;padding:2px 8px;color:#a6e3a1;border-color:#a6e3a1">Export CSV</button>';
  h+='</div>';

  return h;
}

// Simple grouped list for non-beam assemblies
function renderAsmPartsSimple(id,asm){
  var parts=asm.parts||[];
  var groups={};
  for(var i=0;i<parts.length;i++){
    var p=parts[i];
    var k=(p.category||'')+'|'+(p.name||'');
    if(!groups[k])groups[k]={name:p.name||'',category:p.category||'',qty:0,eids:[],is_virtual:p.is_virtual||false,sku:''};
    groups[k].qty+=(p.qty||1);
    if(p.entity_id)groups[k].eids.push(p.entity_id);
    if(!groups[k].sku&&p.part_num)groups[k].sku=p.part_num;
  }
  var items=Object.values(groups).sort(function(a,b){return a.category.localeCompare(b.category)||a.name.localeCompare(b.name);});
  var h='';
  var curCat='';
  for(var i=0;i<items.length;i++){
    var it=items[i];
    if(it.category!==curCat){
      curCat=it.category;
      h+='<div style="padding:4px 10px 2px;font-size:9px;font-weight:600;color:var(--overlay0);border-bottom:1px solid var(--surface0);background:var(--mantle)">'+X(curCat)+'</div>';
    }
    var eidsStr=JSON.stringify(it.eids);
    var vis=it.eids.length?it.eids.some(function(eid){return VIS[eid]!==false;}):true;
    h+='<div style="display:flex;align-items:center;gap:8px;padding:3px 10px;border-bottom:1px solid rgba(49,50,68,.5);font-size:10px">';
    if(it.eids.length){
      h+='<button onclick="event.stopPropagation();togPartGroupVis('+eidsStr+')" style="border:none;background:transparent;cursor:pointer;color:'+(vis?'var(--blue)':'var(--surface2)')+';font-size:10px;padding:0">'+(vis?'\u25C9':'\u25CB')+'</button>';
      h+='<button onclick="event.stopPropagation();isoPartGroup('+eidsStr+')" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:0;font-family:inherit">iso</button>';
    } else {
      h+='<span style="width:24px"></span>';
    }
    if(it.sku)h+='<span style="font-size:9px;color:var(--blue);font-weight:600;min-width:50px">'+X(it.sku)+'</span>';
    h+='<span style="flex:1;color:var(--text)">'+X(it.name);
    if(it.is_virtual)h+='<span class="asm-virt-badge">VIRTUAL</span>';
    h+='</span>';
    h+='<span style="font-weight:700;color:var(--green);min-width:28px;text-align:right">'+it.qty+'</span>';
    h+='</div>';
  }
  var ne=X2(asm.name||id);
  h+='<div style="padding:4px 10px;display:flex;gap:6px;justify-content:flex-end">';
  h+='<button class="hb" onclick="event.stopPropagation();call(\'exportPartsList\',\''+ne+'\')" style="font-size:9px;padding:2px 8px;color:#a6e3a1;border-color:#a6e3a1">Export CSV</button>';
  h+='</div>';
  return h;
}

/* ═══ ASSEMBLY CARD VIEW V2 ═══ */
function renderAsmPanelV2(){
  var body=document.getElementById('asmBody');
  var keys=Object.keys(ASMB).sort(function(a,b){
    var na=(ASMB[a].name||'').toLowerCase(),nb=(ASMB[b].name||'').toLowerCase();
    return na.localeCompare(nb);
  });
  document.getElementById('asmCount').textContent=keys.length+' assemblies';
  var atab=document.querySelector('.tab[data-tab="assemblies"]');
  if(atab)atab.textContent='Assemblies'+(keys.length?' ('+keys.length+')':'');
  if(!keys.length){body.innerHTML='<div class="asm-empty">No assemblies yet. Use "Create Assembly" or right-click in viewport.</div>';return;}

  var h='';
  for(var ki=0;ki<keys.length;ki++){
    var id=keys[ki],asm=ASMB[id];
    var si="'"+id.replace(/'/g,"\\'")+"'";
    var eids=getAsmEids(asm);
    var aVis=eids.length?eids.some(function(eid){return VIS[eid]!==false;}):true;
    var isExp=!!expandedAssemblies[id];
    var name=asm.name||id;
    var zone=asm.zone||'';
    var bi=asm.beamInventory||[];
    var parts=asm.parts||[];
    var breakdown=asm.breakdown||[];
    var tabKey=_ac2Tab[id]||'breakdown';

    // Compute beam stats (only needed for beams tab)
    var totalPcs=0,totalLF=0,totalBF=0;
    for(var si2=0;si2<bi.length;si2++){
      var bm=bi[si2];
      totalPcs+=bm.count||0;
      totalLF+=bm.totalLF||0;
      var sp=bm.section?bm.section.split('x'):[0,0];
      var bW=parseFloat(sp[0])||0,bH=parseFloat(sp[1])||0;
      var rows=bm.rows||[];
      for(var ri=0;ri<rows.length;ri++){
        totalBF+=bW*bH*(rows[ri].l||0)*(rows[ri].qty||0)/12;
      }
    }

    // Build beam eid set for parts dedup
    var beamEids={};
    for(var bei=0;bei<bi.length;bei++){
      var beids=bi[bei].eids||[];
      for(var bej=0;bej<beids.length;bej++)beamEids[beids[bej]]=true;
    }
    var otherParts=parts.filter(function(p){return !p.entity_id||!beamEids[p.entity_id];});

    // Card
    var cardCls='ac2-card';
    if(!aVis)cardCls+=' ac2-hidden';
    h+='<div class="'+cardCls+'" id="ac2Card_'+id+'">';

    // ── Header ──
    h+='<div class="ac2-hdr" onclick="toggleAsmCard('+si+')">';
    // Top row
    h+='<div class="ac2-hdr-top">';
    h+='<button class="ey'+(aVis?'':' off')+'" onclick="event.stopPropagation();togAsmVis('+si+')" title="'+(aVis?'Hide':'Show')+'" style="flex-shrink:0">'+(aVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
    h+='<button class="asm-iso" onclick="event.stopPropagation();isoAsm('+si+')" title="Isolate" style="flex-shrink:0">iso</button>';
    h+='<span style="font-size:8px;color:#585b70;width:12px;text-align:center;transition:transform .2s ease;'+(isExp?'transform:rotate(90deg)':'')+'">&#9654;</span>';
    h+='<span class="ac2-name" ondblclick="event.stopPropagation();asmRename('+si+')" title="'+X(name)+'">'+X(name)+'</span>';
    if(zone)h+='<span class="ac2-zone" ondblclick="event.stopPropagation();asmSetZone('+si+')" title="Zone: '+X(zone)+'">'+X(zone)+'</span>';
    h+='<span class="ac2-item-count">'+eids.length+'</span>';
    h+='</div>';

    // Breakdown summary — inline category chips
    if(breakdown.length){
      h+='<div class="ac2-bd-chips">';
      for(var bdi=0;bdi<breakdown.length;bdi++){
        var bd=breakdown[bdi];
        var bColor=getCatColor(bd.category);
        h+='<span class="ac2-bd-chip" style="border-color:'+bColor+'">';
        h+='<span class="ac2-bd-dot" style="background:'+bColor+'"></span>';
        h+=X(bd.category);
        h+='<span class="ac2-bd-cnt">'+bd.count+'</span>';
        h+='</span>';
      }
      h+='<span class="ac2-bd-total">'+parts.length+' parts</span>';
      h+='</div>';
    } else {
      h+='<div class="ac2-bd-chips"><span class="ac2-bd-total" style="margin-left:64px">'+parts.length+' parts</span></div>';
    }
    h+='</div>'; // end ac2-hdr

    // ── Expanded Body ──
    if(isExp){
      h+='<div>';

      // Tab bar
      h+='<div class="ac2-tabs">';
      var mainTabs=[{key:'breakdown',label:'Breakdown',count:breakdown.length},{key:'parts',label:'Parts',count:otherParts.length}];
      if(tabKey==='beams')mainTabs.push({key:'beams',label:'Beam Inv',count:bi.length});
      else if(tabKey==='auto_sf')mainTabs.push({key:'auto_sf',label:'Auto SF',count:eids.length});
      else if(tabKey==='auto_lf')mainTabs.push({key:'auto_lf',label:'Auto LF',count:eids.length});
      else if(tabKey==='auto_vol')mainTabs.push({key:'auto_vol',label:'Auto Vol',count:eids.length});
      for(var ti=0;ti<mainTabs.length;ti++){
        var t=mainTabs[ti];
        var tActive=tabKey===t.key?' active':'';
        h+='<button class="ac2-tab'+tActive+'" onclick="event.stopPropagation();_ac2Tab[\''+id+'\']=\''+t.key+'\';renderAsmPanel()">'+t.label+'<span class="ac2-tab-count">'+t.count+'</span></button>';
      }
      // Auto scan dropdown button
      h+='<div style="position:relative;display:inline-flex">';
      h+='<button class="ac2-tab" onclick="event.stopPropagation();toggleAsmAutoDD(this,'+si+')" style="color:var(--overlay0);gap:2px">Auto &#9662;</button>';
      h+='</div>';
      h+='<span style="flex:1"></span>';
      if(asm.notes)h+='<span class="ac2-notes" title="'+X(asm.notes)+'">'+X(asm.notes)+'</span>';
      h+='</div>';

      // Tab content
      h+='<div class="ac2-content">';

      // Auto tag list (if placed)
      h+=renderAutoTagList(id);

      if(tabKey==='beams'){
        // Column header
        h+='<div class="ac2-col-hdr">';
        h+='<span style="width:50px"></span><span style="width:10px"></span>';
        h+='<span style="min-width:68px">Section</span>';
        h+='<span style="flex:1">Name</span>';
        h+='<span style="min-width:22px;text-align:right">Qty</span>';
        h+='<span style="min-width:38px;text-align:right">Length</span>';
        h+='<span style="min-width:46px;text-align:right">Board Ft</span>';
        h+='</div>';

        // Beam section rows
        for(var bi2=0;bi2<bi.length;bi2++){
          var bm=bi[bi2];
          var secKey=id+'_s'+bi2;
          var secOpen=!!_ac2OpenSections[secKey];
          var bmEids=bm.eids||[];
          var bmEidsStr=JSON.stringify(bmEids);
          var bmVis=bmEids.length?bmEids.some(function(eid){return VIS[eid]!==false;}):true;
          var sp=bm.section?bm.section.split('x'):[0,0];
          var bW=parseFloat(sp[0])||0,bH=parseFloat(sp[1])||0;
          var secBF=0;
          var bmRows=bm.rows||[];
          for(var ri=0;ri<bmRows.length;ri++){secBF+=bW*bH*(bmRows[ri].l||0)*(bmRows[ri].qty||0)/12;}

          h+='<div style="border-bottom:1px solid #252535">';
          // Section header row
          h+='<div class="ac2-beam-row" onclick="event.stopPropagation();_ac2OpenSections[\''+secKey+'\']=!_ac2OpenSections[\''+secKey+'\'];renderAsmPanel()">';
          h+='<button class="ey'+(bmVis?'':' off')+'" onclick="event.stopPropagation();togPartGroupVis('+bmEidsStr+')" title="'+(bmVis?'Hide':'Show')+'" style="flex-shrink:0">'+(bmVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
          h+='<button onclick="event.stopPropagation();isoPartGroup('+bmEidsStr+')" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:0;font-family:inherit;flex-shrink:0">iso</button>';
          h+='<span style="font-size:8px;color:#585b70;width:10px;text-align:center;transition:transform .2s;'+(secOpen?'transform:rotate(90deg)':'')+'">&#9654;</span>';
          h+='<span style="font-weight:700;color:var(--peach);font-family:var(--font-mono);min-width:68px;font-size:11px">'+X(bm.section)+'"</span>';
          h+='<span style="color:var(--subtext0);flex:1;font-size:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+X(bm.defn)+'</span>';
          h+='<span style="font-weight:700;color:var(--green);min-width:22px;text-align:right;font-size:11px">'+bm.count+'</span>';
          h+='<span style="font-weight:600;color:var(--sapphire);min-width:38px;text-align:right;font-size:10px">'+(bm.totalLF||0).toFixed(1)+'\'</span>';
          h+='<span style="font-weight:600;color:var(--yellow);min-width:46px;text-align:right;font-size:10px">'+Math.round(secBF)+' BF</span>';
          h+='<button class="ac2-rm" onclick="event.stopPropagation();showConfirmModal(\'Remove '+bm.count+' '+X(bm.defn)+' from assembly?\',function(){callJSON(\'removePartsFromAssembly\',{asmId:'+si+',eids:'+bmEidsStr+'})})" title="Remove from assembly"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button>';
          h+='</div>';

          // Expanded subrows
          if(secOpen){
            for(var ri=0;ri<bmRows.length;ri++){
              var rw=bmRows[ri];
              var rwEids=rw.eids||[];
              var rwEidsStr=JSON.stringify(rwEids);
              var rwVis=rwEids.length?rwEids.some(function(eid){return VIS[eid]!==false;}):true;
              var rwBF=bW*bH*(rw.l||0)*(rw.qty||0)/12;
              h+='<div class="ac2-beam-sub">';
              h+='<span class="ac2-tree-line"></span><span class="ac2-tree-branch"></span>';
              h+='<button class="ey'+(rwVis?'':' off')+'" onclick="event.stopPropagation();togPartGroupVis('+rwEidsStr+')" title="'+(rwVis?'Hide':'Show')+'" style="flex-shrink:0">'+(rwVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
              h+='<button onclick="event.stopPropagation();isoPartGroup('+rwEidsStr+')" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:0;font-family:inherit;flex-shrink:0">iso</button>';
              h+='<span style="font-weight:600;color:var(--peach);font-family:var(--font-mono);min-width:68px">'+X(bm.section)+'"</span>';
              h+='<span style="color:#6c7086">&times;</span>';
              h+='<span style="font-weight:700;color:var(--sapphire);min-width:48px">'+fmtFtIn(rw.l)+'</span>';
              h+='<span style="color:#6c7086">&times;</span>';
              h+='<span style="font-weight:700;color:var(--green);min-width:22px">'+rw.qty+'</span>';
              h+='<span style="font-size:9px;color:#6c7086">pcs</span>';
              h+='<span style="flex:1"></span>';
              h+='<span style="font-weight:600;color:var(--yellow)">'+Math.round(rwBF)+' BF</span>';
              h+='</div>';
            }
          }
          h+='</div>';
        }

        // Total row
        h+='<div class="ac2-total">';
        h+='<span style="color:var(--subtext0)">TOTAL</span><span style="flex:1"></span>';
        h+='<span style="color:var(--green);min-width:22px;text-align:right">'+totalPcs+'</span>';
        h+='<span style="color:var(--sapphire);min-width:38px;text-align:right">'+totalLF.toFixed(1)+'\'</span>';
        h+='<span style="color:var(--yellow);min-width:46px;text-align:right">'+Math.round(totalBF).toLocaleString()+' BF</span>';
        h+='</div>';

      } else if(tabKey==='parts'){
        // Column header
        h+='<div class="ac2-col-hdr">';
        h+='<span style="width:50px"></span>';
        h+='<span style="min-width:52px;text-align:center">SKU</span>';
        h+='<span style="width:6px"></span>';
        h+='<span style="flex:1">Name</span>';
        h+='<span style="flex-shrink:0">Category</span>';
        h+='<span style="min-width:28px;text-align:right">Qty</span>';
        h+='</div>';

        if(!otherParts.length){
          h+='<div style="padding:16px 12px;text-align:center;color:#45475a;font-size:10px">All parts are in the beam inventory</div>';
        } else {
          for(var pi=0;pi<otherParts.length;pi++){
            var p=otherParts[pi];
            var pEid=p.entity_id;
            var pVis=pEid?VIS[pEid]!==false:true;
            var pCls='ac2-part-row';
            if(p.is_virtual)pCls+=' virtual';
            h+='<div class="'+pCls+'" style="opacity:'+(pVis?'1':'0.4')+'">';
            if(pEid){
              h+='<button class="ey'+(pVis?'':' off')+'" onclick="event.stopPropagation();togAsmPartVis('+pEid+')" title="'+(pVis?'Hide':'Show')+'" style="flex-shrink:0">'+(pVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';
              h+='<button onclick="event.stopPropagation();isoPartGroup(['+pEid+'])" style="border:none;background:transparent;cursor:pointer;color:var(--overlay0);font-size:9px;padding:0;font-family:inherit;flex-shrink:0">iso</button>';
            } else {
              h+='<span style="width:50px"></span>';
            }
            // SKU
            var hasSku=p.sku&&p.sku.trim();
            if(hasSku){
              h+='<span class="ac2-sku">'+X(p.sku)+'</span>';
            } else {
              h+='<span class="ac2-sku-empty">&mdash;</span>';
            }
            // Color dot
            var pColor=getCatColor(p.category||'');
            h+='<span style="width:6px;height:6px;border-radius:2px;flex-shrink:0;background:'+pColor+'"></span>';
            // Name
            h+='<span style="color:var(--text);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+X(p.name||'');
            if(p.is_virtual)h+='<span style="display:inline-block;background:var(--yellow);color:var(--base);font-size:7px;padding:0 4px;border-radius:2px;font-weight:700;margin-left:5px;vertical-align:middle">VIRTUAL</span>';
            h+='</span>';
            // Category
            h+='<span style="color:#6c7086;font-size:9px;flex-shrink:0">'+X(p.category||'')+'</span>';
            // Qty
            h+='<span style="font-weight:700;color:var(--green);min-width:28px;text-align:right;font-family:var(--font-num)">'+(p.qty||1)+'</span>';
            // Remove button
            if(pEid){
              h+='<button class="ac2-rm" onclick="event.stopPropagation();callJSON(\'removePartsFromAssembly\',{asmId:'+si+',eids:['+pEid+']})" title="Remove from assembly"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button>';
            } else if(p.part_num){
              var pnEsc=p.part_num.replace(/'/g,"\\'");
              h+='<button class="ac2-rm" onclick="event.stopPropagation();callJSON(\'deleteAsmPart\',{asmId:'+si+',partNumber:\''+pnEsc+'\'})" title="Remove virtual part"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button>';
            }
            h+='</div>';
          }
        }

      } else if(tabKey==='breakdown'){
        h+='<div style="padding:14px">';
        // Category rows
        for(var bdi=0;bdi<breakdown.length;bdi++){
          var bd=breakdown[bdi];
          var bColor=getCatColor(bd.category);
          h+='<div style="display:flex;align-items:center;gap:6px;font-size:10px;padding:2px 0">';
          h+='<span style="width:6px;height:6px;border-radius:2px;flex-shrink:0;background:'+bColor+'"></span>';
          h+='<span style="color:var(--subtext0);flex:1">'+X(bd.category)+'</span>';
          h+='<span style="font-family:var(--font-num);font-weight:600;color:var(--text);min-width:24px;text-align:right">'+bd.count+'</span>';
          h+='<span style="font-family:var(--font-num);color:#585b70;font-size:9px;min-width:32px;text-align:right">'+bd.percent+'%</span>';
          h+='</div>';
        }
        // Bar
        h+='<div class="ac2-bar" style="margin:12px 0 8px">';
        for(var bdi=0;bdi<breakdown.length;bdi++){
          var bd=breakdown[bdi];
          var bColor=getCatColor(bd.category);
          h+='<div class="ac2-bar-seg" style="width:'+bd.percent+'%;background:'+bColor+'"></div>';
        }
        h+='</div>';
        // Legend
        h+='<div style="display:flex;flex-wrap:wrap;gap:4px 12px;font-size:9px;color:#6c7086">';
        for(var bdi=0;bdi<breakdown.length;bdi++){
          var bd=breakdown[bdi];
          var bColor=getCatColor(bd.category);
          h+='<span style="display:flex;align-items:center;gap:4px"><span style="width:8px;height:8px;border-radius:2px;background:'+bColor+'"></span>'+X(bd.category)+'</span>';
        }
        h+='</div>';
        h+='</div>';

      } else if(tabKey==='auto_sf'||tabKey==='auto_lf'||tabKey==='auto_vol'){
        // Auto scan summary — compute per-category totals from scan data for this assembly
        var autoUnit=tabKey==='auto_sf'?'SF':tabKey==='auto_lf'?'LF':'CF';
        var autoField=tabKey==='auto_sf'?'areaSF':tabKey==='auto_lf'?'linearFt':'volumeFt3';
        var autoLabel=tabKey==='auto_sf'?'SF':tabKey==='auto_lf'?'LF':'CY';
        var autoDivisor=tabKey==='auto_vol'?27.0:1.0; // CF→CY
        var asmEidSet={};for(var ae=0;ae<eids.length;ae++)asmEidSet[eids[ae]]=true;
        var autoCats={},autoTotal=0;
        if(D&&D.length){
          for(var si3=0;si3<D.length;si3++){
            var sr=D[si3];
            if(!asmEidSet[sr.entityId])continue;
            var val=(sr[autoField]||0);
            if(val<=0)continue;
            var scat=sr.category||'Uncategorized';
            if(!autoCats[scat])autoCats[scat]={total:0,count:0};
            autoCats[scat].total+=val;
            autoCats[scat].count++;
            autoTotal+=val;
          }
        }
        autoTotal=autoTotal/autoDivisor;
        var autoCatKeys=Object.keys(autoCats).sort(function(a,b){return autoCats[b].total-autoCats[a].total;});

        h+='<div style="padding:14px">';
        if(autoCatKeys.length===0){
          h+='<div style="text-align:center;color:#45475a;font-size:10px;padding:12px 0">No '+autoLabel+' data for entities in this assembly</div>';
        } else {
          for(var aci=0;aci<autoCatKeys.length;aci++){
            var ac=autoCatKeys[aci],acData=autoCats[ac];
            var acVal=acData.total/autoDivisor;
            var acPct=autoTotal>0?Math.round(acVal/autoTotal*100):0;
            var acColor=getCatColor(ac);
            h+='<div style="display:flex;align-items:center;gap:6px;font-size:10px;padding:3px 0">';
            h+='<span style="width:6px;height:6px;border-radius:2px;flex-shrink:0;background:'+acColor+'"></span>';
            h+='<span style="color:var(--subtext0);flex:1">'+X(ac)+'</span>';
            h+='<span style="font-family:var(--font-num);color:var(--overlay0);font-size:9px;min-width:24px;text-align:right">'+acData.count+'</span>';
            h+='<span style="font-family:var(--font-num);font-weight:600;color:var(--text);min-width:60px;text-align:right">'+acVal.toFixed(1)+'</span>';
            h+='<span style="font-size:9px;color:#585b70;min-width:20px">'+autoLabel+'</span>';
            h+='<span style="font-family:var(--font-num);color:#585b70;font-size:9px;min-width:28px;text-align:right">'+acPct+'%</span>';
            h+='</div>';
          }
          // Total row
          h+='<div style="display:flex;align-items:center;gap:6px;font-size:10px;padding:6px 0;margin-top:4px;border-top:1px solid var(--surface0)">';
          h+='<span style="width:6px"></span>';
          h+='<span style="color:var(--subtext0);flex:1;font-weight:600">TOTAL</span>';
          h+='<span style="font-family:var(--font-num);font-weight:700;color:var(--text);min-width:60px;text-align:right">'+autoTotal.toFixed(1)+'</span>';
          h+='<span style="font-size:9px;color:#585b70;min-width:20px">'+autoLabel+'</span>';
          h+='<span style="min-width:28px"></span>';
          h+='</div>';
        }
        h+='</div>';
      }

      h+='</div>'; // end ac2-content

      // Action bar
      h+='<div class="ac2-actions">';
      h+='<button style="color:var(--green);border-color:var(--green)" onclick="event.stopPropagation();callJSON(\'addToAssemblyFromSelection\',{asmId:'+si+'})">Add Selected</button>';
      h+='<button onclick="event.stopPropagation();asmExport('+si+')">Export</button>';
      h+='<button onclick="event.stopPropagation();asmRename('+si+')">Rename</button>';
      h+='<button onclick="event.stopPropagation();editAssemblyNotes('+si+')">Notes</button>';
      if(!zone)h+='<button onclick="event.stopPropagation();asmSetZone('+si+')">Zone</button>';
      h+='<span style="flex:1"></span>';
      h+='<button class="danger" onclick="event.stopPropagation();deleteAssemblyConfirm('+si+')">Delete</button>';
      h+='</div>';

      h+='</div>'; // end expanded body
    }

    h+='</div>'; // end ac2-card
  }
  body.innerHTML=h;
  setTimeout(function(){checkScrollFade('asmScroll','asmFade');},20);
}

function getCatColor(cat){
  cat=cat||'';
  // Check CCOL for user-assigned color, else use hash-based fallback
  if(CCOL&&CCOL.categories&&CCOL.categories[cat])return CCOL.categories[cat];
  var palette=['#fab387','#89b4fa','#a6e3a1','#94e2d5','#f9e2af','#cba6f7','#f38ba8','#74c7ec','#b4befe','#89dceb'];
  var hash=0;
  for(var i=0;i<cat.length;i++){hash=((hash<<5)-hash)+cat.charCodeAt(i);hash|=0;}
  return palette[Math.abs(hash)%palette.length];
}

/* ═══ PARTS TABLE ═══ */
function renderAsmPartsTable(id,asm){
  var parts=asm.parts||[];
  if(!parts.length)return'<div class="asm-bd-empty">No parts yet — add from selection or add virtual parts.</div>';
  var si="'"+id.replace(/'/g,"\\'")+"'";
  var h='<table class="asm-parts-table"><thead><tr><th>Part#</th><th>Name</th><th>Category</th><th>Qty</th><th>Unit</th><th>Notes</th><th></th></tr></thead><tbody>';
  var cap=ASM_PARTS_CAP;
  var showAll=!!expandedAssemblies[id+'_allparts'];
  var limit=showAll?parts.length:Math.min(parts.length,cap);
  for(var i=0;i<limit;i++){
    var p=parts[i];
    var rowCls='asm-part-row';
    if(p.is_virtual)rowCls+=' virtual';
    if(p.stale)rowCls+=' stale';
    if(p.beam_net_section)rowCls+=' beam';
    var psi="'"+p.part_num.replace(/'/g,"\\'")+"'";
    h+='<tr class="'+rowCls+'">';
    h+='<td class="asm-part-num">'+X(p.part_num)+'</td>';
    h+='<td>'+X(p.name||'');
    if(p.is_virtual)h+='<span class="asm-virt-badge">VIRTUAL</span>';
    if(p.beam_net_section)h+='<br><span class="asm-beam-info">'+X(p.beam_net_section)+(p.beam_linear_ft?' &middot; '+p.beam_linear_ft.toFixed(1)+' LF':'')+'</span>';
    h+='</td>';
    h+='<td>'+X(p.category||'')+'</td>';
    h+='<td>'+p.qty+'</td>';
    h+='<td>'+X(p.unit||'EA')+'</td>';
    h+='<td style="color:#6c7086;max-width:100px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="'+X(p.notes||'')+'">'+X(p.notes||'')+'</td>';
    h+='<td class="asm-part-acts">';
    if(p.entity_id&&!p.is_virtual){var pVis=VIS[p.entity_id]!==false;h+='<button onclick="event.stopPropagation();togAsmPartVis('+p.entity_id+')" title="'+(pVis?'Hide':'Show')+' entity" style="color:'+(pVis?'#a6adc8':'#585b70')+'">'+(pVis?ICO_EYE_OPEN:ICO_EYE_CLOSED)+'</button>';h+='<button onclick="event.stopPropagation();asmZoomToPart('+p.entity_id+')" title="Zoom to entity"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg></button>';}
    h+='<button onclick="event.stopPropagation();asmEditPart('+si+','+psi+')" title="Edit"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg></button>';
    h+='<button onclick="event.stopPropagation();asmDeletePart('+si+','+psi+')" title="Delete" style="color:#f38ba8"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/></svg></button>';
    h+='</td></tr>';
  }
  if(!showAll&&parts.length>cap){
    h+='<tr><td colspan="7" style="text-align:center;padding:6px"><button class="asm-add-btn" onclick="event.stopPropagation();expandedAssemblies[\''+id+'_allparts\']=true;renderAsmPanel()">Show all '+parts.length+' parts ('+(parts.length-cap)+' more)</button></td></tr>';
  }
  h+='</tbody><tfoot><tr><td colspan="7" style="padding:4px 0">';
  h+='<button class="asm-add-btn sel" onclick="event.stopPropagation();asmAddFromSelection('+si+')">+ From Selection</button>';
  h+='<button class="asm-add-btn virt" onclick="event.stopPropagation();asmAddVirtualPart('+si+')">+ Virtual Part</button>';
  h+='</td></tr></tfoot></table>';
  return h;
}

/* ═══ VIRTUAL PART INLINE FORM ═══ */
function renderAsmVForm(id){
  var isOpen=!!asmVFormOpen[id];
  var si="'"+id.replace(/'/g,"\\'")+"'";
  var catOpts='<option value="">Select...</option>';
  var cats=(typeof CA!=='undefined'&&CA)?CA:[];
  for(var i=0;i<cats.length;i++){catOpts+='<option value="'+X(cats[i])+'">'+X(cats[i])+'</option>';}
  var h='<div class="asm-vform'+(isOpen?' open':'')+'" id="asmVForm_'+id+'">';
  h+='<div class="asm-vform-row"><input id="asmVF_name_'+id+'" placeholder="Part name..." style="flex:2"><select id="asmVF_cat_'+id+'" style="flex:1">'+catOpts+'</select></div>';
  h+='<div class="asm-vform-row"><input id="asmVF_qty_'+id+'" type="number" value="1" min="1" style="width:50px">';
  h+='<select id="asmVF_unit_'+id+'"><option>EA</option><option>LF</option><option>SF</option><option>CF</option><option>LS</option></select>';
  h+='<input id="asmVF_notes_'+id+'" placeholder="Notes..." style="flex:1"></div>';
  h+='<div class="asm-vform-row" style="justify-content:flex-end">';
  h+='<button class="hb" style="font-size:10px;padding:3px 10px" onclick="asmVFormCancel('+si+')">Cancel</button>';
  h+='<button class="hb" style="font-size:10px;padding:3px 10px;color:#a6e3a1;border-color:#a6e3a1" onclick="asmSaveVirtualPart('+si+')">Save</button>';
  h+='</div></div>';
  return h;
}

/* ═══ ASSEMBLY SUMMARY ═══ */
function renderAsmSummary(asm){
  var summary=asm.summary;
  if(!summary||!Object.keys(summary).length)return'';
  var parts=[];
  for(var cat in summary){
    var s=summary[cat];
    var txt=cat+': '+s.qty+' '+((s.qty===1)?'item':'items');
    if(s.lf)txt+=', '+s.lf.toFixed(1)+' LF';
    parts.push(txt);
  }
  return'<div class="asm-summary">'+X(parts.join(' | '))+'</div>';
}

function renderAsmBreakdown(breakdown){
  if(!breakdown||!breakdown.length)return'<div class="asm-bd-empty">No items</div>';
  var h='';
  for(var i=0;i<breakdown.length;i++){
    var b=breakdown[i];
    var cat=b.category||'Uncategorized';
    var bg=getBadgeColor(cat);
    h+='<div class="asm-bd-row">'+
      '<span class="asm-bd-badge" style="background:'+bg+';color:#1e1e2e">'+X(cat)+'</span>'+
      '<span class="asm-bd-count">'+b.count+'</span>'+
      '<span class="asm-bd-pct">'+b.percent+'%</span></div>';
  }
  return h;
}
function getBadgeColor(cat){
  var custom=(CCOL.categories||{})[cat];
  if(custom)return custom;
  return getDefaultColor(cat);
}

/* ═══ ASSEMBLY INTERACTIONS ═══ */
function toggleAsmCard(id){
  var isOpen=!!expandedAssemblies[id];
  if(isOpen){delete expandedAssemblies[id];}else{expandedAssemblies[id]=true;}
  renderAsmPanel();
}
function asmRename(id){
  var a=ASMB[id];if(!a)return;
  showFFModal({
    title:'Rename Assembly',
    fields:[{label:'New Name',id:'name',value:a.name||''}],
    okLabel:'Rename',
    onOk:function(v){
      var nv=v.name.trim();
      if(!nv||nv===(a.name||''))return;
      callJSON('renameAssembly',{asmId:id,newName:nv});
    }
  });
}
function asmSetZone(id){
  var a=ASMB[id];if(!a)return;
  showFFModal({
    title:'Set Zone / Room',
    fields:[{label:'Zone',id:'zone',value:a.zone||'',placeholder:'e.g. Great Room, Kitchen...'}],
    okLabel:'Save',
    onOk:function(v){callJSON('setAsmRoomZone',{asmId:id,zone:v.zone||''});}
  });
}
function asmAddFromSelection(id){
  callJSON('addToAssemblyFromSelection',{asmId:id});
}
function asmAddVirtualPart(id){
  asmVFormOpen[id]=!asmVFormOpen[id];
  renderAsmPanel();
}
function asmVFormCancel(id){
  asmVFormOpen[id]=false;
  renderAsmPanel();
}
function asmSaveVirtualPart(id){
  var name=document.getElementById('asmVF_name_'+id);
  var cat=document.getElementById('asmVF_cat_'+id);
  var qty=document.getElementById('asmVF_qty_'+id);
  var unit=document.getElementById('asmVF_unit_'+id);
  var notes=document.getElementById('asmVF_notes_'+id);
  if(!name||!name.value.trim()){if(name)name.style.borderColor='#f38ba8';return;}
  callJSON('addVirtualPart',{
    asmId:id,
    name:name.value.trim(),
    category:(cat?cat.value:''),
    qty:parseInt(qty?qty.value:'1')||1,
    unit:(unit?unit.value:'EA'),
    notes:(notes?notes.value:'')
  });
  asmVFormOpen[id]=false;
}
function asmEditPart(asmId,partNum){
  var a=ASMB[asmId];if(!a||!a.parts)return;
  var part=null;
  for(var i=0;i<a.parts.length;i++){if(a.parts[i].part_num===partNum){part=a.parts[i];break;}}
  if(!part)return;
  showFFModal({
    title:'Edit Part '+partNum,
    fields:[
      {label:'Name',id:'name',value:part.name||''},
      {label:'Category',id:'category',value:part.category||''},
      {label:'Quantity',id:'quantity',value:String(part.qty||1)},
      {label:'Unit (EA/LF/SF/CF/LS)',id:'unit',value:part.unit||'EA'},
      {label:'Notes',id:'notes',value:part.notes||''}
    ],
    okLabel:'Save',
    onOk:function(v){
      callJSON('updateAsmPart',{asmId:asmId,partNumber:partNum,fields:{
        name:v.name,category:v.category,quantity:parseInt(v.quantity)||1,unit:v.unit,notes:v.notes
      }});
    }
  });
}
function asmDeletePart(asmId,partNum){
  showFFModal({
    title:'Delete Part',
    message:'Delete part '+partNum+'? This cannot be undone.',
    okLabel:'Delete',danger:true,
    onOk:function(){callJSON('deleteAsmPart',{asmId:asmId,partNumber:partNum});}
  });
}
function asmZoomToPart(entityId){
  call('zoomToEntity',String(entityId));
}
function asmExport(id){
  callJSON('exportAssembly',{asmId:id});
}

/* ═══ ASSEMBLY DROPDOWN & FILTERING ═══ */
function buildAsmDD(){
  var sel=document.getElementById('fAsm'),lbl=document.getElementById('fAsmL');
  var keys=Object.keys(ASMB);
  if(!keys.length){sel.value='';sel.style.display='none';if(lbl)lbl.style.display='none';return;}
  var prev=sel.value;
  // Clear stale filter if the selected assembly no longer exists
  if(prev&&!ASMB[prev]){prev='';sel.value='';}
  keys.sort(function(a,b){return(ASMB[a].name||'').toLowerCase().localeCompare((ASMB[b].name||'').toLowerCase());});
  var h='<option value="">All</option>';
  for(var i=0;i<keys.length;i++){var a=ASMB[keys[i]];h+='<option value="'+X(keys[i])+'">'+X(a.name||keys[i])+' ('+getAsmEids(a).length+')</option>';}
  sel.innerHTML=h;
  if(prev)sel.value=prev;
  // Assembly filtering is handled from the assembly tab — keep dropdown hidden
  sel.style.display='none';
  if(lbl)lbl.style.display='none';
}
function filterByAssembly(id){
  var sel=document.getElementById('fAsm');
  sel.value=(sel.value===id)?'':id;
  filt();
  renderAsmPanel();
}
function saveFilteredAsAssembly(){
  showFFModal({
    title:'Create Assembly',
    fields:[
      {label:'Assembly Name',id:'name',value:'',placeholder:'Enter name...'},
      {label:'Zone / Room (optional)',id:'zone',value:'',placeholder:'e.g. Great Room'},
      {label:'Notes (optional)',id:'notes',value:'',placeholder:''}
    ],
    message:'Saves all entities currently visible in the viewport',
    okLabel:'Create',
    onOk:function(v){
      var nm=v.name.trim();if(!nm)return;
      log('Create Assembly: requesting visible entities from Ruby for "'+nm+'"');
      callJSON('createAssemblyFromVisible',{name:nm,notes:v.notes||'',zone:v.zone||''});
    }
  });
}
function createAsmFromSelection(){
  showFFModal({
    title:'Create Assembly from Selection',
    fields:[
      {label:'Assembly Name',id:'name',value:'',placeholder:'Enter name...'},
      {label:'Zone / Room (optional)',id:'zone',value:'',placeholder:'e.g. Great Room'},
      {label:'Notes (optional)',id:'notes',value:'',placeholder:''}
    ],
    message:'Creates an assembly from the entities currently selected in the SketchUp viewport',
    okLabel:'Create',
    onOk:function(v){
      var nm=v.name.trim();if(!nm)return;
      log('Create Assembly from Selection: "'+nm+'"');
      callJSON('createAssemblyFromSelection',{name:nm,notes:v.notes||'',zone:v.zone||''});
    }
  });
}
function deleteAssemblyConfirm(id){
  var a=ASMB[id];
  var name=a?a.name:id;
  showFFModal({
    title:'Delete Assembly',
    message:'Delete assembly "'+name+'"? This cannot be undone.',
    okLabel:'Delete',danger:true,
    onOk:function(){call('deleteAssembly',id);}
  });
}
function editAssemblyNotes(id){
  var a=ASMB[id];if(!a)return;
  showFFModal({
    title:'Notes for "'+X(a.name||id)+'"',
    fields:[{label:'Notes',id:'notes',value:a.notes||''}],
    okLabel:'Save',
    onOk:function(v){callJSON('updateAssembly',{asmId:id,notes:v.notes});}
  });
}
