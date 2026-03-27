/* ═══ CUSTOM COLORS — expandable dot picker ═══ */
function getDefaultColor(key){
  var cls=key.replace(/[\s\/]+/g,'');
  if(KNOWN_CATS[cls]){var el=document.createElement('span');el.className='c-'+cls;document.body.appendChild(el);var bg=getComputedStyle(el).backgroundColor;document.body.removeChild(el);return bg;}
  var h=0;for(var i=0;i<key.length;i++)h=key.charCodeAt(i)+((h<<5)-h);
  return 'hsl('+((h%360+360)%360)+',55%,70%)';
}
function safeId(key){return 'cdw_'+key.replace(/[^a-zA-Z0-9]/g,'_');}
function buildColorDot(type,key,currentColor){
  var sid=safeId(key);
  var bg=currentColor||getDefaultColor(key);
  var hasCustom=!!currentColor;
  var isActive=(type==='category'&&activeColorCategories[key]);
  var h='<span class="color-dot-wrap'+(isActive?' viewport-active':'')+'" onclick="handleColorClick(event,\''+type+'\',\''+X2(key)+'\')" ondblclick="handleColorDblClick(event,\''+type+'\',\''+X2(key)+'\')" id="'+sid+'" style="color:'+bg+'">';
  h+='<span class="cd-main" style="background:'+bg+'"'+(hasCustom?' data-custom-color="'+currentColor+'"':'')+' ></span>';
  h+='</span>';
  return h;
}
function buildStaticDot(color){
  if(!color)return '';
  return '<span class="color-dot-static" style="background:'+color+'"></span>';
}
var PLURAL_MAP={category:'categories',subcategory:'subcategories',assembly:'assemblies',entity:'entities',measurement:'measurements',container:'containers'};
var colorClickTimer=null;

function handleColorClick(event,type,key){
  event.stopPropagation();
  // Delay single-click action to distinguish from double-click
  if(colorClickTimer){clearTimeout(colorClickTimer);colorClickTimer=null;return;}
  colorClickTimer=setTimeout(function(){
    colorClickTimer=null;
    // Single click: toggle highlight on/off
    if(type==='category'){
      if(activeColorCategories[key]){
        deactivateCategoryColor(key);
      } else {
        var section=PLURAL_MAP[type]||(type+'s');
        if(CCOL[section]&&CCOL[section][key]){
          activateCategoryColor(key);
        }
      }
    } else if(type==='container'){
      var cats=getCategoriesInContainer(key);
      var anyActive=false;
      for(var ci=0;ci<cats.length;ci++){
        if(activeColorCategories[cats[ci]]){anyActive=true;break;}
      }
      if(anyActive){
        for(var ci=0;ci<cats.length;ci++) deactivateCategoryColor(cats[ci]);
      } else {
        var section=PLURAL_MAP[type]||(type+'s');
        if(CCOL[section]&&CCOL[section][key]){
          for(var ci=0;ci<cats.length;ci++){
            activeColorCategories[cats[ci]]=true;
            call('highlightCategoryColor',cats[ci]);
            updateDotActiveState(cats[ci],true);
          }
        }
      }
    }
  },250);
}

function handleColorDblClick(event,type,key){
  event.stopPropagation();
  event.preventDefault();
  if(colorClickTimer){clearTimeout(colorClickTimer);colorClickTimer=null;}
  openColorPopup(event,type,key);
}

