/* ═══ PARTS BUILDER ═══ */
var PB_TYPES={
  sheets:  {code:'SH',label:'Sheet Goods',   color:'#89b4fa',desc:'Plywood, drywall, OSB'},
  linear:  {code:'LN',label:'Linear Stock',  color:'#a6e3a1',desc:'Lumber, trim, pipe'},
  rolls:   {code:'RL',label:'Roll Goods',    color:'#cba6f7',desc:'Housewrap, felt, membrane'},
  framing: {code:'WF',label:'Wall Framing',  color:'#fab387',desc:'Studs + plates from wall LF'},
  oncenter:{code:'OC',label:'On Center',     color:'#f5c2e7',desc:'Anchor bolts, rebar, fasteners'},
  coverage:{code:'CV',label:'Area Coverage', color:'#94e2d5',desc:'Paint, concrete, coatings'},
  custom:  {code:'FX',label:'Custom Calc',   color:'#89dcfe',desc:'Formula-based'}
};
var _pbPlates=[];
var _pbEid=0,_pbCat='',_pbVal=0,_pbUnit='',_pbType=null,_pbLabel='';
var _pbSourceEid=0; // non-zero when PB opened from a linked part's value

function openPBFromLinked(parentEid,sourceEid,sourceVal,sourceUnit,sourceName,cat){
  parentEid=parseInt(parentEid)||0;
  sourceEid=parseInt(sourceEid)||0;
  _pbSourceEid=sourceEid;
  _pbEid=parentEid;_pbCat=cat;
  _pbVal=sourceVal||0;_pbUnit=sourceUnit||'SF';_pbType=null;
  _pbLabel=sourceName||'Linked';
  document.getElementById('pbParentLabel').textContent=fmtMeasVal(_pbVal,_pbUnit)+' '+_pbUnit+' \u2014 '+_pbLabel;
  _openPBTypes();
}

function openPB(eid,cat,mtype){
  var mm=null;
  for(var i=0;i<MEAS.length;i++){if(MEAS[i].eid===eid){mm=MEAS[i];break;}}
  if(!mm)return;
  _pbSourceEid=0;
  _pbEid=eid;_pbCat=cat;_pbVal=mm.value||0;_pbUnit=mm.unit||mm.type||'SF';_pbType=null;
  _pbLabel=(mm.label||mm.category||'Measurement');
  document.getElementById('pbParentLabel').textContent=fmtMeasVal(_pbVal,_pbUnit)+' '+_pbUnit+' \u2014 '+_pbLabel;
  _openPBTypes();
}
function _openPBTypes(){
  var h='';
  for(var k in PB_TYPES){
    if(!PB_TYPES.hasOwnProperty(k))continue;
    var t=PB_TYPES[k];
    h+='<div class="pb-type" data-type="'+k+'" onclick="pbSelectType(\''+k+'\')">';
    h+='<div class="pb-type-ico" style="background:'+t.color+'">'+t.code+'</div>';
    h+='<div class="pb-type-lbl">'+t.label+'</div>';
    h+='</div>';
  }
  document.getElementById('pbTypes').innerHTML=h;
  document.getElementById('pbCfg').className='pb-cfg';
  document.getElementById('pbCfg').innerHTML='';
  document.getElementById('pbPreview').style.display='none';
  document.getElementById('pbAddBtn').style.display='none';
  document.getElementById('pbOverlay').classList.add('open');
}

function closePB(){
  document.getElementById('pbOverlay').classList.remove('open');
  _pbType=null;
}

