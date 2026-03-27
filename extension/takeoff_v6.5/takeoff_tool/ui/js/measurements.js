/* ═══ MEASUREMENT PANEL ═══ */
function populateDebugCatSelect(){
  var sel=document.getElementById('debugCatSelect');if(!sel)return;
  var prev=sel.value,h='<option value="">-- category --</option>';
  for(var i=0;i<CA.length;i++){if(CA[i]==='_IGNORE')continue;h+='<option value="'+X2(CA[i])+'"'+(CA[i]===prev?' selected':'')+'>'+X(CA[i])+'</option>';}
  sel.innerHTML=h;
}
var MEAS=[],openMeasCats={},SCAN_TOTALS={},DERIVED={};
var measTypeFilter={lf:true,sf:true,elev:true,vol:true,count:true,wall:true};
var _linkPickEid=0; // parent card eid when in click-to-link mode
var openMeasConts={};
var MSVG={
  chev:'<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M4 2L8 6L4 10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  eyeOn:ICO_EYE_OPEN,eyeOff:ICO_EYE_CLOSED,
  zoom:'<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><circle cx="5.5" cy="5.5" r="3.5" stroke="currentColor" stroke-width="1.2"/><path d="M8.5 8.5L11 11" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>',
  trash:'<svg width="11" height="11" viewBox="0 0 11 11" fill="none"><path d="M2 3H9L8.3 9.5C8.25 10 7.85 10.3 7.35 10.3H3.65C3.15 10.3 2.75 10 2.7 9.5L2 3Z" stroke="currentColor" stroke-width="1"/><path d="M1 3H10" stroke="currentColor" stroke-width="1" stroke-linecap="round"/><path d="M4 3V1.5C4 1.2 4.2 1 4.5 1H6.5C6.8 1 7 1.2 7 1.5V3" stroke="currentColor" stroke-width="1"/></svg>',
  chain:'<svg width="11" height="11" viewBox="0 0 11 11" fill="none"><path d="M4.5 6.5L6.5 4.5M3.5 8L2.5 9C1.8 9.7 1.8 10.3 2.5 10.5C3.2 10.7 3.8 10.2 4.5 9.5L5.5 8.5M6.5 3L7.5 2C8.2 1.3 8.8 1.3 9.5 2C10.2 2.7 9.7 3.3 9 4L8 5" stroke="currentColor" stroke-width="1" stroke-linecap="round"/></svg>',
  plus:'<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M6 2V10M2 6H10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'
};
var MTYPES={
  lf:   {label:'LF',   color:'#a6e3a1',unit:'LF', icon:'&#10236;'},
  sf:   {label:'SF',   color:'#a6e3a1',unit:'SF', icon:'&#11026;'},
  elev: {label:'Elev', color:'#a6e3a1',unit:"'",  icon:'&#8895;'},
  vol:  {label:'Vol',  color:'#a6e3a1',unit:'CF', icon:'&#10696;'},
  count:{label:'Count',color:'#f9e2af',unit:'EA', icon:'&#9670;'},
  wall: {label:'Wall', color:'#74c7ec',unit:'LF', icon:'&#9640;'}
};
function measTypeKey(mtype,unit){
  if(mtype==='CARD')return 'card';
  if(mtype==='LF')return 'lf';if(mtype==='SF')return 'sf';
  if(mtype==='ELEV')return 'elev';if(mtype==='BOX'||mtype==='VOL')return 'vol';
  if(mtype==='COUNT')return 'count';
  if(mtype==='WALL')return 'wall';
  if(unit==='LF')return 'lf';if(unit==='SF')return 'sf';if(unit==='CF')return 'vol';if(unit==='EA')return 'count';
  return 'lf';
}
function toggleMeasPanel(){toggleMeasSection();}
function receiveMeasurements(data){
  try{
    var d=typeof data==='string'?JSON.parse(data):data;
    if(Array.isArray(d)){MEAS=d;SCAN_TOTALS={};DERIVED={};}
    else{MEAS=d.measurements||[];SCAN_TOTALS=d.scanTotals||{};DERIVED=d.derivedParts||{};}
  }catch(e){MEAS=[];SCAN_TOTALS={};DERIVED={};log('MEAS parse err: '+e.message,'err');}
  updateMeasHdrCnt();
  renderMeasPanel();
  if(typeof renderGroups==='function')renderGroups();
  heartbeatOff();
}

