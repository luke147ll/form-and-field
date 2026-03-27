/* ═══ PROJECT NOTES PANEL ═══ */
var PNOTES=[];
var PN_AUTHORS={};
var _pnTypeFilter={};
var _pnUrgFilter={};
var _pnSort='newest';
var _pnShowResolved=false;
var _pnSearch='';
var _pnExpandedId=null;
var _pnLinkedPid=null;
var _pnLinkedLabel=null;
var _pnEditId=null;
var _pnCompType='GENERAL';
var _pnCompUrg='NORMAL';

var PN_TYPE_COLORS={RFI:'#89b4fa',PUNCH:'#fab387',FIELD:'#94e2d5',CHANGE:'#cba6f7',SAFETY:'#f38ba8',GENERAL:'#a6adc8'};
var PN_TYPE_SHORT={RFI:'RFI',PUNCH:'Punch',FIELD:'Field',CHANGE:'Change',SAFETY:'Safety',GENERAL:'General'};
var PN_TYPE_TIP={RFI:'Request for Information',PUNCH:'Punch List Item',FIELD:'Field Note',CHANGE:'Change Order',SAFETY:'Safety Issue',GENERAL:'General Note'};
var PN_URG_TIP={CRITICAL:'Critical - Requires immediate attention',HIGH:'High Priority',NORMAL:'Normal Priority',LOW:'Low Priority'};
var PN_URG_COLORS={CRITICAL:'#f38ba8',HIGH:'#fab387',NORMAL:'#585b70',LOW:'#45475a'};
var PN_STATUS_NEXT={OPEN:'PROGRESS',PROGRESS:'BLOCKED',BLOCKED:'RESOLVED',RESOLVED:'OPEN'};

function receiveNotes(data){
  if(!data)return;
  PNOTES=data.notes||[];
  if(data.authors)PN_AUTHORS=data.authors;
  heartbeatOff();
  pnRender();
  pnUpdateBadge();
}