function pbSelectType(type){
  _pbType=type;
  document.querySelectorAll('.pb-type').forEach(function(el){el.classList.toggle('sel',el.dataset.type===type);});
  var cfg=document.getElementById('pbCfg');
  var h='';
  if(type==='sheets'){
    h+='<div class="pb-row"><span class="pb-lbl">Material</span><input class="pb-inp" id="pbName" placeholder="e.g. 1/2&quot; CDX Plywood" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Sheet W (ft)</span><input class="pb-inp" id="pbW" type="number" step="0.5" value="4" style="width:70px;flex:none" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Sheet H (ft)</span><input class="pb-inp" id="pbH" type="number" step="0.5" value="8" style="width:70px;flex:none" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Waste %</span><input class="pb-inp" id="pbWaste" type="number" step="1" value="10" style="width:70px;flex:none" oninput="pbCalc()"></div>';
  } else if(type==='linear'){
    h+='<div class="pb-row"><span class="pb-lbl">Material</span><input class="pb-inp" id="pbName" placeholder="e.g. 2\u00d76 SPF #2" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Stick length</span><select class="pb-sel" id="pbLen" onchange="pbCalc()">';
    [8,10,12,14,16,20].forEach(function(l){h+='<option value="'+l+'"'+(l===12?' selected':'')+'>'+l+"'</option>";});
    h+='</select></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Waste %</span><input class="pb-inp" id="pbWaste" type="number" step="1" value="5" style="width:70px;flex:none" oninput="pbCalc()"></div>';
  } else if(type==='rolls'){
    h+='<div class="pb-row"><span class="pb-lbl">Material</span><input class="pb-inp" id="pbName" placeholder="e.g. Tyvek HomeWrap" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Coverage</span><input class="pb-inp" id="pbCov" type="number" step="1" value="150" style="width:80px;flex:none" oninput="pbCalc()">';
    h+='<select class="pb-sel" id="pbCovUnit" onchange="pbCalc()" style="margin-left:4px"><option value="SF">SF/roll</option><option value="LF">LF/roll</option></select></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Waste %</span><input class="pb-inp" id="pbWaste" type="number" step="1" value="10" style="width:70px;flex:none" oninput="pbCalc()"></div>';
  } else if(type==='framing'){
    _pbPlates=[];
    h+='<div class="pb-row"><span class="pb-lbl">Description</span><input class="pb-inp" id="pbName" placeholder="e.g. Interior 2\u00d74 walls" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Wall height</span><input class="pb-inp" id="pbHeight" type="number" step="0.5" value="8" style="width:70px;flex:none" oninput="pbCalc()"><span style="font-size:10px;color:var(--overlay0);margin-left:4px">ft</span></div>';
    h+='<div class="pb-row"><span class="pb-lbl">OC spacing</span><select class="pb-sel" id="pbOC" onchange="pbCalc()">';
    h+='<option value="12">12" OC</option><option value="16" selected>16" OC</option><option value="24">24" OC</option></select></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Stud length</span><select class="pb-sel" id="pbStudLen" onchange="pbCalc()">';
    [8,10,12,14,16,20].forEach(function(l){var sel=l===8?' selected':'';h+='<option value="'+l+'"'+sel+'>'+l+"'</option>";});
    h+='</select></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Waste %</span><input class="pb-inp" id="pbWaste" type="number" step="1" value="5" style="width:70px;flex:none" oninput="pbCalc()"></div>';
    h+='<div style="border-top:1px solid var(--surface0);margin:8px 0 6px;padding-top:8px">';
    h+='<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px">';
    h+='<span style="font-size:10px;font-weight:600;color:var(--overlay1)">Plates</span>';
    h+='<button class="pb-btn sec" onclick="pbAddPlate()" style="padding:2px 8px;font-size:9px">+ Plate</button>';
    h+='</div>';
    h+='<div id="pbPlateList"></div>';
    h+='</div>';
  } else if(type==='oncenter'){
    h+='<div class="pb-row"><span class="pb-lbl">Item name</span><input class="pb-inp" id="pbName" placeholder="e.g. 1/2\u2033 Anchor Bolts" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Spacing</span><input class="pb-inp" id="pbSpacing" type="number" step="1" value="32" style="width:70px;flex:none" oninput="pbCalc()">';
    h+='<select class="pb-sel" id="pbSpaceUnit" onchange="pbCalc()" style="margin-left:4px"><option value="in">inches</option><option value="ft">feet</option></select></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Extra each end</span><select class="pb-sel" id="pbEndExtra" onchange="pbCalc()"><option value="1" selected>+1 (standard)</option><option value="0">None</option><option value="2">+2</option></select></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Waste %</span><input class="pb-inp" id="pbWaste" type="number" step="1" value="5" style="width:70px;flex:none" oninput="pbCalc()"></div>';
  } else if(type==='coverage'){
    h+='<div class="pb-row"><span class="pb-lbl">Material</span><input class="pb-inp" id="pbName" placeholder="e.g. Interior latex paint" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Coverage</span><input class="pb-inp" id="pbCov" type="number" step="1" value="350" style="width:80px;flex:none" oninput="pbCalc()">';
    h+='<select class="pb-sel" id="pbCovUnit" onchange="pbCalc()" style="margin-left:4px"><option value="SF/gal">SF/gal</option><option value="SF/bag">SF/bag</option><option value="SF/bucket">SF/bucket</option><option value="CF/CY">CF/CY</option></select></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Coats</span><input class="pb-inp" id="pbCoats" type="number" step="1" value="2" style="width:70px;flex:none" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Waste %</span><input class="pb-inp" id="pbWaste" type="number" step="1" value="5" style="width:70px;flex:none" oninput="pbCalc()"></div>';
  } else if(type==='custom'){
    h+='<div class="pb-row"><span class="pb-lbl">Part name</span><input class="pb-inp" id="pbName" placeholder="e.g. Fasteners" oninput="pbCalc()"></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Formula</span><input class="pb-inp" id="pbFormula" placeholder="val / 32 * 1.1" oninput="pbCalc()"><span style="font-size:9px;color:var(--overlay0);margin-left:4px">use <b>val</b></span></div>';
    h+='<div class="pb-row"><span class="pb-lbl">Result unit</span><input class="pb-inp" id="pbResUnit" placeholder="boxes" style="width:80px;flex:none" oninput="pbCalc()"></div>';
  }
  cfg.innerHTML=h;
  cfg.className='pb-cfg open';
  document.getElementById('pbAddBtn').style.display='';
  if(type==='framing')pbRenderPlates();
  pbCalc();
  var ni=document.getElementById('pbName');if(ni)ni.focus();
}