function renderMeasPanel(){
  var search=(document.getElementById('measSearch')||{}).value||'';
  search=search.toLowerCase();

  // Filter measurements
  var filtered=[];
  for(var i=0;i<MEAS.length;i++){
    var m=MEAS[i];
    if(m.type==='NOTE')continue;
    var tk=measTypeKey(m.type,m.unit);
    if(tk!=='card' && !measTypeFilter[tk])continue;
    if(search){
      var hay=((m.partName||'')+(m.category||'')+(m.note||'')+(m.label||'')).toLowerCase();
      if(hay.indexOf(search)===-1)continue;
    }
    filtered.push(m);
  }

  // Filter derived parts
  var filteredDerived={};
  for(var id in DERIVED){
    if(!DERIVED.hasOwnProperty(id))continue;
    var dp=DERIVED[id],dtk=dp.unit==='LF'?'lf':dp.unit==='CF'?'vol':'sf';
    if(!measTypeFilter[dtk])continue;
    if(search){
      var dHay=((dp.name||'')+(dp.category||'')+(dp.note||'')).toLowerCase();
      if(dHay.indexOf(search)===-1)continue;
    }
    filteredDerived[id]=dp;
  }

  // Update type chip counts
  var counts={lf:0,sf:0,elev:0,vol:0,count:0,wall:0};
  for(var ci=0;ci<MEAS.length;ci++){if(MEAS[ci].type==='NOTE'||MEAS[ci].type==='CARD')continue;var tk2=measTypeKey(MEAS[ci].type,MEAS[ci].unit);counts[tk2]=(counts[tk2]||0)+1;}
  var ce=document.getElementById('mcLF');if(ce)ce.textContent=counts.lf;
  ce=document.getElementById('mcSF');if(ce)ce.textContent=counts.sf;
  ce=document.getElementById('mcElev');if(ce)ce.textContent=counts.elev;
  ce=document.getElementById('mcVol');if(ce)ce.textContent=counts.vol;
  ce=document.getElementById('mcCount');if(ce)ce.textContent=counts.count;
  ce=document.getElementById('mcWall');if(ce)ce.textContent=counts.wall;

  // Summary strip
  var sh='';
  var typeKeys=['lf','sf','elev','vol','count','wall'];
  for(var ti=0;ti<typeKeys.length;ti++){
    var tk3=typeKeys[ti],t=MTYPES[tk3];
    if(!measTypeFilter[tk3])continue;
    var total=0;
    for(var fi=0;fi<filtered.length;fi++){if(measTypeKey(filtered[fi].type,filtered[fi].unit)===tk3)total+=filtered[fi].value||0;}
    for(var did in filteredDerived){
      if(!filteredDerived.hasOwnProperty(did))continue;
      var ddp=filteredDerived[did],ddk=ddp.unit==='LF'?'lf':ddp.unit==='CF'?'vol':'sf';
      if(ddk===tk3)total+=(ddp.computedValue||0);
    }
    if(total===0&&tk3!=='elev')continue;
    var disp=tk3==='elev'?filtered.filter(function(m2){return measTypeKey(m2.type,m2.unit)==='elev'}).length+' pts':total.toLocaleString(undefined,{maximumFractionDigits:1})+' '+t.unit;
    sh+='<div class="ms-item"><span class="ms-icon" style="background:'+t.color+'"></span>';
    sh+='<span class="ms-label">'+t.label+':</span>';
    sh+='<span class="ms-val" style="color:'+t.color+'">'+disp+'</span></div>';
  }
  // Visible count
  var visCount=0;
  for(var vi=0;vi<filtered.length;vi++){if(filtered[vi].type!=='CARD'&&filtered[vi].visible)visCount++;}
  sh+='<div style="flex:1"></div>';
  sh+='<button onclick="call(\'exportFFModel\')" style="background:none;border:1px solid var(--peach);border-radius:3px;color:var(--peach);font:500 9px var(--font-mono);padding:2px 8px;cursor:pointer;margin-right:4px" title="Export measurements as FF model (.skp)">\u2191 Export FF</button>';
  sh+='<button onclick="call(\'importFFMeasurements\')" style="background:none;border:1px solid var(--blue);border-radius:3px;color:var(--blue);font:500 9px var(--font-mono);padding:2px 8px;cursor:pointer;margin-right:4px" title="Import FF measurements from .skp">\u2193 Import FF</button>';
  sh+='<button onclick="exportAllMeasCSV()" style="background:none;border:1px solid var(--surface1);border-radius:3px;color:var(--green);font:500 9px var(--font-mono);padding:2px 8px;cursor:pointer;margin-right:6px" title="Export all measurements + parts to CSV">\u2193 Export All</button>';
  sh+='<span style="font-size:10px;color:var(--overlay0)">'+visCount+'/'+filtered.length+' visible</span>';
  var sumEl=document.getElementById('measSummary');
  if(sumEl)sumEl.innerHTML=sh;

  // Check for imported measurements — show banner
  var importedCount=0;
  for(var ic=0;ic<filtered.length;ic++){if(filtered[ic].imported)importedCount++;}

  // Build card HTML
  var h='';
  if(importedCount>0){
    h+='<div style="display:flex;align-items:center;gap:8px;padding:6px 10px;margin:0 0 4px;background:rgba(250,179,135,0.08);border:1px solid rgba(250,179,135,0.25);border-radius:4px">';
    h+='<span style="font-size:9px;font-weight:600;color:var(--peach)">'+importedCount+' IMPORTED</span>';
    h+='<span style="flex:1;font-size:8px;color:var(--overlay0)">Review and commit to keep</span>';
    h+='<button onclick="call(\'commitAllImported\')" style="background:var(--green);color:var(--base);border:none;border-radius:3px;font:600 8px var(--font-mono);padding:2px 8px;cursor:pointer">\u2713 Commit All</button>';
    h+='<button onclick="showConfirmModal(\'Discard all imported measurements?\',function(){call(\'discardAllImported\')})" style="background:none;border:1px solid var(--red);border-radius:3px;color:var(--red);font:600 8px var(--font-mono);padding:2px 8px;cursor:pointer">\u2717 Discard All</button>';
    h+='</div>';
  }

  // Build eid→measurement lookup for VS comparison
  var measByEid={};
  for(var me=0;me<filtered.length;me++){measByEid[filtered[me].eid]=filtered[me];}

  // Track which derived part IDs have been used so we don't duplicate
  var usedDpIds={};

  if(filtered.length===0 && Object.keys(filteredDerived).length===0){
    h='<div class="meas-empty"><svg width="48" height="48" viewBox="0 0 48 48" fill="none"><rect x="4" y="4" width="40" height="40" rx="6" stroke="currentColor" stroke-width="2"/><path d="M14 24H34M24 14V34" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
    h+='<p>No measurements yet.<br>Use + Measure or scan a model.</p></div>';
  } else {
    // For each measurement, build a split card
    for(var mi=0;mi<filtered.length;mi++){
      var mm=filtered[mi];
      var t2=MTYPES[measTypeKey(mm.type,mm.unit)]||MTYPES.lf;
      var isVis=mm.visible;
      var isSFLF=(mm.type==='SF'||mm.type==='LF'||mm.type==='VOL'||mm.type==='COUNT'||mm.type==='WALL');
      var isCard=(mm.type==='CARD');

      // Determine colors
      var mC=mm.sfColor&&mm.sfColor.length>=3?mm.sfColor:(mm.color&&mm.color.length>=3?mm.color:null);
      var accentHex=mC?'rgb('+mC[0]+','+mC[1]+','+mC[2]+')':isCard?'var(--mauve)':t2.color;

      // Label
      var mLabel=isCard?(mm.label||'Untitled'):isSFLF?(mm.label||mm.partName||mm.category||mm.type):(mm.partName||mm.note||mm.category||'Measurement');
      if(mm.type==='BOX'){
        mLabel='BOX: '+fmtDimIn(mm.width_in||0)+'\u00d7'+fmtDimIn(mm.depth_in||0)+'\u00d7'+fmtDimIn(mm.height_in||0);
      }
      if(mm.type==='ELEV'){
        var cl=mm.custom_label||'';
        var elbl=mm.label||('EL. '+mm.value);
        mLabel=cl?(cl+' '+elbl):elbl;
      }

      // Value display
      var valDisp=isCard?'':mm.type==='ELEV'?mm.value.toFixed(1)+"'":fmtMeasVal(mm.value,mm.unit);
      var mUnit=isCard?'':mm.type==='VOL'?'CY':mm.type==='COUNT'?'EA':mm.type==='WALL'?'LF':isSFLF?mm.type:t2.unit;

      // Count display
      var countDisp='';
      if(mm.type==='SF')countDisp=(mm.faceCount||0)+' faces';
      else if(mm.type==='LF')countDisp=(mm.segments||0)+' segs';
      else if(mm.type==='COUNT')countDisp=(mm.markerCount||mm.value||0)+' markers';
      else if(mm.type==='VOL')countDisp=(mm.objectCount||0)+' objs';
      else if(mm.type==='WALL')countDisp=(mm.segmentCount||0)+' segs';

      // Find derived parts for this measurement
      var cardParts=[];
      for(var dpId in filteredDerived){
        if(!filteredDerived.hasOwnProperty(dpId))continue;
        if(usedDpIds[dpId])continue;
        var dpd=filteredDerived[dpId];
        if(dpd.sourceEid && dpd.sourceEid===mm.eid){
          cardParts.push({id:dpId,data:dpd});
          usedDpIds[dpId]=true;
        } else if(dpd.parentMeasEid && dpd.parentMeasEid===mm.eid){
          cardParts.push({id:dpId,data:dpd});
          usedDpIds[dpId]=true;
        } else if(dpd.category===mm.category && (dpd.sourceType==='category_total'||dpd.sourceType==='category_scan')){
          cardParts.push({id:dpId,data:dpd});
          usedDpIds[dpId]=true;
        }
      }

      // Callback names for SF/LF add/remove
      var addCb=mm.type==='SF'?'addSFFaces':mm.type==='LF'?'addLFFaces':mm.type==='VOL'?'addVolObjects':mm.type==='COUNT'?'addCountMarkers':mm.type==='WALL'?'addWallSegments':'';
      var rmCb=mm.type==='SF'?'removeSFFaces':mm.type==='LF'?'removeLFFaces':mm.type==='VOL'?'removeVolObjects':mm.type==='COUNT'?'removeCountMarkers':mm.type==='WALL'?'removeWallSegments':'';

      // ── Card start ──
      var isImported=!!mm.imported;
      h+='<div class="mcard'+(isVis?'':' mcard-hidden')+(isImported?' mcard-imported':'')+'" data-eid="'+mm.eid+'">';

      // Left side
      h+='<div class="mcard-left" style="border-left-color:'+accentHex+'">';

      // Visibility column
      if(!isCard){
        h+='<div class="mcard-vis">';
        h+='<button class="mcard-eye'+(isVis?' on':'')+'" onclick="togMeasVis('+mm.eid+','+(isVis?'false':'true')+')" style="'+(isVis?'color:'+accentHex:'')+'">'+(isVis?MSVG.eyeOn:MSVG.eyeOff)+'</button>';
        if(isSFLF){
          h+='<div class="mcard-dot" style="background:'+accentHex+'" onclick="showSFColorPicker(event,'+mm.eid+',\''+X2(mm.category)+'\')" title="Change color"></div>';
        }
        h+='</div>';
      }

      // Info area
      h+='<div class="mcard-info">';
      // Header: label + category pill
      h+='<div class="mcard-hdr">';
      if(isCard){
        h+='<span class="mcard-label" ondblclick="editCardLabel(this,'+mm.eid+')" title="Double-click to rename">'+X(mLabel)+'</span>';
      } else if(isSFLF){
        h+='<span class="mcard-label" ondblclick="editSFLabel(this,'+mm.eid+')" title="Double-click to rename">'+X(mLabel)+'</span>';
      } else if(mm.type==='ELEV'){
        h+='<span class="mcard-label" ondblclick="editElevLabel('+mm.eid+',this)" title="Double-click to rename">'+X(mLabel)+'</span>';
      } else {
        h+='<span class="mcard-label">'+X(mLabel)+'</span>';
      }
      if(!isCard)h+='<span class="mcard-pill">'+X(mm.category||'Custom')+'</span>';
      if(isImported)h+='<span class="mcard-pill" style="background:var(--peach);color:var(--base);font-weight:600">IMPORTED</span>';
      if(mm.committedBy)h+='<span class="mcard-pill" style="background:var(--blue);color:var(--base);font-weight:500" title="Committed from '+X(mm.committedBy)+'">'+X(mm.committedBy)+'</span>';
      h+='</div>';
      // Value row
      if(!isCard){
        h+='<div class="mcard-val-row">';
        h+='<span class="mcard-val" style="color:'+accentHex+'">'+valDisp+'</span>';
        if(mm.type!=='ELEV')h+='<span class="mcard-unit">'+mUnit+'</span>';
        if(countDisp)h+='<span class="mcard-count">'+countDisp+'</span>';
        h+='</div>';
      }
      // VS Comparison delta row
      var vsOther=null;
      if(mm.vsTarget && measByEid[mm.vsTarget]){
        // This is the local comparison card — vsTarget points to the imported card
        vsOther=measByEid[mm.vsTarget];
      } else if(mm.vsLocal && measByEid[mm.vsLocal]){
        // This is the imported card — vsLocal points to the local comparison card
        vsOther=measByEid[mm.vsLocal];
      }
      if(vsOther && !isCard){
        var myVal=mm.value||0, theirVal=vsOther.value||0;
        var delta,deltaLabel;
        if(mm.vsTarget){
          // I'm the local card, they are the imported card
          delta=myVal-theirVal;
          deltaLabel='vs Imported: '+fmtMeasVal(theirVal,mUnit)+' '+mUnit;
        } else {
          // I'm the imported card, they are the local card
          delta=theirVal-myVal;
          deltaLabel='Local: '+fmtMeasVal(theirVal,mUnit)+' '+mUnit;
        }
        var dSign=delta>0?'+':delta<0?'\u2212':'';
        var dColor=Math.abs(delta)<0.1?'var(--overlay0)':(delta>0?'var(--green)':'var(--red)');
        var dAbs=Math.abs(delta);
        h+='<div style="margin-top:2px;padding:3px 0;border-top:1px dashed var(--surface1);display:flex;align-items:center;gap:6px;font-size:9px">';
        h+='<span style="color:var(--peach);font-weight:600">VS</span>';
        h+='<span style="color:var(--overlay0)">'+deltaLabel+'</span>';
        h+='<span style="color:'+dColor+';font-weight:700">\u0394 '+dSign+dAbs.toFixed(1)+' '+mUnit+'</span>';
        h+='</div>';
      }
      // Wall segment details (consolidated by nominal + height)
      if(mm.type==='WALL'&&mm.wallDetails&&mm.wallDetails.length){
        h+='<div style="margin-top:3px;padding:3px 0;border-top:1px solid var(--surface0)">';
        for(var wi=0;wi<mm.wallDetails.length;wi++){
          var wd=mm.wallDetails[wi];
          var cnt=wd.count||1;
          h+='<div style="font-size:9px;color:var(--subtext0);line-height:1.6;display:flex;align-items:baseline">';
          h+='<span style="color:var(--sapphire);font-weight:600;width:32px;flex:none">'+(wd.nominal||'?')+'</span>';
          h+='<span style="flex:1">'+(wd.lf||0)+'\' L <span style="color:var(--overlay0)">\u00d7</span> '+(wd.h||0)+'\' H</span>';
          if(cnt>1)h+='<span style="color:var(--text);font-weight:600;flex:none;text-align:right">'+cnt+'\u00d7</span>';
          h+='</div>';
        }
        h+='</div>';
      }
      h+='</div>'; // end mcard-info

      // Action buttons
      h+='<div class="mcard-acts">';
      // VS compare button — available on any measurable card without an existing comparison
      if(isSFLF && !mm.vsLocal && !mm.vsTarget){
        h+='<button class="mcard-act" onclick="call(\'startMeasComparison\',JSON.stringify({eid:'+mm.eid+',type:\''+mm.type+'\',category:\''+X2(mm.category||'')+'\'}))" title="Compare \u2014 measure locally and see the difference" style="color:var(--peach);font-weight:700;font-size:9px">VS</button>';
      }
      if(isImported){
        h+='<button class="mcard-act" onclick="call(\'commitImportedMeasurement\',\''+mm.eid+'\')" title="Commit to model" style="color:var(--green);font-size:11px">\u2713</button>';
        h+='<button class="mcard-act del" onclick="call(\'discardImportedMeasurement\',\''+mm.eid+'\')" title="Discard">\u2717</button>';
      } else {
        if(!isCard && addCb){
          var addTip=mm.type==='VOL'?'Add objects':mm.type==='COUNT'?'Add markers':mm.type==='WALL'?'Add segments':'Add faces';
          var rmTip=mm.type==='VOL'?'Remove objects':mm.type==='COUNT'?'Remove markers':mm.type==='WALL'?'Remove segments':'Remove faces';
          h+='<button class="mcard-act add" onclick="call(\''+addCb+'\',JSON.stringify({eid:'+mm.eid+',category:\''+X2(mm.category)+'\'}))" title="'+addTip+'">+</button>';
          h+='<button class="mcard-act sub" onclick="call(\''+rmCb+'\',\''+mm.eid+'\')" title="'+rmTip+'">&minus;</button>';
        }
        if(!isCard)h+='<button class="mcard-act exp" onclick="exportMeasCSV('+mm.eid+')" title="Export CSV">\u2193</button>';
        if(!isCard && addCb)h+='<button class="mcard-act" onclick="startCombine('+mm.eid+')" title="Combine with another card" style="color:#94e2d5;font-size:10px">\u2295</button>';
        h+='<button class="mcard-act del" onclick="delMeas('+mm.eid+')" title="Delete">\u00d7</button>';
      }
      h+='</div>';

      h+='</div>'; // end mcard-left

      // Right side — derived parts
      h+='<div class="mcard-right">';
      if(isImported){
        // Imported cards: show source info instead of parts builder
        h+='<div class="mcard-parts-hdr">';
        h+='<span class="mcard-parts-title" style="color:var(--peach)">Imported</span>';
        h+='</div>';
        h+='<div style="padding:4px 8px;font-size:8px;color:var(--overlay0)">From: '+X(mm.importSource||'Unknown')+'</div>';
        h+='<div style="padding:0 8px 4px;display:flex;gap:4px">';
        if(isSFLF && !mm.vsLocal){
          h+='<button onclick="call(\'startMeasComparison\',JSON.stringify({eid:'+mm.eid+',type:\''+mm.type+'\',category:\''+X2(mm.category||'')+'\'}))" style="flex:1;background:var(--peach);color:var(--base);border:none;border-radius:3px;font:700 8px var(--font-mono);padding:3px 6px;cursor:pointer">VS Compare</button>';
        }
        h+='<button onclick="call(\'commitImportedMeasurement\',\''+mm.eid+'\')" style="flex:1;background:var(--green);color:var(--base);border:none;border-radius:3px;font:600 8px var(--font-mono);padding:3px 6px;cursor:pointer">\u2713 Commit</button>';
        h+='<button onclick="call(\'discardImportedMeasurement\',\''+mm.eid+'\')" style="flex:1;background:none;border:1px solid var(--red);border-radius:3px;color:var(--red);font:600 8px var(--font-mono);padding:3px 6px;cursor:pointer">\u2717 Discard</button>';
        h+='</div>';
      } else {
      h+='<div class="mcard-parts-hdr">';
      h+='<span class="mcard-parts-title">Parts</span>';
      h+='<button class="mcard-parts-add" onclick="openPB('+mm.eid+',\''+X2(mm.category)+'\',\''+X2(mm.type||'SF')+'\')">+ part</button>';
      h+='<button class="mcard-parts-add" onclick="showAddPartForm('+mm.eid+',\''+X2(mm.category)+'\',\''+X2(mm.type||'SF')+'\')" style="color:var(--overlay0);font-size:8px" title="Legacy add part">+ link</button>';
      h+='</div>';
      // Wall inline parts (studs + plates computed from wall data)
      var wallParts=(mm.type==='WALL')?computeWallParts(mm):[];
      if(wallParts.length){
        for(var wp=0;wp<wallParts.length;wp++){
          var wpt=wallParts[wp];
          var wpColor=wpt.type==='stud'?'var(--sapphire)':'var(--green)';
          var wpCode=wpt.type==='stud'?'ST':'PL';
          h+='<div class="mcard-part" style="flex-wrap:wrap">';
          h+='<span class="pb-ico" style="background:'+wpColor+';font-size:7px;width:18px;height:18px;line-height:18px">'+wpCode+'</span>';
          h+='<span class="mcard-part-name" style="color:'+wpColor+'">'+X(wpt.label)+'</span>';
          h+='<span class="mcard-part-order">'+wpt.qty+'</span>';
          h+='<span class="mcard-part-unit">'+wpt.unit+'</span>';
          h+='<div style="width:100%;padding-left:24px;font-size:8px;color:var(--overlay0)">'+X(wpt.detail)+'</div>';
          h+='</div>';
        }
      }
      if(cardParts.length===0 && wallParts.length===0){
        h+='<div class="mcard-noparts">No derived parts</div>';
      } else if(cardParts.length>0) {
        for(var pi=0;pi<cardParts.length;pi++){
          var pp=cardParts[pi],ppd=pp.data;

          // Parts Builder parts — use typed renderer
          if(ppd.partBuilder && ppd.pbType && PB_TYPES[ppd.pbType]){
            h+=pbPartRow(pp,ppd);
            continue;
          }

          var pVal=ppd.computedValue||0;
          var pUnit=ppd.unit||'SF';
          var pWaste=(ppd.multiplier&&ppd.multiplier!==1)?(' ('+(ppd.multiplier>1?'+':'')+Math.round((ppd.multiplier-1)*100)+'%)'):'';
          var isScan=ppd.sourceType==='category_scan';

          // For beam inventory scans, show a compact summary
          if(isScan && ppd.beamInventory && ppd.beamInventory.length>0){
            var biPcs=0,biLF=0;
            for(var bs=0;bs<ppd.beamInventory.length;bs++){biPcs+=ppd.beamInventory[bs].count;biLF+=ppd.beamInventory[bs].totalLF;}
            h+='<div class="mcard-part">';
            h+='<span class="mcard-part-name" style="color:var(--peach)">Beam Inv ('+ppd.beamInventory.length+' sizes)</span>';
            h+='<span class="mcard-part-val">'+biPcs+' pcs</span>';
            h+='<span class="mcard-part-unit">EA</span>';
            h+='<button class="mcard-part-del" onclick="delDerived(\''+X2(pp.id)+'\')" title="Delete">\u00d7</button>';
            h+='</div>';
          } else {
            var isTool=ppd.sourceType==='tool_sf'||ppd.sourceType==='tool_poly_sf'||ppd.sourceType==='tool_lf'||ppd.sourceType==='tool_vol';
            var isLinked=ppd.sourceType==='linked';
            var hasGeo=isTool||isLinked;
            var pVis=ppd.visible!==false;
            var nameStyle='';
            if(isScan)nameStyle=' style="color:var(--green)"';
            else if(isLinked && ppd.linkedColor && ppd.linkedColor.length>=3)nameStyle=' style="color:rgb('+ppd.linkedColor[0]+','+ppd.linkedColor[1]+','+ppd.linkedColor[2]+')"';
            else if(isTool)nameStyle=' style="color:var(--sapphire)"';
            h+='<div class="mcard-part'+(hasGeo&&!pVis?' mcard-part-off':'')+'">';
            if(hasGeo && ppd.sourceEid){
              var eyeColor=isLinked&&ppd.linkedColor?'color:rgb('+ppd.linkedColor[0]+','+ppd.linkedColor[1]+','+ppd.linkedColor[2]+')':'';
              h+='<button class="mcard-part-eye'+(pVis?' on':'')+'" onclick="togPartVis('+ppd.sourceEid+','+(pVis?'false':'true')+')" title="'+(pVis?'Hide':'Show')+'"'+(pVis&&eyeColor?' style="'+eyeColor+'"':'')+'>'+ICO_EYE_SM+'</button>';
            }
            h+='<span class="mcard-part-name"'+nameStyle+'>'+X(ppd.name||'Part')+'</span>';
            h+='<span class="mcard-part-val">'+pVal.toLocaleString(undefined,{maximumFractionDigits:1})+'</span>';
            if(pWaste)h+='<span class="mcard-part-waste">'+pWaste+'</span>';
            h+='<span class="mcard-part-unit">'+pUnit+'</span>';
            if(hasGeo && ppd.sourceEid){
              var gt=ppd.grpType||'SF';
              var addCbP=gt==='LF'?'addLFFaces':'addSFFaces';
              var rmCbP=gt==='LF'?'removeLFFaces':'removeSFFaces';
              h+='<button class="mcard-part-add" onclick="call(\''+addCbP+'\',JSON.stringify({eid:'+ppd.sourceEid+',category:\''+X2(ppd.category||'')+'\'}))" title="Add faces">+</button>';
              h+='<button class="mcard-part-sub" onclick="call(\''+rmCbP+'\',\''+ppd.sourceEid+'\')" title="Remove faces">&minus;</button>';
            }
            // + part button: create PB part from this linked/tool card's value
            if((isLinked||isTool)&&ppd.sourceEid&&pVal>0){
              h+='<button class="mcard-parts-add" onclick="openPBFromLinked('+mm.eid+','+ppd.sourceEid+','+pVal+',\''+X2(pUnit)+'\',\''+X2(ppd.name||'Linked')+'\',\''+X2(mm.category||'')+'\')" title="Create part from '+X(ppd.name||'this')+'" style="font-size:7px;padding:1px 4px">+P</button>';
            }
            h+='<button class="mcard-part-del" onclick="delDerived(\''+X2(pp.id)+'\')" title="Delete">\u00d7</button>';
            h+='</div>';
          }
        }
      }
      // Inline add-part form (hidden by default)
      h+='<div class="apf" id="apf_'+mm.eid+'">';
      h+='<div class="apf-row"><span class="apf-label">Name</span><input class="apf-input" id="apfN_'+mm.eid+'" placeholder="e.g. Underlayment" /></div>';
      h+='<div class="apf-row"><span class="apf-label">Source</span><select class="apf-select" id="apfSrc_'+mm.eid+'" onchange="apfSrcChange('+mm.eid+')">';
      if(!isCard)h+='<option value="measurement">From this measurement</option>';
      h+='<option value="tool_sf">Measure SF (Face)</option>';
      h+='<option value="tool_poly_sf">Measure SF (Poly)</option>';
      h+='<option value="tool_lf">Measure LF</option>';
      h+='<option value="tool_vol">Measure Volume</option>';
      h+='<option value="linked">Link existing card</option>';
      h+='<option value="manual">Manual value</option>';
      h+='</select></div>';
      h+='<div class="apf-row" id="apfLinkRow_'+mm.eid+'" style="display:none"><span class="apf-label">Card</span><select class="apf-select" id="apfLink_'+mm.eid+'" onchange="apfLinkChange('+mm.eid+')" style="flex:1"></select><span style="font-size:8px;color:var(--overlay0);margin-left:4px;white-space:nowrap">or click a card</span></div>';
      h+='<div class="apf-row" id="apfMultRow_'+mm.eid+'"'+(isCard?' style="display:none"':'')+' ><span class="apf-label">Waste %</span><input class="apf-input" id="apfMult_'+mm.eid+'" type="number" step="1" value="0" style="width:60px;flex:none" oninput="apfWastePreview('+mm.eid+','+mm.value+')" />';
      h+='<span id="apfPrev_'+mm.eid+'" style="font-size:9px;color:var(--overlay0);margin-left:4px">= '+fmtMeasVal(mm.value,mm.unit)+'</span></div>';
      h+='<div class="apf-row" id="apfManRow_'+mm.eid+'" style="display:none"><span class="apf-label">Value</span><input class="apf-input" id="apfManVal_'+mm.eid+'" type="number" step="0.1" value="0" style="width:90px;flex:none" /></div>';
      h+='<div class="apf-row" id="apfUnitRow_'+mm.eid+'"><span class="apf-label">Unit</span><select class="apf-select" id="apfUnit_'+mm.eid+'" style="width:70px;flex:none">';
      var defUnit=mm.type==='LF'?'LF':mm.type==='BOX'?'CF':mm.type==='VOL'?'CY':'SF';
      h+='<option value="SF"'+(defUnit==='SF'?' selected':'')+'>SF</option>';
      h+='<option value="LF"'+(defUnit==='LF'?' selected':'')+'>LF</option>';
      h+='<option value="CF"'+(defUnit==='CF'?' selected':'')+'>CF</option>';
      h+='<option value="CY"'+(defUnit==='CY'?' selected':'')+'>CY</option>';
      h+='<option value="EA">EA</option>';
      h+='</select></div>';
      h+='<div class="apf-btns">';
      h+='<button class="apf-btn cancel" onclick="hideAddPartForm('+mm.eid+')">Cancel</button>';
      h+='<button class="apf-btn save" onclick="submitAddPart('+mm.eid+',\''+X2(mm.category)+'\')">Create</button>';
      h+='</div></div>';
      } // end if(!isImported) parts section

      h+='</div>'; // end mcard-right

      h+='</div>'; // end mcard
    }

    // Orphan derived parts — not matched to any measurement
    for(var orphId in filteredDerived){
      if(!filteredDerived.hasOwnProperty(orphId))continue;
      if(usedDpIds[orphId])continue;
      var odp=filteredDerived[orphId];
      var odt=odp.unit==='LF'?MTYPES.lf:odp.unit==='CF'?MTYPES.vol:MTYPES.sf;
      var oVal=odp.computedValue||0;
      var oIsScan=odp.sourceType==='category_scan';

      h+='<div class="mcard">';
      h+='<div class="mcard-left" style="border-left-color:'+odt.color+'">';
      h+='<div class="mcard-vis">';
      h+='<div style="width:20px;height:20px;display:flex;align-items:center;justify-content:center;color:var(--mauve);opacity:.5">'+MSVG.chain+'</div>';
      h+='</div>';
      h+='<div class="mcard-info">';
      h+='<div class="mcard-hdr">';
      h+='<span class="mcard-label"'+(oIsScan?' style="color:var(--green)"':'')+'>'+X(odp.name||'Derived Part')+'</span>';
      h+='<span class="mcard-pill">'+X(odp.category||'Custom')+'</span>';
      h+='</div>';
      h+='<div class="mcard-val-row">';
      h+='<span class="mcard-val" style="color:'+odt.color+'">'+oVal.toLocaleString(undefined,{maximumFractionDigits:1})+'</span>';
      h+='<span class="mcard-unit">'+(odp.unit||'SF')+'</span>';
      if(odp.multiplier&&odp.multiplier!==1)h+='<span class="mcard-count">x'+odp.multiplier+'</span>';
      h+='</div>';
      h+='</div>';
      h+='<div class="mcard-acts">';
      h+='<button class="mcard-act del" onclick="delDerived(\''+X2(orphId)+'\')" title="Delete">\u00d7</button>';
      h+='</div>';
      h+='</div>'; // end mcard-left
      h+='<div class="mcard-right">';
      h+='<div class="mcard-noparts" style="padding:8px 0;font-style:normal;color:var(--overlay0);font-size:9px">Standalone derived part</div>';
      h+='</div>';
      h+='</div>'; // end mcard
    }

    // Add measurement card
    h+='<div class="mcard-add-form" id="measAddForm" style="display:none">';
    h+='<div style="display:flex;gap:6px;align-items:center">';
    h+='<input id="measAddLabel" class="apf-input" placeholder="Card name" style="flex:1;font-size:11px;padding:4px 8px" onkeydown="if(event.key===\'Enter\'){measAddCreate();event.preventDefault();}">';
    h+='<button class="maf-btn" onclick="measAddCreate()" style="color:var(--green);border-color:rgba(166,227,161,.3)">Create</button>';
    h+='<button class="maf-btn" onclick="measAddCancel()" style="color:var(--overlay0);border-color:var(--surface1)">Cancel</button>';
    h+='</div>';
    h+='</div>';
    h+='<div style="display:flex;gap:6px">';
    h+='<div class="mcard-add" id="measAddBtn" onclick="measAddShow()" style="flex:1">';
    h+=MSVG.plus+' Add card</div>';
    h+='<div class="mcard-add" onclick="measCountNew()" style="flex:none;padding:6px 12px;color:#f9e2af">';
    h+='&#9670; Count</div>';
    h+='<div class="mcard-add" onclick="measWallNew()" style="flex:none;padding:6px 12px;color:#74c7ec">';
    h+='&#9640; Wall</div>';
    h+='</div>';
  }

  document.getElementById('measBody').innerHTML=h;
  if(_linkPickEid)applyLinkPickClasses();
  setTimeout(function(){checkScrollFade('measScroll','measFade');},20);
}