/* ═══ COLOR POPUP ═══ */
function openColorPopup(event,type,key){
  var popup=document.getElementById('colorPopup');
  // Position below clicked dot
  var rect=event.target.getBoundingClientRect();
  var top=rect.bottom+4;
  var left=rect.left;
  // Keep within viewport
  if(left+224>window.innerWidth)left=window.innerWidth-228;
  if(left<4)left=4;
  if(top+280>window.innerHeight)top=rect.top-284;
  if(top<4)top=4;
  popup.style.top=top+'px';
  popup.style.left=left+'px';
  popup.style.display='block';

  // Populate state
  cpState.type=type;
  cpState.key=key;
  var section=PLURAL_MAP[type]||(type+'s');
  var existingHex=(CCOL[section]&&CCOL[section][key])||'';
  var existingOpacity=85;
  if(CSETTINGS[section]&&CSETTINGS[section][key]){
    var s=CSETTINGS[section][key];
    if(s.color)existingHex=s.color;
    if(s.opacity!=null)existingOpacity=Math.round(s.opacity*100);
  }
  cpState.hex=existingHex||getDefaultColor(key);
  cpState.opacity=existingOpacity;

  // Title
  var titleMap={category:'Category',subcategory:'Subcategory',container:'Container',entity:'Entity',assembly:'Assembly',measurement:'Measurement'};
  document.getElementById('cpTitle').textContent=(titleMap[type]||'Custom')+' Color';

  // Build swatches
  var sw=document.getElementById('cpSwatches');
  var sh='';
  for(var i=0;i<COLOR_PALETTE.length;i++){
    var c=COLOR_PALETTE[i];
    var picked=(c===existingHex)?' picked':'';
    sh+='<span class="cp-swatch'+picked+'" style="background:'+c+'" onclick="cpPickSwatch(\''+c+'\',this)"></span>';
  }
  sw.innerHTML=sh;

  // Hex input + preview
  document.getElementById('cpHexInput').value=existingHex||'';
  document.getElementById('cpPreview').style.background=cpState.hex;
  try{document.getElementById('cpNativePicker').value=existingHex||'#cba6f7';}catch(e){}

  // Opacity slider
  document.getElementById('cpOpacity').value=existingOpacity;
  document.getElementById('cpOpacityVal').textContent=existingOpacity+'%';

  // Outside click listener (delayed to avoid immediate close)
  setTimeout(function(){
    document.addEventListener('click',cpOutsideClick);
  },10);
}

function closeColorPopup(){
  document.getElementById('colorPopup').style.display='none';
  document.removeEventListener('click',cpOutsideClick);
}

function cpOutsideClick(e){
  var popup=document.getElementById('colorPopup');
  if(!popup.contains(e.target)){
    closeColorPopup();
  }
}

function cpPickSwatch(hex,el){
  cpState.hex=hex;
  document.getElementById('cpHexInput').value=hex;
  document.getElementById('cpPreview').style.background=hex;
  try{document.getElementById('cpNativePicker').value=hex;}catch(e){}
  // Update picked state
  var all=document.getElementById('cpSwatches').querySelectorAll('.cp-swatch');
  for(var i=0;i<all.length;i++)all[i].classList.remove('picked');
  el.classList.add('picked');
}

function onCpHexInput(val){
  val=val.trim();
  if(val.length>0&&val[0]!=='#')val='#'+val;
  if(/^#[0-9a-fA-F]{6}$/.test(val)){
    cpState.hex=val;
    document.getElementById('cpPreview').style.background=val;
    try{document.getElementById('cpNativePicker').value=val;}catch(e){}
    // Update swatch picked state
    var all=document.getElementById('cpSwatches').querySelectorAll('.cp-swatch');
    for(var i=0;i<all.length;i++){
      all[i].classList.toggle('picked',all[i].style.background===val||rgbToHex(all[i].style.background)===val.toLowerCase());
    }
  }
}

function onCpNativePick(val){
  cpState.hex=val;
  document.getElementById('cpHexInput').value=val;
  document.getElementById('cpPreview').style.background=val;
  var all=document.getElementById('cpSwatches').querySelectorAll('.cp-swatch');
  for(var i=0;i<all.length;i++)all[i].classList.remove('picked');
}

function onCpOpacityChange(val){
  cpState.opacity=parseInt(val);
  document.getElementById('cpOpacityVal').textContent=val+'%';
  // Live preview: update opacity in SketchUp immediately
  callJSON('setCustomOpacity',{type:cpState.type,key:cpState.key,opacity:parseInt(val)/100.0});
}