function pbAddPlate(){
  _pbPlates.push({material:'Plate',multiplier:1,stickLen:8});
  pbRenderPlates();
  pbCalc();
}
function pbRemovePlate(i){
  _pbPlates.splice(i,1);
  pbRenderPlates();
  pbCalc();
}
function pbRenderPlates(){
  var el=document.getElementById('pbPlateList');
  if(!el)return;
  var h='';
  _pbPlates.forEach(function(p,i){
    h+='<div style="display:flex;align-items:center;gap:4px;margin-bottom:4px">';
    h+='<select class="pb-sel" style="flex:0 0 80px;font-size:9px" onchange="_pbPlates['+i+'].material=this.value;pbCalc()">';
    h+='<option value="Plate"'+(p.material==='Plate'?' selected':'')+'>Plate</option>';
    h+='<option value="PT Plate"'+(p.material==='PT Plate'?' selected':'')+'>PT Plate</option>';
    h+='</select>';
    h+='<span style="font-size:9px;color:var(--overlay0)">\u00d7</span>';
    h+='<input type="number" class="pb-inp" value="'+p.multiplier+'" min="1" max="10" step="1" style="width:36px;flex:none;font-size:9px;text-align:center" onchange="_pbPlates['+i+'].multiplier=parseInt(this.value)||1;pbCalc()">';
    h+='<select class="pb-sel" style="flex:0 0 58px;font-size:9px" onchange="_pbPlates['+i+'].stickLen=parseInt(this.value);pbCalc()">';
    [8,10,12,14,16,20].forEach(function(l){h+='<option value="'+l+'"'+(p.stickLen===l?' selected':'')+'>'+l+"'</option>";});
    h+='</select>';
    h+='<button class="pb-btn sec" onclick="pbRemovePlate('+i+')" style="padding:1px 5px;font-size:9px;color:var(--red);border-color:var(--red)">\u00d7</button>';
    h+='</div>';
  });
  if(!_pbPlates.length){
    h+='<span style="font-size:9px;color:var(--overlay0);font-style:italic">No plates added</span>';
  }
  el.innerHTML=h;
}
function pbUpdatePlate(i,field,val){
  if(!_pbPlates[i])return;
  _pbPlates[i][field]=val;
  pbCalc();
}

function pbCalc(){
  var prev=document.getElementById('pbPreview');
  if(!_pbType){prev.style.display='none';return;}
  var r=pbCompute(_pbType,_pbVal,null);
  if(!r){prev.style.display='none';return;}
  prev.style.display='block';
  if(_pbType==='framing' && r.lines){
    var h='From <b>'+fmtMeasVal(_pbVal,_pbUnit)+' '+_pbUnit+'</b> of '+X(_pbLabel)+':';
    r.lines.forEach(function(ln){h+='<br><span class="pb-order">'+ln.order+'</span> '+X(ln.label);});
    prev.innerHTML=h;
  } else {
    prev.innerHTML='From <b>'+fmtMeasVal(_pbVal,_pbUnit)+' '+_pbUnit+'</b> of '+X(_pbLabel)+':<br><span class="pb-order">'+r.order+'</span> '+X(r.orderUnit);
  }
}