/* ── Meas helpers ── */
function fmtDimIn(inches){if(!inches||inches<0.1)return"0'-0\"";var ft=Math.floor(inches/12),ins=Math.floor(inches-ft*12);return ft+"'-"+ins+'"';}
function fmtMeasVal(val,unit){
  if(unit==='')return'';
  if(!val&&val!==0)return'--';
  if(unit==='SF')return val.toFixed(1)+' SF';
  if(unit==='LF')return val.toFixed(1)+' LF';
  if(unit==='CF')return val.toFixed(1)+' CF';
  if(unit==='CY')return val.toFixed(2)+' CY';
  if(unit==='EA')return Math.round(val)+' EA';
  if(unit==='feet'){var ft=Math.floor(val),inc=Math.round(Math.abs(val-ft)*12);if(inc>=12){ft+=(val>=0?1:-1);inc=0;}return ft+"'-"+inc+'"';}
  if(unit==='meters')return val.toFixed(3)+' m';
  if(unit==='inches')return val.toFixed(1)+'"';
  return val.toFixed(1);
}
function togMeasType(type,el){measTypeFilter[type]=!measTypeFilter[type];el.classList.toggle('active',measTypeFilter[type]);renderMeasPanel();}
function togMeasCont(name){openMeasConts[name]=openMeasConts[name]===false?true:false;renderMeasPanel();}
function togMeasCat(cat){openMeasCats[cat]=openMeasCats[cat]===false?true:false;renderMeasPanel();}
function togMeasVis(eid,show){var s=show==='true'||show===true;callJSON('toggleMeasurement',{eid:eid,show:s});for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){MEAS[i].visible=s;break;}}renderMeasPanel();}
function togPartVis(srcEid,show){var s=show==='true'||show===true;callJSON('toggleMeasurement',{eid:srcEid,show:s});for(var k in DERIVED){if(DERIVED.hasOwnProperty(k)&&DERIVED[k].sourceEid===srcEid){DERIVED[k].visible=s;}}renderMeasPanel();}
function zoomMeas(eid){call('zoomToMeasurement',''+eid);}
function showAllMeas(){call('showAllMeasurements');}
function hideAllMeas(){call('hideAllMeasurements');}
function recalcSF(){call('recalculateSF');}
function hideMeasurements(){call('hideAllMeasurements');}
function delMeas(eid){showConfirmModal('Delete this measurement? This cannot be undone.',function(){call('deleteMeasurement',''+eid);MEAS=MEAS.filter(function(m){return m.eid!==eid;});clrScanHL();updateMeasHdrCnt();renderMeasPanel();});}