function pnRender(){
  var crit=PNOTES.filter(function(n){return n.urgency==='CRITICAL'&&n.status!=='RESOLVED';});
  var banner=document.getElementById('pnCritBanner');
  if(banner){
    if(crit.length>0){banner.style.display='';document.getElementById('pnCritText').textContent=crit.length+' CRITICAL note'+(crit.length>1?'s':'')+' need attention';}
    else banner.style.display='none';
  }
  var oC=0,pC=0,bC=0,rC=0;
  for(var i=0;i<PNOTES.length;i++){
    var s=PNOTES[i].status||'OPEN';
    if(s==='OPEN')oC++;else if(s==='PROGRESS')pC++;else if(s==='BLOCKED')bC++;else if(s==='RESOLVED')rC++;
  }
  var se=document.getElementById('pnStatOpen');if(se)se.textContent=oC;
  se=document.getElementById('pnStatProgress');if(se)se.textContent=pC;
  se=document.getElementById('pnStatBlocked');if(se)se.textContent=bC;
  se=document.getElementById('pnStatResolved');if(se)se.textContent=rC;

  // Type chips
  var tc=document.getElementById('pnTypeChips');
  if(tc){
    var th='';
    var types=['RFI','PUNCH','FIELD','CHANGE','SAFETY','GENERAL'];
    for(var t=0;t<types.length;t++){
      var tp=types[t];
      var cnt=PNOTES.filter(function(n){return n.type===tp&&n.status!=='RESOLVED';}).length;
      th+='<span class="pn-chip tp-'+tp.toLowerCase()+(_pnTypeFilter[tp]?' active':'')+'" onclick="pnToggleType(\''+tp+'\')" title="'+(PN_TYPE_TIP[tp]||tp)+'">'+PN_TYPE_SHORT[tp]+'<span class="pc-count">'+cnt+'</span></span>';
    }
    tc.innerHTML=th;
  }
  // Urgency chips
  var uc=document.getElementById('pnUrgChips');
  if(uc){
    var uh='';
    var urgLevels=['CRITICAL','HIGH','NORMAL','LOW'];
    var urgIcons={CRITICAL:'\u25B2',HIGH:'\u25B3',NORMAL:'\u25CB',LOW:'\u25BD'};
    for(var ui=0;ui<urgLevels.length;ui++){
      var ul=urgLevels[ui];
      var uCnt=PNOTES.filter(function(n){return n.urgency===ul&&n.status!=='RESOLVED';}).length;
      uh+='<span class="pn-chip'+(_pnUrgFilter[ul]?' active':'')+'" style="color:'+(PN_URG_COLORS[ul]||'#585b70')+'" onclick="pnToggleUrg(\''+ul+'\')" title="'+(PN_URG_TIP[ul]||ul)+'">'+urgIcons[ul]+'<span class="pc-count">'+uCnt+'</span></span>';
    }
    uc.innerHTML=uh;
  }
  // Resolved toggle
  var rtgl=document.getElementById('pnResTgl');
  if(rtgl){if(_pnShowResolved)rtgl.classList.add('on');else rtgl.classList.remove('on');}

  // Filter notes
  var filtered=PNOTES.filter(function(n){
    if(!_pnShowResolved&&n.status==='RESOLVED')return false;
    var _hasTypeF=Object.keys(_pnTypeFilter).some(function(k){return _pnTypeFilter[k];});
    if(_hasTypeF&&!_pnTypeFilter[n.type])return false;
    var _hasUrgF=Object.keys(_pnUrgFilter).some(function(k){return _pnUrgFilter[k];});
    if(_hasUrgF&&!_pnUrgFilter[n.urgency])return false;
    if(_pnSearch){
      var q=_pnSearch.toLowerCase();
      if((n.title||'').toLowerCase().indexOf(q)<0&&(n.body||'').toLowerCase().indexOf(q)<0&&(n.author_name||'').toLowerCase().indexOf(q)<0&&(n.entity_label||'').toLowerCase().indexOf(q)<0)return false;
    }
    return true;
  });

  // Sort
  if(_pnSort==='urgency'){
    var urgOrd={CRITICAL:0,HIGH:1,NORMAL:2,LOW:3};
    filtered.sort(function(a,b){return(urgOrd[a.urgency]||2)-(urgOrd[b.urgency]||2)||(b.updated||'').localeCompare(a.updated||'');});
  }else if(_pnSort==='type'){
    filtered.sort(function(a,b){return(a.type||'').localeCompare(b.type||'')||(b.updated||'').localeCompare(a.updated||'');});
  }else{
    filtered.sort(function(a,b){return(b.updated||'').localeCompare(a.updated||'');});
  }

  var list=document.getElementById('pnList');
  var empty=document.getElementById('pnEmpty');
  if(!filtered.length){
    list.innerHTML='';
    empty.style.display='block';
    return;
  }
  empty.style.display='none';
  var h='';
  for(var i=0;i<filtered.length;i++){
    h+=pnRenderCard(filtered[i]);
  }
  list.innerHTML=h;
  pnUpdateBadge();
  setTimeout(function(){checkScrollFade('pnScroll','pnFade');},20);
}