function rgbToHex(rgb){
  if(!rgb||rgb[0]==='#')return rgb;
  var m=rgb.match(/(\d+)/g);
  if(!m||m.length<3)return rgb;
  return '#'+((1<<24)+(parseInt(m[0])<<16)+(parseInt(m[1])<<8)+parseInt(m[2])).toString(16).slice(1);
}

function cpApply(){
  var hex=cpState.hex;
  var opacity=cpState.opacity/100.0;
  var type=cpState.type;
  var key=cpState.key;
  var section=PLURAL_MAP[type]||(type+'s');

  // Update CCOL
  if(!CCOL[section])CCOL[section]={};
  CCOL[section][key]=hex;

  // Update CSETTINGS
  if(!CSETTINGS[section])CSETTINGS[section]={};
  CSETTINGS[section][key]={color:hex,opacity:opacity};

  // Update dot
  var sid=safeId(key);
  var wrap=document.getElementById(sid);
  if(wrap){
    var dot=wrap.querySelector('.cd-main');
    if(dot){dot.style.background=hex;dot.setAttribute('data-custom-color',hex);}
    wrap.style.color=hex;
  }

  // Save to Ruby
  callJSON('setCustomColor',{type:type,key:key,color:hex,opacity:opacity});

  // Activate color in viewport
  if(type==='category'){
    activeColorCategories[key]=true;
    call('highlightCategoryColor',key);
    updateDotActiveState(key,true);
  } else if(type==='container'){
    var cats=getCategoriesInContainer(key);
    for(var ci=0;ci<cats.length;ci++){
      activeColorCategories[cats[ci]]=true;
      call('highlightCategoryColor',cats[ci]);
      updateDotActiveState(cats[ci],true);
    }
  }

  closeColorPopup();
  renderGroups();renderAsmPanel();renderMeasPanel();
}

function cpReset(){
  var type=cpState.type;
  var key=cpState.key;
  var section=PLURAL_MAP[type]||(type+'s');

  // Clear from CCOL
  if(CCOL[section])delete CCOL[section][key];
  if(CSETTINGS[section])delete CSETTINGS[section][key];

  // Update dot
  var sid=safeId(key);
  var wrap=document.getElementById(sid);
  if(wrap){
    var dot=wrap.querySelector('.cd-main');
    if(dot){dot.style.background=getDefaultColor(key);dot.removeAttribute('data-custom-color');}
  }

  // Clear in Ruby
  callJSON('clearCustomColor',{type:type,key:key});

  // Deactivate viewport highlight if active
  if(type==='category'&&activeColorCategories[key]){
    deactivateCategoryColor(key);
  } else if(type==='container'){
    var cats=getCategoriesInContainer(key);
    for(var ci=0;ci<cats.length;ci++){
      if(activeColorCategories[cats[ci]]) deactivateCategoryColor(cats[ci]);
    }
  }

  closeColorPopup();
  renderGroups();renderAsmPanel();renderMeasPanel();
}

function activateCategoryColor(key){
  activeColorCategories[key]=true;
  call('highlightCategoryColor',key);
  updateDotActiveState(key,true);
}

function deactivateCategoryColor(key){
  delete activeColorCategories[key];
  call('clearCategoryColor',key);
  updateDotActiveState(key,false);
}

function updateDotActiveState(key,active){
  var sid=safeId(key);
  var wrap=document.getElementById(sid);
  if(wrap){
    wrap.classList.toggle('viewport-active',active);
    if(active){
      var main=wrap.querySelector('.cd-main');
      if(main)wrap.style.color=main.style.background;
    }
  }
}

function clearAllDotStates(){
  var keys=Object.keys(activeColorCategories);
  for(var i=0;i<keys.length;i++){
    updateDotActiveState(keys[i],false);
  }
  activeColorCategories={};
}