/* ── Combine ── */
var _combineTargetEid=0;
function startCombine(targetEid){
  var target=MEAS.find(function(m){return m.eid===targetEid;});
  if(!target)return;
  var compat=MEAS.filter(function(m){
    return m.eid!==targetEid && m.type===target.type && !m.partLink && !m.imported;
  });
  if(!compat.length){showToast('No compatible cards to combine with','warning');return;}
  _combineTargetEid=targetEid;
  var el=document.getElementById('combineList');
  var h='';
  for(var i=0;i<compat.length;i++){
    var c=compat[i];
    var clr=c.sfColor?'rgb('+c.sfColor[0]+','+c.sfColor[1]+','+c.sfColor[2]+')':'var(--green)';
    var val=c.value!=null?c.value.toLocaleString(undefined,{maximumFractionDigits:2}):'0';
    var unit=c.unit||c.type;
    var lbl=c.label||c.partName||c.category||'Measurement';
    var cat=c.category||'';
    h+='<div class="comb-row" onclick="doCombine('+c.eid+')">';
    h+='<span class="comb-dot" style="background:'+clr+'"></span>';
    h+='<span class="comb-lbl">'+X(lbl)+'</span>';
    h+='<span class="comb-val">'+val+' '+X(unit)+'</span>';
    if(cat)h+='<span class="comb-cat">'+X(cat)+'</span>';
    h+='</div>';
  }
  el.innerHTML=h;
  document.getElementById('combineModal').className='modal-bg show';
}
function doCombine(sourceEid){
  document.getElementById('combineModal').className='modal-bg';
  if(!_combineTargetEid)return;
  call('combineMeasurements',JSON.stringify({targetEid:_combineTargetEid,sourceEid:sourceEid}));
  _combineTargetEid=0;
}
function cancelCombine(){
  document.getElementById('combineModal').className='modal-bg';
  _combineTargetEid=0;
}