function pnRenderCard(n){
  var tc=PN_TYPE_COLORS[n.type]||'#a6adc8';
  var isExp=(_pnExpandedId===n.id);
  var isRes=(n.status==='RESOLVED');
  var h='<div class="pn-card'+(isRes?' resolved':'')+'" style="border-left-color:'+tc+'">';
  // Header row
  h+='<div class="pn-card-hdr" onclick="pnExpandNote(\''+n.id+'\')">';
  // Author monogram
  var initials=(n.author_name||'??').substring(0,2).toUpperCase();
  h+='<div class="pn-mono" style="background:'+tc+'">'+initials+'</div>';
  // Type tag
  h+='<span class="pn-type-tag" style="color:'+tc+';background:'+tc+'18">'+(n.type||'GEN')+'</span>';
  // Urgency dot
  var urgCls=(n.urgency||'normal').toLowerCase();
  h+='<span class="pn-urg-dot '+urgCls+'"></span>';
  // Title
  h+='<span class="pn-title">'+X(n.title||'Untitled')+'</span>';
  // Status pill
  var stCls=(n.status||'open').toLowerCase();
  h+='<span class="pn-status '+stCls+'" onclick="event.stopPropagation();pnCycleStatus(\''+n.id+'\')" title="Click to cycle status">'+X(n.status||'OPEN')+'</span>';
  h+='</div>';
  // Footer
  h+='<div class="pn-footer">';
  h+='<span class="pn-author">'+X(n.author_name||'??')+'</span>';
  h+='<span style="color:#585b70">&middot;</span>';
  h+='<span>'+pnTimeAgo(n.updated||n.created)+'</span>';
  if(n.entity_pid&&n.entity_label){
    h+='<span class="pn-entity-chip" onclick="event.stopPropagation();call(\'zoomToNoteEntity\',\''+X(n.entity_pid)+'\')">'+X(n.entity_label)+'</span>';
  }
  var rc=(n.responses||[]).length;
  if(rc>0)h+='<span class="pn-replies-count">'+rc+' repl'+(rc>1?'ies':'y')+'</span>';
  h+='</div>';
  // Expanded body
  if(isExp){
    h+='<div class="pn-expanded">';
    if(n.body)h+='<div class="pn-body-text">'+X(n.body)+'</div>';
    // Thread
    var resps=n.responses||[];
    if(resps.length>0){
      h+='<div class="pn-thread">';
      for(var r=0;r<resps.length;r++){
        var rsp=resps[r];
        h+='<div class="pn-resp">';
        h+='<div class="pn-resp-meta"><span class="pn-author">'+X(rsp.author_name||'??')+'</span> &middot; '+pnTimeAgo(rsp.created)+'</div>';
        h+='<div class="pn-resp-body">'+X(rsp.body||'')+'</div>';
        h+='</div>';
      }
      h+='</div>';
    }
    // Reply input
    h+='<div class="pn-reply-row">';
    h+='<input type="text" id="pnReply_'+n.id+'" placeholder="Reply..." onkeydown="if(event.key===\'Enter\')pnSubmitReply(\''+n.id+'\')">';
    h+='<button class="hb" onclick="pnSubmitReply(\''+n.id+'\')" style="font-size:9px;padding:1px 6px;color:#cba6f7;border-color:rgba(203,166,247,0.4)">Send</button>';
    h+='</div>';
    // Actions
    h+='<div class="pn-card-actions">';
    if(n.tag_eid){
      h+='<button class="hb" onclick="event.stopPropagation();call(\'zoomToEntity\',\''+X(String(n.tag_eid))+'\')" style="color:#a6e3a1;border-color:rgba(166,227,161,0.3)" title="Zoom to 3D note tag in model"><svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><circle cx="7" cy="7" r="4"/><line x1="10" y1="10" x2="14" y2="14"/></svg> Zoom</button>';
    }else{
      h+='<button class="hb disabled" style="color:#45475a;border-color:#313244;cursor:default" title="Place a 3D tag first to enable zoom"><svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><circle cx="7" cy="7" r="4"/><line x1="10" y1="10" x2="14" y2="14"/></svg> Zoom</button>';
    }
    h+='<button class="hb" onclick="event.stopPropagation();pnPlaceTag(\''+n.id+'\')" style="color:#94e2d5;border-color:rgba(148,226,213,0.3)" title="Place a 3D tag in the model for this note"><svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path d="M14 10l-4 4H3a1 1 0 01-1-1V3a1 1 0 011-1h10a1 1 0 011 1v7z"/><line x1="5" y1="6" x2="11" y2="6"/><line x1="5" y1="9" x2="9" y2="9"/></svg> Place Tag</button>';
    h+='<button class="hb" onclick="event.stopPropagation();pnEditNote(\''+n.id+'\')" style="color:#89b4fa;border-color:rgba(137,180,250,0.3)">Edit</button>';
    h+='<button class="hb" onclick="event.stopPropagation();pnDeleteNote(\''+n.id+'\')" style="color:#f38ba8;border-color:rgba(243,139,168,0.3)">Delete</button>';
    h+='</div>';
    h+='</div>';
  }
  h+='</div>';
  return h;
}