function pbReadCfg(type){
  var c={};
  c.name=((document.getElementById('pbName')||{}).value||'').trim();
  c.waste=parseFloat((document.getElementById('pbWaste')||{}).value)||0;
  if(type==='sheets'){
    c.sheetW=parseFloat((document.getElementById('pbW')||{}).value)||4;
    c.sheetH=parseFloat((document.getElementById('pbH')||{}).value)||8;
  } else if(type==='linear'){
    c.stickLen=parseFloat((document.getElementById('pbLen')||{}).value)||12;
  } else if(type==='rolls'){
    c.coverage=parseFloat((document.getElementById('pbCov')||{}).value)||150;
    c.covUnit=(document.getElementById('pbCovUnit')||{}).value||'SF';
  } else if(type==='framing'){
    c.wallHeight=parseFloat((document.getElementById('pbHeight')||{}).value)||8;
    c.ocSpacing=parseInt((document.getElementById('pbOC')||{}).value)||16;
    c.studLen=parseInt((document.getElementById('pbStudLen')||{}).value)||8;
    c.plates=_pbPlates.map(function(p){return{material:p.material,multiplier:p.multiplier,stickLen:p.stickLen};});
  } else if(type==='oncenter'){
    c.spacing=parseFloat((document.getElementById('pbSpacing')||{}).value)||32;
    c.spaceUnit=(document.getElementById('pbSpaceUnit')||{}).value||'in';
    c.endExtra=parseInt((document.getElementById('pbEndExtra')||{}).value)||1;
  } else if(type==='coverage'){
    c.coverageRate=parseFloat((document.getElementById('pbCov')||{}).value)||350;
    c.covUnit=(document.getElementById('pbCovUnit')||{}).value||'SF/gal';
    c.coats=parseInt((document.getElementById('pbCoats')||{}).value)||2;
  } else if(type==='custom'){
    c.formula=((document.getElementById('pbFormula')||{}).value||'').trim();
    c.resultUnit=((document.getElementById('pbResUnit')||{}).value||'').trim();
  }
  return c;
}

function pbCompute(type,parentVal,cfg){
  var c=cfg||pbReadCfg(type);
  var w=c.waste||0;
  if(type==='sheets'){
    var sf=((c.sheetW||4)*(c.sheetH||8));
    if(sf<=0)return null;
    var total=parentVal*(1+w/100);
    var sheets=Math.ceil(total/sf);
    return{order:sheets,orderUnit:'sheets ('+(c.sheetW||4)+"'\u00d7"+(c.sheetH||8)+"')",raw:total};
  } else if(type==='linear'){
    var len=c.stickLen||12;
    var total=parentVal*(1+w/100);
    var sticks=Math.ceil(total/len);
    return{order:sticks,orderUnit:len+"' sticks",raw:total};
  } else if(type==='rolls'){
    var cov=c.coverage||150;
    if(cov<=0)return null;
    var total=parentVal*(1+w/100);
    var rolls=Math.ceil(total/cov);
    return{order:rolls,orderUnit:'rolls ('+cov+' '+(c.covUnit||'SF')+'/roll)',raw:total};
  } else if(type==='framing'){
    var oc=c.ocSpacing||16;
    var wallIn=parentVal*12;
    var studs=Math.ceil(wallIn/oc)+1;
    studs=Math.ceil(studs*(1+w/100));
    var studLen=c.studLen||8;
    var lines=[{order:studs,label:studs+' studs @ '+studLen+"'",sticks:studs,lf:studs*studLen}];
    var plates=c.plates||[];
    plates.forEach(function(p){
      var mult=p.multiplier||1;
      var totalLF=parentVal*mult*(1+w/100);
      totalLF=Math.ceil(totalLF*10)/10;
      var sLen=p.stickLen||8;
      var stickCount=Math.ceil(totalLF/sLen);
      lines.push({order:stickCount,label:stickCount+' sticks '+p.material+' ('+mult+'x) = '+totalLF.toFixed(1)+' LF @ '+sLen+"'",sticks:stickCount,lf:totalLF,material:p.material});
    });
    var totalOrder=lines[0].sticks;
    plates.forEach(function(p,i){totalOrder+=lines[i+1].sticks;});
    return{order:totalOrder,orderUnit:'total sticks',raw:studs,lines:lines,compound:true};
  } else if(type==='oncenter'){
    var spacing=c.spacing||32;
    var unit=c.spaceUnit||'in';
    var spacingFt=unit==='in'?spacing/12:spacing;
    if(spacingFt<=0)return null;
    var totalLF=parentVal*(1+w/100);
    var count=Math.ceil(totalLF/spacingFt)+(c.endExtra||0);
    var spaceLbl=unit==='in'?(spacing+'"'):(spacing+"'");
    return{order:count,orderUnit:'EA @ '+spaceLbl+' O.C.',raw:totalLF};
  } else if(type==='coverage'){
    var rate=c.coverageRate||350;
    if(rate<=0)return null;
    var coats=c.coats||1;
    var total=parentVal*coats*(1+w/100);
    var units=Math.ceil(total/rate);
    var parts=(c.covUnit||'SF/gal').split('/');
    var unitLbl=parts.length>1?parts[1]:'units';
    return{order:units,orderUnit:unitLbl+' ('+rate+' '+(c.covUnit||'SF/gal')+')',raw:total};
  } else if(type==='custom'){
    if(!c.formula)return null;
    try{
      var val=parentVal;
      var result=eval(c.formula);
      var order=Math.ceil(result);
      return{order:order,orderUnit:c.resultUnit||'units',raw:result};
    }catch(e){return null;}
  }
  return null;
}