/* ── CSV helpers ── */
function Q(s){return '"'+((s==null?'':s).toString().replace(/"/g,'""'))+'"';}
function csvSafe(s){return (s||'').replace(/\u2014/g,'-').replace(/\u2013/g,'-').replace(/\u00d7/g,'x').replace(/[\u2018\u2019]/g,"'").replace(/[\u201c\u201d]/g,'"');}
function measCleanUnit(mm){
  if(mm.type==='SF')return 'SF';if(mm.type==='LF')return 'LF';
  if(mm.type==='VOL')return 'CF';if(mm.type==='COUNT')return 'EA';
  if(mm.type==='WALL')return 'LF';if(mm.type==='ELEV')return 'FT';return mm.unit||'';
}
var CSV_HDR='Parent,Category,Cost Code,Part,Qty,Height/Length,Type,Unit,Waste %,Order Desc\n';
function csvRow(parent,cat,cc,part,qty,heightLen,type,unit,waste,orderDesc){
  return Q(csvSafe(parent))+','+Q(csvSafe(cat))+','+Q(csvSafe(cc))+','
    +Q(csvSafe(part))+','
    +(qty===''||qty==null?'':Math.round(qty*100)/100)+','
    +(heightLen===''||heightLen==null?'':Math.round(heightLen*100)/100)+','
    +type+','+unit+','
    +(waste===''||waste===0||waste==null?'':waste)+','
    +Q(csvSafe(orderDesc));
}
function csvMeasRows(mm){
  var label=mm.label||mm.partName||mm.category||'Measurement';
  var cat=mm.category||'';
  var cc=mm.costCode||'';
  var unit=measCleanUnit(mm);
  var rows=[csvRow(label,cat,cc,'',mm.value,'','Measurement',unit,'','')];
  if(mm.type==='WALL'){
    var cfg=mm.wallConfig||{};
    var details=mm.wallDetails||[];
    var oc=mm.ocSpacing||cfg.oc_spacing||16;
    var waste=cfg.waste_pct||5;
    // Stud rows per nominal+height group
    for(var di=0;di<details.length;di++){
      var d=details[di],cnt=d.count||1;
      var wallIn=(d.lf||0)*12;
      var studs=Math.ceil(wallIn/oc);
      studs=Math.ceil(studs*(1+waste/100));
      rows.push(csvRow(label,cat,cc,(d.nominal||'?')+' Studs',studs,d.h||'','ST','EA',waste,studs+' studs '+oc+'" OC'));
    }
    // Plate rows per nominal
    var plates=cfg.plates||[];
    if(plates.length){
      var lfByNom={};
      for(var ni=0;ni<details.length;ni++){
        var dn=details[ni],nom=dn.nominal||'?';
        lfByNom[nom]=(lfByNom[nom]||0)+(dn.lf||0);
      }
      for(var nom in lfByNom){
        if(!lfByNom.hasOwnProperty(nom))continue;
        var nomLF=lfByNom[nom];
        for(var j=0;j<plates.length;j++){
          var p=plates[j];
          var mult=p.multiplier||1;
          var pLF=nomLF*mult*(1+waste/100);
          pLF=Math.ceil(pLF*10)/10;
          var sLen=p.stickLen||16;
          var sticks=Math.ceil(pLF/sLen);
          rows.push(csvRow(label,cat,cc,nom+' '+(p.material||'Plate')+' ('+mult+'x)',sticks,sLen,'PL','sticks',waste,sticks+' @ '+sLen+"' = "+pLF.toFixed(1)+' LF'));
        }
      }
    }
  }
  return rows;
}
/* PB type code map */
function pbTypeCode(t){
  var m={sheets:'SH',linear:'LN',rolls:'RL',framing:'WF',oncenter:'OC',coverage:'CV',custom:'FX'};
  return m[t]||'FX';
}
/* Build CSV rows for a Parts Builder derived part */
function pbCSVRows(dp,parentVal,parentLabel,cc,cat){
  if(!dp.partBuilder||!dp.pbType||!dp.cfg)return null;
  var r=pbCompute(dp.pbType,parentVal,dp.cfg);
  if(!r)return null;
  var w=dp.cfg.waste||0;
  var name=csvSafe(dp.cfg.name||dp.name||'Part');
  var rows=[];
  if(r.compound&&r.lines){
    var ln0=r.lines[0];
    var studLen=dp.cfg.studLen||8;
    var oc=dp.cfg.ocSpacing||16;
    var wh=dp.cfg.wallHeight||8;
    rows.push(csvRow(parentLabel,cat,cc,name+' - Studs',ln0.sticks,wh,'WF','EA',w,oc+'" OC '+studLen+"' studs"));
    var plates=dp.cfg.plates||[];
    for(var li=1;li<r.lines.length;li++){
      var ln=r.lines[li];
      var pc=plates[li-1]||{};
      var pm=csvSafe(ln.material||'Plate');
      var sLen=pc.stickLen||16;
      rows.push(csvRow(parentLabel,cat,cc,name+' - '+pm,ln.sticks,sLen,'PL','sticks',w,(pc.multiplier>1?pc.multiplier+'x ':'')+'= '+ln.lf.toFixed(1)+' LF'));
    }
  } else if(dp.pbType==='sheets'){
    var sw=dp.cfg.sheetW||4;var sh=dp.cfg.sheetH||8;
    rows.push(csvRow(parentLabel,cat,cc,name,r.order,'','SH','sheets',w,sw+"'x"+sh+"' sheets"));
  } else if(dp.pbType==='linear'){
    var sl=dp.cfg.stickLen||12;
    rows.push(csvRow(parentLabel,cat,cc,name,r.order,sl,'LN','sticks',w,r.raw.toFixed(1)+' LF'));
  } else if(dp.pbType==='rolls'){
    var cov=dp.cfg.coverage||150;var cu=dp.cfg.covUnit||'SF';
    rows.push(csvRow(parentLabel,cat,cc,name,r.order,'','RL','rolls',w,cov+' '+(cu||'SF')+'/roll'));
  } else if(dp.pbType==='oncenter'){
    var sp=dp.cfg.spacing||32;var su=dp.cfg.spaceUnit||'in';
    var spLbl=su==='in'?(sp+'"'):(sp+"'");
    rows.push(csvRow(parentLabel,cat,cc,name,r.order,'','OC','EA',w,spLbl+' O.C.'));
  } else if(dp.pbType==='coverage'){
    var cr=dp.cfg.coverageRate||350;var cvu=dp.cfg.covUnit||'SF/gal';
    var cvParts=cvu.split('/');var ouLbl=cvParts.length>1?cvParts[1]:'units';
    var coats=dp.cfg.coats||1;
    rows.push(csvRow(parentLabel,cat,cc,name,r.order,'','CV',ouLbl,w,cr+' '+cvu+(coats>1?', '+coats+' coats':'')));
  } else if(dp.pbType==='custom'){
    var ru=dp.cfg.resultUnit||'units';
    rows.push(csvRow(parentLabel,cat,cc,name,r.order,'','FX',ru,w,dp.cfg.formula||''));
  }
  return rows;
}
/* Build CSV rows for a legacy (non-PB) derived part */
function legacyCSVRow(dp,parentLabel,cc,cat){
  var waste=dp.multiplier?Math.round((dp.multiplier-1)*100):0;
  var totalQty=dp.computedValue||0;
  var srcLabel='Part';
  if(dp.sourceType==='category_scan')srcLabel='Scan';
  else if(dp.sourceType==='measurement')srcLabel='Derived';
  else if(dp.sourceType==='linked')srcLabel='Linked';
  else if(dp.sourceType==='manual')srcLabel='Manual';
  return csvRow(parentLabel,cat,cc,csvSafe(dp.name||'Part'),totalQty,'',srcLabel,dp.unit||'SF',waste,'');
}
function pbFindParentVal(dp){
  // If part tracks a linked source, use that source's value
  if(dp.cfg&&dp.cfg.pbSourceEid){
    for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===dp.cfg.pbSourceEid)return MEAS[i].value||0;}
    // Linked card may not be in MEAS (filtered by part_link); use Ruby-computed value
    return dp.computedValue||0;
  }
  if(!dp.parentMeasEid&&!dp.sourceEid)return dp.computedValue||0;
  var eid=dp.parentMeasEid||dp.sourceEid;
  for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid)return MEAS[i].value||0;}
  return dp.computedValue||0;
}
function csvPartRows(dp,parentVal,parentLabel,cc,cat){
  var pbRows=pbCSVRows(dp,parentVal,parentLabel,cc,cat);
  if(pbRows)return pbRows;
  return [legacyCSVRow(dp,parentLabel,cc,cat)];
}