function pnTimeAgo(ts){
  if(!ts)return'';
  var d=new Date(ts);
  if(isNaN(d.getTime()))return ts;
  var now=new Date();
  var diffMs=now-d;
  var diffMins=Math.floor(diffMs/60000);
  var diffHrs=Math.floor(diffMs/3600000);
  var diffDays=Math.floor(diffMs/86400000);
  if(diffMins<1)return'just now';
  if(diffMins<60)return diffMins+'m ago';
  if(diffHrs<24)return diffHrs+'h ago';
  var opts={month:'short',day:'numeric'};
  if(diffDays>180||d.getFullYear()!==now.getFullYear())opts.year='numeric';
  return d.toLocaleDateString('en-US',opts)+' '+d.toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit'});
}

function pnExpandNote(id){
  _pnExpandedId=(_pnExpandedId===id)?null:id;
  pnRender();
}

function pnCycleStatus(id){
  var n=PNOTES.find(function(n){return n.id===id;});
  if(!n)return;
  var next=PN_STATUS_NEXT[n.status]||'OPEN';
  callJSON('cycleNoteStatus',{noteId:id,newStatus:next});
}

function pnToggleType(tp){_pnTypeFilter[tp]=!_pnTypeFilter[tp];pnRender();}
function pnToggleUrg(u){_pnUrgFilter[u]=!_pnUrgFilter[u];pnRender();}
function pnToggleSort(){
  if(_pnSort==='newest')_pnSort='urgency';
  else if(_pnSort==='urgency')_pnSort='type';
  else _pnSort='newest';
  var btn=document.getElementById('pnSortBtn');
  if(btn)btn.title='Sort: '+_pnSort;
  pnRender();
}
function pnToggleResolved(){_pnShowResolved=!_pnShowResolved;pnRender();}
function pnFilterCritical(){_pnUrgFilter={CRITICAL:true};_pnShowResolved=false;pnRender();}

function pnUpdateBadge(){
  var open=PNOTES.filter(function(n){return n.status!=='RESOLVED';}).length;
  var tab=document.querySelector('.tab[data-tab="notes"]');
  if(tab)tab.innerHTML='Notes'+(open?' <span class="tbadge">'+open+'</span>':'');
}

// ── Composer ──
function pnShowComposer(){
  _pnEditId=null;_pnLinkedPid=null;_pnLinkedLabel=null;
  _pnCompType='GENERAL';_pnCompUrg='NORMAL';
  document.getElementById('pnComposerTitle').textContent='New Note';
  document.getElementById('pnNoteTitle').value='';
  document.getElementById('pnNoteBody').value='';
  document.getElementById('pnLinkedLabel').style.display='none';
  pnRenderCompChips();
  document.getElementById('pnComposer').style.display='';
  document.getElementById('pnNoteTitle').focus();
}
function pnHideComposer(){document.getElementById('pnComposer').style.display='none';}

function pnRenderCompChips(){
  var types=['RFI','PUNCH','FIELD','CHANGE','SAFETY','GENERAL'];
  var th='';
  for(var i=0;i<types.length;i++){
    var tp=types[i];
    th+='<span class="pn-chip tp-'+tp.toLowerCase()+(_pnCompType===tp?' active':'')+'" onclick="pnSetCompType(\''+tp+'\')" title="'+(PN_TYPE_TIP[tp]||tp)+'">'+PN_TYPE_SHORT[tp]+'</span>';
  }
  document.getElementById('pnCompType').innerHTML=th;
  var urgs=['CRITICAL','HIGH','NORMAL','LOW'];
  var uh='';
  for(var i=0;i<urgs.length;i++){
    var u=urgs[i];
    uh+='<span class="pn-chip'+(_pnCompUrg===u?' active':'')+'" style="color:'+(PN_URG_COLORS[u]||'#585b70')+'" onclick="pnSetCompUrg(\''+u+'\')" title="'+(PN_URG_TIP[u]||u)+'">'+u.charAt(0)+'</span>';
  }
  document.getElementById('pnCompUrg').innerHTML=uh;
}
function pnSetCompType(tp){_pnCompType=tp;pnRenderCompChips();}
function pnSetCompUrg(u){_pnCompUrg=u;pnRenderCompChips();}