function pbSubmit(){
  if(!_pbType){showToast('Select a part type','warning');return;}
  var c=pbReadCfg(_pbType);
  if(!c.name && _pbType!=='custom'){showToast('Enter a material name','warning');return;}
  if(_pbType==='custom' && !c.formula){showToast('Enter a formula','warning');return;}
  var r=pbCompute(_pbType,_pbVal,c);
  if(!r){showToast('Cannot calculate — check inputs','warning');return;}
  // Track linked source so JS-side value lookup uses the right measurement
  if(_pbSourceEid)c.pbSourceEid=_pbSourceEid;
  // Build derived part payload — sourceEid always points to parent card
  // so Ruby can resolve it; pbSourceEid in cfg handles JS-side lookup
  var payload={
    name:c.name||'Custom part',
    category:_pbCat,
    sourceType:'measurement',
    sourceEid:_pbEid,
    parentMeasEid:_pbEid,
    unit:_pbUnit,
    multiplier:1.0,
    wastePct:c.waste||0,
    partBuilder:true,
    pbType:_pbType,
    cfg:c
  };
  callJSON('createDerivedPart',payload);
  _pbSourceEid=0;
  closePB();
  showToast(PB_TYPES[_pbType].code+' part "'+c.name+'" added','success');
}

/* Render a parts-builder part row */
function pbPartRow(pp,ppd){
  var h='';
  var t=PB_TYPES[ppd.pbType]||{code:'??',color:'#6c7086'};
  // If part was created from a linked source, look up that source's current value
  var pv=ppd.computedValue||0;
  if(ppd.cfg&&ppd.cfg.pbSourceEid){
    for(var si=0;si<MEAS.length;si++){if(MEAS[si].eid===ppd.cfg.pbSourceEid){pv=MEAS[si].value||0;break;}}
  }
  var r=pbCompute(ppd.pbType,pv,ppd.cfg);
  if(r && r.compound && r.lines){
    /* Compound framing: header + sub-lines */
    h+='<div class="mcard-part" style="flex-wrap:wrap">';
    h+='<span class="pb-ico" style="background:'+t.color+'">'+t.code+'</span>';
    h+='<span class="mcard-part-name" style="color:'+t.color+'">'+X(ppd.cfg.name||ppd.name||'Wall Framing')+'</span>';
    h+='<span class="mcard-part-order">'+r.order+'</span>';
    h+='<span class="mcard-part-unit">total sticks</span>';
    if(ppd.cfg.waste)h+='<span class="mcard-part-waste">(+'+ppd.cfg.waste+'%)</span>';
    h+='<button class="mcard-part-del" onclick="delDerived(\''+X2(pp.id)+'\')" title="Delete">\u00d7</button>';
    h+='<div style="width:100%;padding-left:24px;margin-top:2px">';
    r.lines.forEach(function(ln){
      h+='<div style="font-size:9px;color:var(--subtext0);line-height:1.5">';
      h+=X(ln.label);
      h+='</div>';
    });
    h+='</div>';
    h+='</div>';
  } else {
    h+='<div class="mcard-part">';
    h+='<span class="pb-ico" style="background:'+t.color+'">'+t.code+'</span>';
    h+='<span class="mcard-part-name" style="color:'+t.color+'">'+X(ppd.cfg.name||ppd.name||'Part')+'</span>';
    if(r){
      h+='<span class="mcard-part-order">'+r.order+'</span>';
      h+='<span class="mcard-part-unit" style="width:auto;max-width:90px;overflow:hidden;text-overflow:ellipsis">'+X(r.orderUnit)+'</span>';
    }
    if(ppd.cfg.waste)h+='<span class="mcard-part-waste">(+'+ppd.cfg.waste+'%)</span>';
    h+='<button class="mcard-part-del" onclick="delDerived(\''+X2(pp.id)+'\')" title="Delete">\u00d7</button>';
    h+='</div>';
  }
  return h;
}