/* ── CSV export for a single measurement ── */
function exportMeasCSV(eid){
  var mm=null;
  for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){mm=MEAS[i];break;}}
  if(!mm){showToast('Measurement not found','warning');return;}
  var label=mm.label||mm.partName||mm.category||'measurement';
  var cc=mm.costCode||'';

  var csv=CSV_HDR;
  var mRows=csvMeasRows(mm);
  for(var mri=0;mri<mRows.length;mri++)csv+=mRows[mri]+'\n';

  var parts=[];
  for(var id in DERIVED){
    if(!DERIVED.hasOwnProperty(id))continue;
    var dp=DERIVED[id];
    if(dp.sourceEid&&dp.sourceEid===eid){parts.push(dp);continue;}
    if(dp.parentMeasEid&&dp.parentMeasEid===eid){parts.push(dp);continue;}
    if(dp.category===mm.category&&(dp.sourceType==='category_total'||dp.sourceType==='category_scan')){parts.push(dp);continue;}
  }
  for(var pi=0;pi<parts.length;pi++){
    var rows=csvPartRows(parts[pi],mm.value,label,cc,mm.category||'');
    for(var ri=0;ri<rows.length;ri++)csv+=rows[ri]+'\n';
  }

  var slug=label.toLowerCase().replace(/[^a-z0-9]+/g,'_').replace(/_+$/,'');
  var blob=new Blob([csv],{type:'text/csv'});
  var a=document.createElement('a');
  a.href=URL.createObjectURL(blob);
  a.download=slug+'_takeoff.csv';
  a.click();
  URL.revokeObjectURL(a.href);
  showToast('Exported '+label+' to CSV','success');
}
function exportAllMeasCSV(){
  if(MEAS.length===0){showToast('No measurements to export','warning');return;}
  var csv=CSV_HDR;
  var usedDp={};
  for(var mi=0;mi<MEAS.length;mi++){
    var mm=MEAS[mi];
    if(mm.type==='NOTE'||mm.type==='BENCHMARK')continue;
    var label=mm.label||mm.partName||mm.category||'Measurement';
    var cc=mm.costCode||'';
    var mRows2=csvMeasRows(mm);
    for(var mri2=0;mri2<mRows2.length;mri2++)csv+=mRows2[mri2]+'\n';
    for(var id in DERIVED){
      if(!DERIVED.hasOwnProperty(id)||usedDp[id])continue;
      var dp=DERIVED[id];
      var match=false;
      if(dp.sourceEid&&dp.sourceEid===mm.eid)match=true;
      else if(dp.parentMeasEid&&dp.parentMeasEid===mm.eid)match=true;
      else if(dp.category===mm.category&&(dp.sourceType==='category_total'||dp.sourceType==='category_scan'))match=true;
      if(!match)continue;
      usedDp[id]=true;
      var rows=csvPartRows(dp,mm.value,label,cc,mm.category||'');
      for(var ri=0;ri<rows.length;ri++)csv+=rows[ri]+'\n';
    }
  }
  for(var oid in DERIVED){
    if(!DERIVED.hasOwnProperty(oid)||usedDp[oid])continue;
    var odp=DERIVED[oid];
    var pv=pbFindParentVal(odp);
    var plbl=csvSafe(odp.name||'Orphan part');
    var rows=csvPartRows(odp,pv,plbl,'',odp.category||'');
    for(var ri=0;ri<rows.length;ri++)csv+=rows[ri]+'\n';
  }
  var blob=new Blob([csv],{type:'text/csv'});
  var a=document.createElement('a');
  a.href=URL.createObjectURL(blob);
  a.download='measurements_takeoff.csv';
  a.click();
  URL.revokeObjectURL(a.href);
  showToast('Exported all measurements to CSV','success');
}
/* ── Measurement card expand/collapse ── */
var _openMeasCards={};
function togMeasCard(eid){
  _openMeasCards[eid]=!_openMeasCards[eid];
  var card=document.querySelector('.mc-card[data-eid="'+eid+'"]');
  if(!card)return;
  card.classList.toggle('open');
  var body=card.querySelector('.mc-card-body');
  var chev=card.querySelector('.mc-card-chev');
  if(body)body.style.display=card.classList.contains('open')?'block':'none';
  if(chev)chev.innerHTML=card.classList.contains('open')?'&#9660;':'&#9654;';
  // Adjust parent meas-list max-height
  var ml=card.closest('.meas-list');
  if(ml){var sh=ml.scrollHeight;ml.style.maxHeight=sh+'px';}
}
/* ── SF label + color editing ── */
var SF_PALETTE=[
  [166,227,161,'Green'],[137,180,250,'Blue'],[250,179,135,'Peach'],[203,166,247,'Mauve'],
  [249,226,175,'Yellow'],[148,226,213,'Teal'],[137,220,235,'Sky'],[245,194,231,'Pink'],
  [242,205,205,'Flamingo'],[243,139,168,'Red'],[180,190,254,'Lavender'],[116,199,236,'Sapphire']
];
var _sfCPEl=null;
function showSFColorPicker(ev,eid,cat){
  ev.stopPropagation();
  if(_sfCPEl){_sfCPEl.remove();_sfCPEl=null;}
  var d=document.createElement('div');d.className='sf-cpicker open';
  // Find current color
  var cur=null;for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){cur=MEAS[i].sfColor;break;}}
  for(var i=0;i<SF_PALETTE.length;i++){(function(c){
    var dot=document.createElement('div');dot.className='sf-cpicker-dot';
    dot.style.background='rgb('+c[0]+','+c[1]+','+c[2]+')';
    dot.title=c[3];
    if(cur&&cur[0]===c[0]&&cur[1]===c[1]&&cur[2]===c[2])dot.classList.add('active');
    dot.onclick=function(e){e.stopPropagation();pickSFColor(eid,cat,[c[0],c[1],c[2]]);};
    d.appendChild(dot);
  })(SF_PALETTE[i]);}
  var r=ev.target.getBoundingClientRect();
  d.style.left=Math.min(r.left,window.innerWidth-160)+'px';
  d.style.top=(r.bottom+4)+'px';
  document.body.appendChild(d);_sfCPEl=d;
  setTimeout(function(){document.addEventListener('click',closeSFCP,{once:true});},0);
}
function closeSFCP(){if(_sfCPEl){_sfCPEl.remove();_sfCPEl=null;}}
function pickSFColor(eid,cat,rgb){
  closeSFCP();
  var mtype='SF';for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){mtype=MEAS[i].type;break;}}
  var cb=mtype==='LF'?'updateLFColor':mtype==='VOL'?'updateVolColor':mtype==='COUNT'?'updateCountColor':mtype==='WALL'?'updateWallColor':'updateSFColor';
  callJSON(cb,{eid:eid,color:rgb});
  for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){MEAS[i].sfColor=rgb;MEAS[i].color=rgb;break;}}
  renderMeasPanel();
}
function editSFLabel(el,eid){
  var cur=el.textContent;
  var mtype='SF';for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){mtype=MEAS[i].type;break;}}
  var cb=mtype==='LF'?'updateLFLabel':mtype==='VOL'?'updateVolLabel':mtype==='COUNT'?'updateCountLabel':mtype==='WALL'?'updateWallLabel':'updateSFLabel';
  var inp=document.createElement('input');inp.type='text';inp.value=cur;
  inp.style.cssText='font:inherit;background:var(--surface0);color:var(--text);border:1px solid var(--overlay0);border-radius:3px;padding:1px 4px;width:100%;outline:none;font-size:11px';
  el.textContent='';el.appendChild(inp);inp.focus();inp.select();
  function commit(){
    var v=inp.value.trim();if(!v)v=cur;
    el.textContent=v;
    if(v!==cur){
      callJSON(cb,{eid:eid,label:v});
      for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){MEAS[i].label=v;break;}}
    }
  }
  inp.onblur=commit;
  inp.onkeydown=function(e){if(e.key==='Enter'){e.preventDefault();inp.blur();}if(e.key==='Escape'){inp.value=cur;inp.blur();}};
}
function editCardLabel(el,eid){
  var cur=el.textContent;
  var inp=document.createElement('input');inp.type='text';inp.value=cur;
  inp.style.cssText='font:inherit;background:var(--surface0);color:var(--text);border:1px solid var(--overlay0);border-radius:3px;padding:1px 4px;width:100%;outline:none;font-size:11px';
  el.textContent='';el.appendChild(inp);inp.focus();inp.select();
  function commit(){
    var v=inp.value.trim();if(!v)v=cur;
    el.textContent=v;
    if(v!==cur){
      callJSON('updateCardLabel',{eid:eid,label:v});
      for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){MEAS[i].label=v;break;}}
    }
  }
  inp.onblur=commit;
  inp.onkeydown=function(e){if(e.key==='Enter'){e.preventDefault();inp.blur();}if(e.key==='Escape'){inp.value=cur;inp.blur();}};
}
function newSFMeasurement(cat){
  showInputModal('Label for new SF measurement',function(label){
    // Pick a color that's not already used in this category
    var usedRGB={};
    for(var i=0;i<MEAS.length;i++){
      if(MEAS[i].type==='SF'&&MEAS[i].category===cat&&MEAS[i].sfColor){
        usedRGB[MEAS[i].sfColor.join(',')]=true;
      }
    }
    var color=[166,227,161];
    for(var i=0;i<SF_PALETTE.length;i++){
      var k=SF_PALETTE[i][0]+','+SF_PALETTE[i][1]+','+SF_PALETTE[i][2];
      if(!usedRGB[k]){color=[SF_PALETTE[i][0],SF_PALETTE[i][1],SF_PALETTE[i][2]];break;}
    }
    callJSON('newSFMeasurement',{category:cat,label:label,color:color});
  });
}
function newLFMeasurement(cat){
  showInputModal('Label for new LF measurement',function(label){
    var usedRGB={};
    for(var i=0;i<MEAS.length;i++){
      if(MEAS[i].type==='LF'&&MEAS[i].category===cat&&MEAS[i].sfColor){
        usedRGB[MEAS[i].sfColor.join(',')]=true;
      }
    }
    var color=[166,227,161];
    for(var i=0;i<SF_PALETTE.length;i++){
      var k=SF_PALETTE[i][0]+','+SF_PALETTE[i][1]+','+SF_PALETTE[i][2];
      if(!usedRGB[k]){color=[SF_PALETTE[i][0],SF_PALETTE[i][1],SF_PALETTE[i][2]];break;}
    }
    callJSON('newLFMeasurement',{category:cat,label:label,color:color});
  });
}
function newVolMeasurement(cat){
  showInputModal('Label for new Volume measurement',function(label){
    var usedRGB={};
    for(var i=0;i<MEAS.length;i++){
      if(MEAS[i].type==='VOL'&&MEAS[i].category===cat&&MEAS[i].sfColor){
        usedRGB[MEAS[i].sfColor.join(',')]=true;
      }
    }
    var color=[203,166,247];
    for(var i=0;i<SF_PALETTE.length;i++){
      var k=SF_PALETTE[i][0]+','+SF_PALETTE[i][1]+','+SF_PALETTE[i][2];
      if(!usedRGB[k]){color=[SF_PALETTE[i][0],SF_PALETTE[i][1],SF_PALETTE[i][2]];break;}
    }
    callJSON('newVolMeasurement',{category:cat,label:label,color:color});
  });
}
function measAddShow(){
  var f=document.getElementById('measAddForm');
  var b=document.getElementById('measAddBtn');
  if(f)f.style.display='block';
  if(b)b.style.display='none';
  var inp=document.getElementById('measAddLabel');
  if(inp){inp.value='';inp.focus();}
}
function measAddCancel(){
  var f=document.getElementById('measAddForm');
  var b=document.getElementById('measAddBtn');
  if(f)f.style.display='none';
  if(b)b.style.display='';
}
function measAddCreate(){
  var label=(document.getElementById('measAddLabel')||{}).value||'';
  label=label.trim();
  if(!label){showToast('Enter a name','warning');document.getElementById('measAddLabel').focus();return;}
  measAddCancel();
  call('createEmptyCard',label);
  showToast('Created card "'+label+'"','success');
}
function measCountNew(){
  showPortalPrompt('New Count Measurement','e.g. Joist Hangers',function(label){
    callJSON('measureCount',{category:'Custom',label:label,color:null});
    showToast('Count tool active — click to place markers','info');
  });
}
/* ── Compute wall parts from measurement data ── */
function computeWallParts(mm){
  var parts=[];
  if(!mm||mm.type!=='WALL')return parts;
  var cfg=mm.wallConfig||{};
  var oc=mm.ocSpacing||cfg.oc_spacing||16;
  var waste=cfg.waste_pct||5;
  var details=mm.wallDetails||[];
  // Studs — one line per consolidated group (nominal + height)
  for(var i=0;i<details.length;i++){
    var d=details[i],cnt=d.count||1;
    var wallLF=d.lf||0;
    var wallIn=wallLF*12;
    var studs=Math.ceil(wallIn/oc);
    studs=Math.ceil(studs*(1+waste/100));
    var hLbl=d.h?(d.h+"'"):'';
    parts.push({type:'stud',label:(d.nominal||'?')+' Studs'+(hLbl?' @ '+hLbl+' H':''),qty:studs,unit:'EA',detail:studs+' studs '+oc+'" OC'});
  }
  // Plates — computed per nominal size so 2x4 walls get 2x4 plates etc.
  var plates=cfg.plates||[];
  if(plates.length){
    var lfByNom={};
    for(var ni=0;ni<details.length;ni++){
      var dn=details[ni],nom=dn.nominal||'?';
      lfByNom[nom]=(lfByNom[nom]||0)+(dn.lf||0);
    }
    for(var nom in lfByNom){
      if(!lfByNom.hasOwnProperty(nom))continue;
      var nomLF=lfByNom[nom];
      for(var j=0;j<plates.length;j++){
        var p=plates[j];
        var mult=p.multiplier||1;
        var pLF=nomLF*mult*(1+waste/100);
        pLF=Math.ceil(pLF*10)/10;
        var sLen=p.stickLen||16;
        var sticks=Math.ceil(pLF/sLen);
        parts.push({type:'plate',label:nom+' '+(p.material||'Plate')+' ('+mult+'x)',qty:sticks,unit:'sticks',detail:sticks+' @ '+sLen+"' = "+pLF.toFixed(1)+' LF'});
      }
    }
  }
  return parts;
}