function pnSubmitNote(){
  var title=document.getElementById('pnNoteTitle').value.trim();
  if(!title){showToast('Title is required','warn');return;}
  var body=document.getElementById('pnNoteBody').value.trim();
  var payload={title:title,body:body,type:_pnCompType,urgency:_pnCompUrg};
  if(_pnLinkedPid){payload.entity_pid=_pnLinkedPid;payload.entity_label=_pnLinkedLabel;}
  if(_pnEditId){payload.id=_pnEditId;}
  callJSON('saveNote',payload);
  pnHideComposer();
}

function pnEditNote(id){
  var n=PNOTES.find(function(n){return n.id===id;});
  if(!n)return;
  _pnEditId=id;
  _pnCompType=n.type||'GENERAL';
  _pnCompUrg=n.urgency||'NORMAL';
  _pnLinkedPid=n.entity_pid||null;
  _pnLinkedLabel=n.entity_label||null;
  document.getElementById('pnComposerTitle').textContent='Edit Note';
  document.getElementById('pnNoteTitle').value=n.title||'';
  document.getElementById('pnNoteBody').value=n.body||'';
  if(_pnLinkedPid&&_pnLinkedLabel){
    var ll=document.getElementById('pnLinkedLabel');
    ll.textContent=_pnLinkedLabel;ll.style.display='';
  }else{
    document.getElementById('pnLinkedLabel').style.display='none';
  }
  pnRenderCompChips();
  document.getElementById('pnComposer').style.display='';
  document.getElementById('pnNoteTitle').focus();
}

function pnPlaceTag(id){
  var n=PNOTES.find(function(n){return n.id===id;});
  if(!n)return;
  callJSON('activateNoteTag',{title:n.title||'',type:n.type||'GENERAL',noteId:n.id});
}

function pnDeleteNote(id){
  showConfirmModal('Delete this note? This cannot be undone.',function(){
    if(_pnExpandedId===id)_pnExpandedId=null;
    call('deleteProjectNote',id);
  });
}

function pnSubmitReply(noteId){
  var inp=document.getElementById('pnReply_'+noteId);
  if(!inp)return;
  var body=inp.value.trim();
  if(!body)return;
  callJSON('addNoteResponse',{noteId:noteId,body:body});
  inp.value='';
}

function pnLinkEntity(){call('getSelectedEntity');}
function pnReceiveLinkedEntity(data){
  if(!data){showToast('Select an entity in the model first','warn');return;}
  _pnLinkedPid=data.pid;
  _pnLinkedLabel=data.label||('Entity '+data.eid);
  var ll=document.getElementById('pnLinkedLabel');
  ll.textContent=_pnLinkedLabel;ll.style.display='';
}

// Create note for entity from other panels
function createNoteForEntity(pid,label){
  switchInfoTab('notes');
  setTimeout(function(){
    pnShowComposer();
    _pnLinkedPid=pid;_pnLinkedLabel=label;
    var ll=document.getElementById('pnLinkedLabel');
    if(ll){ll.textContent=label;ll.style.display='';}
  },200);
}

// Keep formatTimestamp for legacy 3D note tags in measurements panel
function formatTimestamp(ts){
  if(!ts)return'';
  var d=new Date(ts.replace(' ','T'));
  if(isNaN(d.getTime()))return ts;
  var now=new Date();
  var diffMs=now-d;
  var diffMins=Math.floor(diffMs/60000);
  var diffHrs=Math.floor(diffMs/3600000);
  if(diffMins<1)return'just now';
  if(diffMins<60)return diffMins+'m ago';
  if(diffHrs<24)return diffHrs+'h ago';
  return d.toLocaleDateString('en-US',{month:'short',day:'numeric'})+' '+d.toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit'});
}