var _wallPlates=[];
function measWallNew(){
  _wallPlates=[];
  var acts=document.getElementById('portalActions');
  document.getElementById('portalTitle').textContent='New Wall Measurement';
  document.getElementById('portalDesc').textContent='';
  document.getElementById('portalProgress').style.display='none';
  acts.style.display='block';
  var h='<div style="display:flex;flex-direction:column;gap:6px;width:100%">';
  h+='<div style="display:flex;align-items:center;gap:6px"><span style="font-size:10px;color:var(--overlay1);width:70px;flex:none">Label</span><input id="wlLabel" class="pb-inp" placeholder="e.g. Interior 2x4 Walls" style="flex:1"></div>';
  h+='<div style="display:flex;align-items:center;gap:6px"><span style="font-size:10px;color:var(--overlay1);width:70px;flex:none">OC spacing</span><select id="wlOC" class="pb-sel" style="flex:none">';
  h+='<option value="12">12" OC</option><option value="16" selected>16" OC</option><option value="24">24" OC</option></select></div>';
  h+='<div style="display:flex;align-items:center;gap:6px"><span style="font-size:10px;color:var(--overlay1);width:70px;flex:none">Waste %</span><input id="wlWaste" class="pb-inp" type="number" step="1" value="5" style="width:60px;flex:none"></div>';
  h+='<div style="border-top:1px solid var(--surface0);margin:6px 0 4px;padding-top:6px">';
  h+='<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">';
  h+='<span style="font-size:10px;font-weight:600;color:var(--overlay1)">Plates</span>';
  h+='<button class="pb-btn sec" onclick="wallAddPlate()" style="padding:2px 8px;font-size:9px">+ Plate</button>';
  h+='</div><div id="wlPlateList"><span style="font-size:9px;color:var(--overlay0);font-style:italic">No plates added</span></div></div>';
  h+='<div style="display:flex;gap:6px;justify-content:flex-end;margin-top:4px">';
  h+='<span class="portal-btn portal-cancel" onclick="hidePortal()">Cancel</span>';
  h+='<span class="portal-btn portal-confirm" onclick="measWallSubmit()">Start</span>';
  h+='</div></div>';
  acts.innerHTML=h;
  var ov=document.getElementById('portalOverlay');
  ov.style.display='flex';ov.style.opacity='';ov.style.transition='';
  setTimeout(function(){document.getElementById('wlLabel').focus();},100);
}
function wallAddPlate(){
  _wallPlates.push({material:'Plate',multiplier:1,stickLen:16});
  wallRenderPlates();
}
function wallRemovePlate(i){
  _wallPlates.splice(i,1);
  wallRenderPlates();
}
function wallRenderPlates(){
  var el=document.getElementById('wlPlateList');
  if(!el)return;
  var h='';
  _wallPlates.forEach(function(p,i){
    h+='<div style="display:flex;align-items:center;gap:4px;margin-bottom:4px">';
    h+='<select class="pb-sel" style="flex:0 0 80px;font-size:9px" onchange="_wallPlates['+i+'].material=this.value">';
    h+='<option value="Plate"'+(p.material==='Plate'?' selected':'')+'>Plate</option>';
    h+='<option value="PT Plate"'+(p.material==='PT Plate'?' selected':'')+'>PT Plate</option>';
    h+='</select>';
    h+='<span style="font-size:9px;color:var(--overlay0)">\u00d7</span>';
    h+='<input type="number" class="pb-inp" value="'+p.multiplier+'" min="1" max="10" step="1" style="width:36px;flex:none;font-size:9px;text-align:center" onchange="_wallPlates['+i+'].multiplier=parseInt(this.value)||1">';
    h+='<select class="pb-sel" style="flex:0 0 58px;font-size:9px" onchange="_wallPlates['+i+'].stickLen=parseInt(this.value)">';
    [8,10,12,14,16,20].forEach(function(l){h+='<option value="'+l+'"'+(p.stickLen===l?' selected':'')+'>'+l+"'</option>";});
    h+='</select>';
    h+='<button class="pb-btn sec" onclick="wallRemovePlate('+i+')" style="padding:1px 5px;font-size:9px;color:var(--red);border-color:var(--red)">\u00d7</button>';
    h+='</div>';
  });
  if(!_wallPlates.length)h='<span style="font-size:9px;color:var(--overlay0);font-style:italic">No plates added</span>';
  el.innerHTML=h;
}
function measWallSubmit(){
  var label=(document.getElementById('wlLabel').value||'').trim();
  if(!label){showToast('Enter a label','warn');return;}
  var oc=parseInt(document.getElementById('wlOC').value)||16;
  var waste=parseInt(document.getElementById('wlWaste').value)||5;
  var plates=_wallPlates.map(function(p){return{material:p.material,multiplier:p.multiplier,stickLen:p.stickLen};});
  hidePortal();
  callJSON('measureWall',{category:'Wall Framing',label:label,color:null,ocSpacing:oc,plates:plates,waste:waste});
  showToast('Wall tool active \u2014 click wall components','info');
}

/* ── Link-pick mode: click a card to link it ── */
function applyLinkPickClasses(){
  // Build set of valid target eids from the dropdown
  var validEids={};
  var linkSel=document.getElementById('apfLink_'+_linkPickEid);
  if(linkSel){for(var j=0;j<linkSel.options.length;j++)validEids[linkSel.options[j].value]=true;}
  var cards=document.querySelectorAll('.mcard[data-eid]');
  for(var i=0;i<cards.length;i++){
    var eid=cards[i].getAttribute('data-eid');
    if(parseInt(eid)===_linkPickEid){cards[i].classList.add('link-pick-src');cards[i].classList.remove('link-pickable');}
    else if(validEids[eid]){cards[i].classList.add('link-pickable');cards[i].classList.remove('link-pick-src');}
    else{cards[i].classList.remove('link-pickable','link-pick-src');}
  }
}
function clearLinkPick(){
  _linkPickEid=0;
  var cards=document.querySelectorAll('.mcard[data-eid]');
  for(var i=0;i<cards.length;i++){cards[i].classList.remove('link-pickable','link-pick-src');}
}
function handleLinkPick(clickedEid){
  if(!_linkPickEid||clickedEid===_linkPickEid)return;
  // Check that the clicked card is in the dropdown (not a CARD/BENCHMARK/NOTE)
  var linkSel=document.getElementById('apfLink_'+_linkPickEid);
  if(!linkSel)return;
  var found=false;
  for(var i=0;i<linkSel.options.length;i++){
    if(parseInt(linkSel.options[i].value)===clickedEid){linkSel.selectedIndex=i;found=true;break;}
  }
  if(!found){showToast('Can\u2019t link that card type','warning');return;}
  apfLinkChange(_linkPickEid);
  // Flash the picked card
  var card=document.querySelector('.mcard[data-eid="'+clickedEid+'"]');
  if(card){card.style.outline='2px solid var(--green)';setTimeout(function(){card.style.outline='';},600);}
}
function delDerived(id){
  var dp=DERIVED[id];
  if(dp&&dp.sourceType==='linked'){
    showPartDelModal(id,dp.name||'Part');
  } else {
    showConfirmModal('Delete this derived part?',function(){call('deleteDerivedPart',id);var wasHL=(_hlScanId===id);delete DERIVED[id];if(wasHL)clrScanHL();renderMeasPanel();showToast('Deleted','warning');});
  }
}
function genCatMeas(cat,unit){closeMeasGDD();callJSON('generateCategoryMeasurement',{category:cat,unit:unit});showToast('Scanning '+cat+' for '+unit+'...','success');}
/* ── Beam helpers ── */
function parseFrac(s){
  // Parse construction fraction like "7 1/2" or "11 7/8" or "3/4" to decimal
  s=String(s).trim();
  var m=s.match(/^(\d+)\s+(\d+)\/(\d+)$/);
  if(m)return parseInt(m[1])+parseInt(m[2])/parseInt(m[3]);
  m=s.match(/^(\d+)\/(\d+)$/);
  if(m)return parseInt(m[1])/parseInt(m[2]);
  return parseFloat(s)||0;
}
function fmtFtIn(decFt){
  var totalIn=Math.round(decFt*48)/4;/* round to 1/4" */
  var ft=Math.floor(totalIn/12),ins=totalIn-ft*12;
  var whole=Math.floor(ins),frac=ins-whole,fs='';
  if(Math.abs(frac-.75)<.01)fs='-3/4';
  else if(Math.abs(frac-.5)<.01)fs='-1/2';
  else if(Math.abs(frac-.25)<.01)fs='-1/4';
  if(whole===0&&!fs)return ft+"'";
  return ft+"'-"+whole+fs+'"';
}
/* ── Beam inventory expand state ── */
var _beamInvOpen={};
function biExpandAll(dId,count,expand){
  for(var i=0;i<count;i++)_beamInvOpen['bi_'+dId+'_'+i]=expand;
  renderMeasPanel();
}
/* ── Measurements hide-empty toggle ── */
var measHideEmpty=false;
function toggleMeasHideEmpty(){
  measHideEmpty=!measHideEmpty;
  var el=document.getElementById('measHideEmptyToggle');
  if(el)el.classList.toggle('active',measHideEmpty);
  renderMeasPanel();
}
/* ── Beam highlight ── */
function hlBeamEids(eids){
  call('clearHighlights');
  if(eids&&eids.length>0){
    callJSON('highlightBeamEntities',{eids:eids});
  }
}
/* ── Scan measurement eye toggle ── */
var _hlScanId=null;
function togScanHL(id){
  if(_hlScanId===id){clrScanHL();renderMeasPanel();return;}
  call('clearHighlights');
  var dp=DERIVED[id];if(!dp){return;}
  callJSON('highlightCategoryScan',{category:dp.category||'',unit:dp.unit||'SF',entityIds:dp.entityIds||[]});
  _hlScanId=id;renderMeasPanel();
}
function clrScanHL(){call('clearHighlights');_hlScanId=null;}
/* ── Category visibility controls (measurements tab) ── */
var _measHiddenCats={};
var _measIsoCat=null;
function measTogCatVis(cat){
  _measIsoCat=null;
  if(_measHiddenCats[cat]){delete _measHiddenCats[cat];call('showCategory',cat);}
  else{_measHiddenCats[cat]=true;call('hideCategory',cat);}
  renderMeasPanel();
}
function measIsoCat(cat){
  if(_measIsoCat===cat){_measIsoCat=null;_measHiddenCats={};call('showAll');renderMeasPanel();return;}
  _measIsoCat=cat;_measHiddenCats={};
  call('isolateCategory',cat);renderMeasPanel();
}
/* ── Global fixed-position measurement dropdown ── */
var _measGDD=null;
function _getMeasGDD(){
  if(_measGDD)return _measGDD;
  _measGDD=document.createElement('div');
  _measGDD.className='meas-gdd';
  document.body.appendChild(_measGDD);
  return _measGDD;
}
function openMeasGDD(btn,cat,ev){
  ev.stopPropagation();
  var dd=_getMeasGDD();
  /* If already open for same button, close */
  if(dd.classList.contains('open')&&dd._btn===btn){closeMeasGDD();return;}
  dd._btn=btn;
  /* Build menu content */
  var h='';
  if(cat){
    /* Category-specific: auto scan + manual + derived */
    h+='<span class="meas-gdd-sep" style="border:none;margin:0">Auto Scan</span>';
    h+='<button class="meas-gdd-item" onclick="genCatMeas(\''+X2(cat)+'\',\'LF\')"><span class="dd-dot" style="background:#a6e3a1"></span>Auto LF</button>';
    h+='<button class="meas-gdd-item" onclick="genCatMeas(\''+X2(cat)+'\',\'SF\')"><span class="dd-dot" style="background:#89b4fa"></span>Auto SF</button>';
    h+='<button class="meas-gdd-item" onclick="genCatMeas(\''+X2(cat)+'\',\'CF\')"><span class="dd-dot" style="background:#cba6f7"></span>Auto CF</button>';
    h+='<button class="meas-gdd-item" onclick="genCatMeas(\''+X2(cat)+'\',\'BM\')"><span class="dd-dot" style="background:#fab387"></span>Auto Beam</button>';
    h+='<span class="meas-gdd-sep">Manual</span>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();call(\'activateLFForCat\',\''+X2(cat)+'\')"><span class="dd-dot" style="background:#a6e3a1"></span>LF Poly</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();newLFMeasurement(\''+X2(cat)+'\')"><span class="dd-dot" style="background:#a6e3a1"></span>LF Face</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();newSFMeasurement(\''+X2(cat)+'\')"><span class="dd-dot" style="background:#89b4fa"></span>SF Face</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();call(\'polySFForCat\',\''+X2(cat)+'\')"><span class="dd-dot" style="background:#94e2d5"></span>SF Poly</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();newVolMeasurement(\''+X2(cat)+'\')"><span class="dd-dot" style="background:#cba6f7"></span>Volume (CY)</button>';
    h+='<span class="meas-gdd-sep">Derived</span>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();showMeasAddPart(\''+X2(cat)+'\')"><span class="dd-dot" style="background:#cba6f7"></span>+ Part</button>';
  } else {
    /* Global: just manual tools */
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();call(\'activateLF\')"><span class="dd-dot" style="background:#a6e3a1"></span>LF Poly</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();call(\'activateLFFace\')"><span class="dd-dot" style="background:#a6e3a1"></span>LF Face</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();call(\'activateSF\')"><span class="dd-dot" style="background:#89b4fa"></span>SF Face</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();call(\'polySF\')"><span class="dd-dot" style="background:#94e2d5"></span>SF Poly</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();newVolMeasurement(\'Custom\')"><span class="dd-dot" style="background:#cba6f7"></span>Volume (CY)</button>';
    h+='<button class="meas-gdd-item" onclick="closeMeasGDD();call(\'activateElevation\')"><span class="dd-dot" style="background:#fab387"></span>Elevation Tag</button>';
  }
  dd.innerHTML=h;
  /* Position fixed relative to button */
  var r=btn.getBoundingClientRect();
  dd.style.top=(r.bottom+2)+'px';
  dd.style.left='auto';
  dd.style.right=(window.innerWidth-r.right)+'px';
  dd.classList.add('open');
}
function closeMeasGDD(){var dd=_getMeasGDD();dd.classList.remove('open');dd._btn=null;}
document.addEventListener('click',function(){closeMeasGDD();closeAsmAutoDD();});
/* ── Assembly Auto-scan dropdown ── */
var _asmAutoDD=null;
function _getAsmAutoDD(){
  if(_asmAutoDD)return _asmAutoDD;
  _asmAutoDD=document.createElement('div');
  _asmAutoDD.className='meas-gdd';
  document.body.appendChild(_asmAutoDD);
  return _asmAutoDD;
}
function toggleAsmAutoDD(btn,asmId){
  var dd=_getAsmAutoDD();
  if(dd.classList.contains('open')&&dd._btn===btn){closeAsmAutoDD();return;}
  dd._btn=btn;
  var opts=[
    {key:'beams',label:'Auto Beam',dot:'var(--peach)'},
    {key:'auto_sf',label:'Auto SF',dot:'var(--blue)'},
    {key:'auto_lf',label:'Auto LF',dot:'var(--green)'},
    {key:'auto_vol',label:'Auto Vol',dot:'var(--mauve)'},
    {key:'auto_tag',label:'Auto Tag',dot:'var(--yellow)'}
  ];
  var h='';
  for(var i=0;i<opts.length;i++){
    var o=opts[i];
    if(o.key==='auto_tag'){
      h+='<button class="meas-gdd-item" onclick="event.stopPropagation();closeAsmAutoDD();showAutoTagModal(\''+asmId+'\')">';
    } else {
      h+='<button class="meas-gdd-item" onclick="event.stopPropagation();_ac2Tab[\''+asmId+'\']=\''+o.key+'\';closeAsmAutoDD();renderAsmPanel()">';
    }
    h+='<span class="dd-dot" style="background:'+o.dot+'"></span>'+o.label+'</button>';
  }
  dd.innerHTML=h;
  var r=btn.getBoundingClientRect();
  dd.style.top=(r.bottom+2)+'px';
  dd.style.left='auto';
  dd.style.right=(window.innerWidth-r.right)+'px';
  dd.classList.add('open');
}
function closeAsmAutoDD(){var dd=_getAsmAutoDD();dd.classList.remove('open');dd._btn=null;}
/* ── Add Part form ── */
function showAddPartForm(eid,cat,mtype){
  // Close any other open forms first
  document.querySelectorAll('.apf.open').forEach(function(el){el.classList.remove('open');});
  var el=document.getElementById('apf_'+eid);
  if(el){el.classList.add('open');var inp=document.getElementById('apfN_'+eid);if(inp){inp.focus();inp.select();}}
}
function hideAddPartForm(eid){var el=document.getElementById('apf_'+eid);if(el)el.classList.remove('open');if(_linkPickEid)clearLinkPick();}
function apfSrcChange(eid){
  var src=(document.getElementById('apfSrc_'+eid)||{}).value||'measurement';
  var multRow=document.getElementById('apfMultRow_'+eid);
  var manRow=document.getElementById('apfManRow_'+eid);
  var linkRow=document.getElementById('apfLinkRow_'+eid);
  var unitRow=document.getElementById('apfUnitRow_'+eid);
  var isTool=src==='tool_sf'||src==='tool_poly_sf'||src==='tool_lf'||src==='tool_vol';
  var isLink=src==='linked';
  if(multRow)multRow.style.display=(src==='manual'||isLink)?'none':'flex';
  if(manRow)manRow.style.display=src==='manual'?'flex':'none';
  if(linkRow)linkRow.style.display=isLink?'flex':'none';
  if(unitRow)unitRow.style.display=isLink?'none':'flex';
  // Auto-set unit for tool sources
  if(isTool){
    var unitSel=document.getElementById('apfUnit_'+eid);
    if(unitSel)unitSel.value=(src==='tool_sf'||src==='tool_poly_sf')?'SF':src==='tool_vol'?'CY':'LF';
  }
  // Link-pick mode
  if(isLink){
    _linkPickEid=eid;
    applyLinkPickClasses();
  } else {
    if(_linkPickEid)clearLinkPick();
  }
  // Populate card picker for linked
  if(isLink){
    var linkSel=document.getElementById('apfLink_'+eid);
    if(linkSel){
      var opts='';
      for(var i=0;i<MEAS.length;i++){
        var m=MEAS[i];
        if(m.eid===eid)continue;
        if(m.type==='BENCHMARK'||m.type==='NOTE'||m.type==='CARD')continue;
        var lbl=(m.label||m.category||'Measurement')+' \u2014 '+fmtMeasVal(m.value,m.unit)+' '+(m.type||'');
        opts+='<option value="'+m.eid+'" data-label="'+X2(m.label||m.category||'')+'" data-unit="'+(m.unit||m.type||'SF')+'">'+X(lbl)+'</option>';
      }
      linkSel.innerHTML=opts;
      apfLinkChange(eid);
    }
  }
}
function apfLinkChange(eid){
  var linkSel=document.getElementById('apfLink_'+eid);
  if(!linkSel||!linkSel.selectedOptions.length)return;
  var opt=linkSel.selectedOptions[0];
  var nameInp=document.getElementById('apfN_'+eid);
  if(nameInp)nameInp.value=opt.getAttribute('data-label')||'';
}
function apfWastePreview(eid,baseVal){
  var pct=parseFloat((document.getElementById('apfMult_'+eid)||{}).value)||0;
  var result=baseVal*(1+pct/100);
  var el=document.getElementById('apfPrev_'+eid);
  if(el)el.textContent='= '+result.toFixed(1)+(pct>0?' (+'+pct+'%)':'');
}
function submitAddPart(eid,cat){
  var name=(document.getElementById('apfN_'+eid)||{}).value||'';name=name.trim();
  if(!name){showToast('Enter a part name','warning');return;}
  var srcType=(document.getElementById('apfSrc_'+eid)||{}).value||'measurement';
  var wastePct=parseFloat((document.getElementById('apfMult_'+eid)||{}).value)||0;
  var mult=1.0+(wastePct/100.0);
  var unit=(document.getElementById('apfUnit_'+eid)||{}).value||'SF';
  var manVal=parseFloat((document.getElementById('apfManVal_'+eid)||{}).value)||0;
  if(srcType==='tool_sf'||srcType==='tool_poly_sf'||srcType==='tool_lf'||srcType==='tool_vol'){
    var payload={name:name,category:cat,sourceType:srcType,unit:unit,
                 multiplier:mult,wastePct:wastePct,parentMeasEid:eid};
    callJSON('createPartAndMeasure',payload);
    hideAddPartForm(eid);
    var toolMsg=srcType==='tool_vol'?'Click objects':'Click faces';
    showToast('Measuring "'+name+'"... '+toolMsg+', then Escape to finish.','info');
  } else if(srcType==='linked'){
    var linkSel=document.getElementById('apfLink_'+eid);
    var linkedEid=linkSel?parseInt(linkSel.value):0;
    if(!linkedEid){showToast('Select a card to link','warning');return;}
    var linkedOpt=linkSel.selectedOptions[0];
    var linkedUnit=linkedOpt?linkedOpt.getAttribute('data-unit')||'SF':'SF';
    var payload={name:name,category:cat,sourceType:'linked',sourceEid:linkedEid,
                 parentMeasEid:eid,unit:linkedUnit,multiplier:1.0};
    callJSON('linkCardAsPart',payload);
    hideAddPartForm(eid);
    showToast('Linked "'+name+'" into card','success');
  } else if(srcType==='measurement'){
    var payload={name:name,category:cat,sourceType:'measurement',sourceEid:eid,
                 unit:unit,multiplier:mult,wastePct:wastePct};
    callJSON('createDerivedPart',payload);
    hideAddPartForm(eid);
    showToast('Part "'+name+'" created','success');
  } else {
    var payload={name:name,category:cat,sourceType:'manual',manualValue:manVal,
                 unit:unit,multiplier:1.0};
    callJSON('createDerivedPart',payload);
    hideAddPartForm(eid);
    showToast('Part "'+name+'" created','success');
  }
}
