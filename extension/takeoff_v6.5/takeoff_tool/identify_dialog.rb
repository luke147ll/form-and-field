module TakeoffTool
  module IdentifyDialog
    unless defined?(@_identify_loaded)
    @_identify_loaded = true
    @dialog = nil
    @current_entities = []
    @observer = nil
    end

    # SelectionObserver for live updates
    class SelObserver < Sketchup::SelectionObserver
      def onSelectionBulkChange(sel)
        IdentifyDialog.on_selection_changed(sel)
      end
      def onSelectionCleared(sel)
        IdentifyDialog.on_selection_changed(sel)
      end
    end

    def self.on_selection_changed(sel)
      return unless @dialog && @dialog.visible?
      entities = sel.to_a.select { |e| e.respond_to?(:entityID) }
      return if entities.empty?
      @current_entities = entities
      html_body = entities.length == 1 ? build_single_body(entities.first) : build_multi_body(entities)
      require 'json'
      safe = JSON.generate(html_body)
      @dialog.execute_script("updateContent(#{safe})")
    rescue => e
      puts "IdentifyDialog: selection update error: #{e.message}"
    end

    def self.detach_observer
      return unless @observer
      sel = Sketchup.active_model&.selection
      sel.remove_observer(@observer) if sel
      @observer = nil
    end

    def self.show(selection)
      @dialog.close if @dialog && @dialog.visible? rescue nil
      detach_observer
      @current_entities = selection.to_a.select { |e| e.respond_to?(:entityID) }
      return if @current_entities.empty?

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field - Identify",
        preferences_key: "TakeoffIdentify",
        width: 320, height: 450,
        left: 200, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.add_action_callback('applyCategory') do |_ctx, arg_str|
        begin
          require 'json'
          data = JSON.parse(arg_str.to_s)
          cat = data['category'].to_s
          sub = data['subcategory'].to_s
        rescue
          cat = arg_str.to_s
          sub = ''
        end
        next if cat.empty?
        # Learning system: capture before apply
        if @current_entities.length > 0
          first_e = @current_entities.first
          old_cat = first_e.get_attribute('TakeoffAssignments', 'category') rescue nil
          old_cat ||= 'Uncategorized'
          begin
            LearningSystem.capture(first_e.entityID, old_cat, cat,
              new_subcategory: sub.empty? ? nil : sub)
          rescue => le
            puts "Identify learning capture error: #{le.message}"
          end
        end
        TakeoffTool.apply_category_to_selection(@current_entities, cat)
        unless sub.empty?
          @current_entities.each do |e|
            TakeoffTool.save_assignment(e.entityID, 'subcategory', sub)
          end
        end

        # Update viewport isolation if active
        hidden_count = 0
        if Highlighter.isolated_categories
          @current_entities.each do |e|
            result = Highlighter.update_entity_isolation(e.entityID, cat)
            hidden_count += 1 if result
          end
        end

        # Refresh dashboard so HIDDEN_CATS visibility is enforced
        Dashboard.send_live_data if defined?(Dashboard) && Dashboard.respond_to?(:send_live_data)

        # Build feedback message
        n = @current_entities.length
        if hidden_count > 0
          if n == 1
            msg = "Moved to #{cat} — hidden (not in current isolation)"
          else
            msg = "#{n} entities → #{cat} — #{hidden_count} hidden (not in current isolation)"
          end
        else
          msg = n == 1 ? "Applied: #{cat}" : "#{n} entities → #{cat}"
        end

        send_apply_result(cat, sub, msg, hidden_count > 0)
      end

      @dialog.add_action_callback('addCustomCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        next if name.empty?
        TakeoffTool.add_custom_category(name)
        puts "Takeoff: IdentifyDialog addCustomCategory '#{name}'"
      end

      @dialog.add_action_callback('requestSubcategoriesForCat') do |_ctx, cat_str|
        send_subcategories_for(cat_str.to_s.strip)
      end

      @dialog.add_action_callback('addSubcategoryForCat') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          name = data['name'].to_s.strip
          TakeoffTool.add_subcategory(cat, name)
          send_subcategories_for(cat)
        rescue => e
          puts "Takeoff: IdentifyDialog addSubcategoryForCat error: #{e.message}"
        end
      end

      html = @current_entities.length == 1 ? build_single(@current_entities.first) : build_multi(@current_entities)
      @dialog.set_html(html)
      @dialog.set_on_closed { detach_observer }
      @dialog.show

      # Attach selection observer for live updates
      sel = Sketchup.active_model&.selection
      if sel
        @observer = SelObserver.new
        sel.add_observer(@observer)
      end
    end

    private

    def self.h(s)
      s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
    end

    # Strip trailing Revit hex ID from name (e.g. "Basic Wall, Finish - GYP, 3A2F" -> "Basic Wall, Finish - GYP")
    def self.clean_name(name)
      name.to_s.sub(/,\s*[0-9A-Fa-f]+\s*$/, '').strip
    end

    def self.fmt_dim(inches)
      inches = inches.to_f
      ft = (inches / 12).floor
      rem = inches - ft * 12
      whole = rem.floor
      frac = rem - whole
      # Format fractional part
      if frac.abs < 0.05
        rem_str = "#{whole}\""
      else
        rem_str = "#{rem.round(1)}\""
      end
      ft > 0 ? "#{ft}'-#{rem_str}" : rem_str
    end

    def self.fmt_vol(vol_in3)
      ft3 = vol_in3 / 1728.0
      "#{ft3.round(2)} ft&sup3;"
    end

    def self.entity_info(e)
      eid = e.entityID
      defn = e.respond_to?(:definition) ? e.definition : nil
      dname = defn ? defn.name : ''
      iname = (e.respond_to?(:name) && e.name && !e.name.empty?) ? e.name : nil

      # Category
      cat = TakeoffTool.category_assignments[eid]
      cat ||= (e.get_attribute('TakeoffAssignments', 'category') rescue nil)
      unless cat
        sr = TakeoffTool.filtered_scan_results.find { |r| r[:entity_id] == eid }
        cat = sr[:parsed][:auto_category] if sr
      end

      # Subcategory
      sub = (e.get_attribute('TakeoffAssignments', 'subcategory') rescue nil)
      unless sub
        sr ||= TakeoffTool.filtered_scan_results.find { |r| r[:entity_id] == eid }
        sub = sr[:parsed][:auto_subcategory] if sr
      end

      # Tag
      tag = e.respond_to?(:layer) && e.layer ? e.layer.name : 'Untagged'

      # IFC Type
      ifc = nil
      if defn && defn.attribute_dictionaries
        a = defn.attribute_dictionaries['AppliedSchemaTypes']
        ifc = a['IFC 4'] if a
      end

      # Material
      mat = nil
      if e.material
        mat = e.material.display_name
      elsif defn
        f = defn.entities.grep(Sketchup::Face).first
        mat = f.material.display_name if f && f.material
      end

      # Bounding box
      bb = e.bounds
      w = bb.width.to_f; h_val = bb.height.to_f; d = bb.depth.to_f

      # Volume / Solid
      is_solid = false; vol = nil
      begin
        if e.respond_to?(:manifold?) && e.manifold?
          is_solid = true; vol = e.volume
        end
      rescue; end

      # Instance count
      inst_count = defn ? defn.instances.length : 1

      # Model source (multiverse)
      ms_raw = (e.get_attribute('FormAndField', 'model_source') rescue nil) || 'model_a'
      model_label = ms_raw == 'model_a' ? 'A' : 'B'

      {
        name: clean_name(iname || dname),
        definition: dname,
        category: cat, subcategory: sub || '',
        tag: tag, ifc: ifc, material: mat,
        w: w, h: h_val, d: d,
        is_solid: is_solid, volume: vol,
        instance_count: inst_count,
        model_source: model_label
      }
    end

    def self.category_options(selected)
      containers = TakeoffTool.master_containers || []
      all_cats = TakeoffTool.master_categories.reject { |c| c == '_IGNORE' }
      if containers.any?
        in_cont = {}
        opts = ''
        containers.each do |cont|
          cats = (cont['categories'] || []).reject { |c| c['name'] == '_IGNORE' }
          next if cats.empty?
          sorted = cats.sort_by { |c| c['name'].downcase }
          opts += "<optgroup label=\"#{h(cont['name'])}\">"
          sorted.each do |cat|
            in_cont[cat['name']] = true
            sel = cat['name'] == selected ? ' selected' : ''
            opts += "<option value=\"#{h(cat['name'])}\"#{sel}>#{h(cat['name'])}</option>"
          end
          opts += "</optgroup>"
        end
        orphans = all_cats.reject { |c| in_cont[c] }.sort_by(&:downcase)
        if orphans.any?
          opts += "<optgroup label=\"Other\">"
          orphans.each do |c|
            sel = c == selected ? ' selected' : ''
            opts += "<option value=\"#{h(c)}\"#{sel}>#{h(c)}</option>"
          end
          opts += "</optgroup>"
        end
        opts + "\n<option value=\"__custom__\">+ Custom...</option>"
      else
        cats = all_cats.sort_by(&:downcase)
        opts = cats.map { |c|
          sel = c == selected ? ' selected' : ''
          "<option value=\"#{h(c)}\"#{sel}>#{h(c)}</option>"
        }.join("\n")
        opts + "\n<option value=\"__custom__\">+ Custom...</option>"
      end
    end

    def self.subcategory_options(cat, selected)
      subs = TakeoffTool.master_subcategories_for(cat)
      opts = '<option value="">--</option>'
      subs.each do |s|
        sel = s == selected ? ' selected' : ''
        opts += "<option value=\"#{h(s)}\"#{sel}>#{h(s)}</option>"
      end
      # Include current value even if not in master list
      if selected && !selected.empty? && !subs.include?(selected)
        opts += "<option value=\"#{h(selected)}\" selected>#{h(selected)}</option>"
      end
      opts + "\n<option value=\"__custom_sub__\">+ Custom...</option>"
    end

    def self.send_categories
      return unless @dialog && @dialog.visible?
      require 'json'
      cats = TakeoffTool.master_categories.reject { |c| c == '_IGNORE' }
      containers = TakeoffTool.master_containers || []
      payload = { categories: cats, containers: containers }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveCategories('#{esc}')") rescue nil
    end

    def self.send_subcategories_for(cat)
      return unless @dialog && @dialog.visible?
      require 'json'
      subs = TakeoffTool.master_subcategories_for(cat)
      js = JSON.generate(subs)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveSubcategories('#{esc}')") rescue nil
    end

    def self.send_apply_result(cat, sub, message, hidden)
      return unless @dialog && @dialog.visible?
      require 'json'
      js = JSON.generate({ category: cat, subcategory: sub, message: message, hidden: hidden })
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveApplyResult('#{esc}')") rescue nil
    end

    MOCHA_CSS = <<~CSS.freeze unless defined?(MOCHA_CSS)
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: 'Segoe UI', system-ui, sans-serif;
        font-size: 12px;
        background: #1e1e2e;
        color: #cdd6f4;
        padding: 16px;
        line-height: 1.5;
        overflow-y: auto;
      }
      h1 {
        font-size: 14px;
        font-weight: 700;
        color: #cba6f7;
        text-transform: uppercase;
        letter-spacing: 1.5px;
        margin-bottom: 14px;
        padding-bottom: 8px;
        border-bottom: 2px solid #313244;
      }
      .entity-name {
        font-size: 13px;
        font-weight: 600;
        color: #89b4fa;
        word-break: break-all;
        margin-bottom: 4px;
      }
      .def-name-sub {
        font-size: 10px;
        color: #6c7086;
        margin-bottom: 12px;
      }
      .row {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        padding: 3px 0;
        border-bottom: 1px solid #181825;
      }
      .label {
        color: #a6adc8;
        font-size: 11px;
        flex-shrink: 0;
        min-width: 85px;
      }
      .value {
        text-align: right;
        font-weight: 500;
        word-break: break-all;
      }
      .cat-assigned { color: #a6e3a1; }
      .cat-unassigned { color: #f38ba8; font-style: italic; }
      .dim { color: #fab387; font-family: Consolas, monospace; font-size: 11px; }
      hr {
        border: none;
        border-top: 1px solid #313244;
        margin: 14px 0;
      }
      select {
        width: 100%;
        padding: 7px 8px;
        background: #313244;
        color: #cdd6f4;
        border: 1px solid #45475a;
        border-radius: 4px;
        font-size: 12px;
        cursor: pointer;
        margin-bottom: 8px;
      }
      select:focus { outline: none; border-color: #89b4fa; }
      .apply-btn {
        width: 100%;
        padding: 8px;
        background: #cba6f7;
        color: #1e1e2e;
        border: none;
        border-radius: 4px;
        font-size: 12px;
        font-weight: 700;
        cursor: pointer;
        text-transform: uppercase;
        letter-spacing: 0.5px;
      }
      .apply-btn:hover { background: #b4befe; }
      .badge {
        display: inline-block;
        padding: 1px 6px;
        border-radius: 3px;
        font-size: 10px;
        font-weight: 600;
      }
      .badge-yes { background: #a6e3a1; color: #1e1e2e; }
      .badge-no { background: #45475a; color: #a6adc8; }
      .multi-count {
        font-size: 16px;
        font-weight: 700;
        color: #cba6f7;
        margin-bottom: 12px;
      }
      .def-list {
        list-style: none;
        max-height: 220px;
        overflow-y: auto;
        margin-bottom: 14px;
      }
      .def-list li {
        padding: 5px 8px;
        background: #181825;
        margin-bottom: 2px;
        border-radius: 4px;
        display: flex;
        justify-content: space-between;
        font-size: 11px;
      }
      .def-list .dname {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .def-list .dcount {
        color: #89b4fa;
        font-weight: 600;
        flex-shrink: 0;
        margin-left: 8px;
      }
      .sect-label {
        font-size: 10px;
        text-transform: uppercase;
        letter-spacing: 1px;
        color: #6c7086;
        margin-bottom: 6px;
      }
    CSS

    MODAL_CSS = <<~CSS.freeze unless defined?(MODAL_CSS)
      .modal-bg{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.6);z-index:200}
      .modal-bg.show{display:block}
      .modal-card{position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);background:#313244;border:1px solid #45475a;border-radius:8px;padding:20px;z-index:201;width:260px;box-shadow:0 8px 32px rgba(0,0,0,0.5)}
      .modal-card h3{font-size:13px;font-weight:600;color:#cdd6f4;margin-bottom:12px}
      .modal-card input[type=text]{width:100%;background:#1e1e2e;border:1px solid #45475a;color:#cdd6f4;border-radius:4px;padding:8px 10px;font-size:12px;font-family:inherit;outline:none;box-sizing:border-box}
      .modal-card input[type=text]:focus{border-color:#cba6f7}
      .modal-btns{display:flex;justify-content:flex-end;gap:8px;margin-top:14px}
      .modal-btns button{padding:6px 16px;border-radius:4px;border:1px solid #45475a;background:#313244;color:#cdd6f4;cursor:pointer;font-size:12px;font-family:inherit}
      .modal-btns button.pri{background:#cba6f7;color:#1e1e2e;border-color:#cba6f7;font-weight:600}
      .modal-btns button:hover{opacity:0.85}
    CSS

    MODAL_HTML = <<~HTML.freeze unless defined?(MODAL_HTML)
      <div id="inputModal" class="modal-bg" onclick="if(event.target===this)cancelModal()">
        <div class="modal-card">
          <h3 id="modalTitle">New category name</h3>
          <input type="text" id="modalInput" onkeydown="if(event.key==='Enter')confirmModal();if(event.key==='Escape')cancelModal();">
          <div class="modal-btns">
            <button onclick="cancelModal()">Cancel</button>
            <button class="pri" onclick="confirmModal()">OK</button>
          </div>
        </div>
      </div>
    HTML

    IDENTIFY_JS = <<~JS.freeze unless defined?(IDENTIFY_JS)
      var _modalCb=null;
      function updateContent(html){
        var container=document.getElementById('idContent');
        if(container){container.innerHTML=html;}
        else{document.body.innerHTML=html+'<div id="inputModal" class="modal-bg" onclick="if(event.target===this)cancelModal()"><div class="modal-card"><h3 id="modalTitle">New category name</h3><input type="text" id="modalInput" onkeydown="if(event.key===\\'Enter\\')confirmModal();if(event.key===\\'Escape\\')cancelModal();"><div class="modal-btns"><button onclick="cancelModal()">Cancel</button><button class="pri" onclick="confirmModal()">OK</button></div></div></div>';}
      }
      function onCatChange(sel){
        if(sel.value==='__custom__'){
          sel.value='';
          showInputModal('New category name',function(name){
            var sub=document.getElementById('subSel');
            var subVal=sub?sub.value:'';if(subVal==='__custom_sub__')subVal='';
            sketchup.applyCategory(JSON.stringify({category:name,subcategory:subVal}));
            sketchup.addCustomCategory(name);
          });
          return;
        }
        // Request subcategories for selected category
        if(sel.value) sketchup.requestSubcategoriesForCat(sel.value);
        else updateSubSel([]);
      }
      function onSubChange(sel){
        if(sel.value==='__custom_sub__'){
          var cat=document.getElementById('catSel').value;
          sel.value='';
          if(!cat)return;
          showInputModal('New subcategory for '+cat,function(name){
            sketchup.applyCategory(JSON.stringify({category:cat,subcategory:name}));
            sketchup.addSubcategoryForCat(JSON.stringify({cat:cat,name:name}));
          });
        }
      }
      function doApply(){
        var cat=document.getElementById('catSel').value;
        var sub=document.getElementById('subSel').value;
        if(sub==='__custom_sub__')sub='';
        if(cat) sketchup.applyCategory(JSON.stringify({category:cat,subcategory:sub||''}));
      }
      function showInputModal(title,cb){
        _modalCb=cb;
        document.getElementById('modalTitle').textContent=title;
        var inp=document.getElementById('modalInput');inp.value='';
        document.getElementById('inputModal').className='modal-bg show';
        setTimeout(function(){inp.focus();},50);
      }
      function confirmModal(){
        var v=document.getElementById('modalInput').value.trim();
        document.getElementById('inputModal').className='modal-bg';
        if(v&&_modalCb)_modalCb(v);
        _modalCb=null;
      }
      function cancelModal(){
        document.getElementById('inputModal').className='modal-bg';
        _modalCb=null;
      }
      function receiveCategories(json){
        try{
          var d=JSON.parse(json);
          var cats=Array.isArray(d)?d:(d.categories||[]);
          var containers=d.containers||[];
          var sel=document.getElementById('catSel');
          var cur=sel.value;
          sel.innerHTML='<option value="">-- Select --</option>';
          if(containers.length>0){
            var inCont={};
            containers.forEach(function(cont){
              if(!cont.categories||!cont.categories.length)return;
              var grp=document.createElement('optgroup');
              grp.label=cont.name;
              var sorted=cont.categories.slice().sort(function(a,b){return a.name.toLowerCase().localeCompare(b.name.toLowerCase());});
              sorted.forEach(function(cat){
                if(cat.name==='_IGNORE')return;
                inCont[cat.name]=true;
                var o=document.createElement('option');
                o.value=cat.name;o.textContent=cat.name;
                if(cat.name===cur)o.selected=true;
                grp.appendChild(o);
              });
              sel.appendChild(grp);
            });
            var orphans=cats.filter(function(c){return c!=='_IGNORE'&&!inCont[c];}).sort(function(a,b){return a.toLowerCase().localeCompare(b.toLowerCase());});
            if(orphans.length){
              var grp=document.createElement('optgroup');grp.label='Other';
              orphans.forEach(function(c){var o=document.createElement('option');o.value=c;o.textContent=c;if(c===cur)o.selected=true;grp.appendChild(o);});
              sel.appendChild(grp);
            }
          }else{
            cats.sort(function(a,b){return a.toLowerCase().localeCompare(b.toLowerCase());});
            cats.forEach(function(c){
              var o=document.createElement('option');o.value=c;o.textContent=c;
              if(c===cur)o.selected=true;sel.appendChild(o);
            });
          }
          var custom=document.createElement('option');
          custom.value='__custom__';custom.textContent='+ Custom...';
          sel.appendChild(custom);
          if(cur)sel.value=cur;
        }catch(e){}
      }
      function receiveSubcategories(json){
        try{
          var subs=JSON.parse(json);
          updateSubSel(subs);
        }catch(e){}
      }
      function updateSubSel(subs){
        var sel=document.getElementById('subSel');
        if(!sel)return;
        var cur=sel.value;
        sel.innerHTML='<option value="">--</option>';
        var found=false;
        for(var i=0;i<subs.length;i++){
          var o=document.createElement('option');
          o.value=subs[i];o.textContent=subs[i];
          if(subs[i]===cur){o.selected=true;found=true;}
          sel.appendChild(o);
        }
        if(cur&&!found){var extra=document.createElement('option');extra.value=cur;extra.textContent=cur;extra.selected=true;sel.appendChild(extra);}
        var custom=document.createElement('option');
        custom.value='__custom_sub__';custom.textContent='+ Custom...';
        sel.appendChild(custom);
      }
      function receiveApplyResult(json){
        try{
          var d=JSON.parse(json);
          // Update category info row
          var rows=document.querySelectorAll('.row');
          for(var i=0;i<rows.length;i++){
            var lbl=rows[i].querySelector('.label');
            var val=rows[i].querySelector('.value');
            if(!lbl||!val)continue;
            if(lbl.textContent==='Category'){
              val.textContent=d.category;
              val.className='value cat-assigned';
            }
            if(lbl.textContent==='Subcategory'){
              val.textContent=d.subcategory||'';
            }
          }
          // Add subcategory row if it doesn't exist and we have one
          if(d.subcategory){
            var hasSub=false;
            for(var j=0;j<rows.length;j++){
              var l2=rows[j].querySelector('.label');
              if(l2&&l2.textContent==='Subcategory'){hasSub=true;break;}
            }
            if(!hasSub){
              for(var k=0;k<rows.length;k++){
                var l3=rows[k].querySelector('.label');
                if(l3&&l3.textContent==='Category'){
                  var nr=document.createElement('div');nr.className='row';
                  nr.innerHTML='<span class="label">Subcategory</span><span class="value">'+d.subcategory+'</span>';
                  rows[k].parentNode.insertBefore(nr,rows[k].nextSibling);
                  break;
                }
              }
            }
          }
          // Update dropdowns
          var catSel=document.getElementById('catSel');
          if(catSel&&d.category){
            var hasC=false;
            for(var m=0;m<catSel.options.length;m++){if(catSel.options[m].value===d.category){hasC=true;break;}}
            if(!hasC){var co=document.createElement('option');co.value=d.category;co.textContent=d.category;var cx=catSel.querySelector('option[value="__custom__"]');if(cx)catSel.insertBefore(co,cx);else catSel.appendChild(co);}
            catSel.value=d.category;
          }
          var subSel=document.getElementById('subSel');
          if(subSel&&d.subcategory){
            var hasS=false;
            for(var n=0;n<subSel.options.length;n++){if(subSel.options[n].value===d.subcategory){hasS=true;break;}}
            if(!hasS){var so=document.createElement('option');so.value=d.subcategory;so.textContent=d.subcategory;var sx=subSel.querySelector('option[value="__custom_sub__"]');if(sx)subSel.insertBefore(so,sx);else subSel.appendChild(so);}
            subSel.value=d.subcategory;
          }
          // Show feedback
          showApplyMsg(d.message,d.hidden);
        }catch(e){}
      }
      function showApplyMsg(msg,isHidden){
        var el=document.getElementById('applyMsg');
        if(!el){
          el=document.createElement('div');el.id='applyMsg';
          var btn=document.querySelector('.apply-btn');
          if(btn)btn.parentNode.insertBefore(el,btn.nextSibling);
          else document.body.appendChild(el);
        }
        el.textContent=msg;
        el.style.cssText='margin-top:8px;padding:8px;border-radius:4px;font-size:11px;font-weight:600;text-align:center;'
          +(isHidden?'background:#fab387;color:#1e1e2e':'background:#a6e3a1;color:#1e1e2e');
        el.style.display='block';el.style.opacity='1';el.style.transition='none';
        setTimeout(function(){el.style.transition='opacity 1s';el.style.opacity='0';},3000);
        setTimeout(function(){el.style.display='none';},4200);
      }
    JS

    def self.build_single_body(entity)
      i = entity_info(entity)
      dim = "#{fmt_dim(i[:w])} &times; #{fmt_dim(i[:h])} &times; #{fmt_dim(i[:d])}"

      cat_class = i[:category] ? 'cat-assigned' : 'cat-unassigned'
      cat_text = i[:category] || 'Unassigned'

      vol_str = (i[:is_solid] && i[:volume]) ? fmt_vol(i[:volume]) : 'N/A'
      solid = i[:is_solid] ? '<span class="badge badge-yes">Yes</span>' : '<span class="badge badge-no">No</span>'

      sub_row = (i[:subcategory] && !i[:subcategory].empty?) ?
        "<div class=\"row\"><span class=\"label\">Subcategory</span><span class=\"value\">#{h(i[:subcategory])}</span></div>" : ''
      ifc_row = i[:ifc] ?
        "<div class=\"row\"><span class=\"label\">IFC Type</span><span class=\"value\">#{h(i[:ifc])}</span></div>" : ''

      defn_line = ''
      if i[:definition] && !i[:definition].empty? && clean_name(i[:definition]) != i[:name]
        defn_line = "<div class=\"def-name-sub\">Definition: #{h(i[:definition])}</div>"
      end

      model_row = ''
      if TakeoffTool.active_mv_view
        mc = i[:model_source] == 'A' ? '#a6e3a1' : '#89b4fa'
        model_row = "<div class=\"row\"><span class=\"label\">Model</span><span class=\"value\" style=\"color:#{mc};font-weight:700\">Model #{i[:model_source]}</span></div>"
      end

      <<~HTML
        <h1>Identify</h1>
        <div class="entity-name">#{h(i[:name])}</div>
        #{defn_line}
        #{model_row}
        <div class="row"><span class="label">Category</span><span class="value #{cat_class}">#{h(cat_text)}</span></div>
        #{sub_row}
        <div class="row"><span class="label">Layer/Tag</span><span class="value">#{h(i[:tag])}</span></div>
        #{ifc_row}
        <div class="row"><span class="label">Material</span><span class="value">#{h(i[:material] || '(none)')}</span></div>
        <div class="row"><span class="label">Size</span><span class="value dim">#{dim}</span></div>
        <div class="row"><span class="label">Solid</span><span class="value">#{solid}</span></div>
        <div class="row"><span class="label">Volume</span><span class="value">#{vol_str}</span></div>
        <div class="row"><span class="label">Instances</span><span class="value">#{i[:instance_count]}</span></div>
        <hr>
        <div class="sect-label">Set Category</div>
        <select id="catSel" onchange="onCatChange(this)">
          <option value="">-- Select --</option>
          #{category_options(i[:category] || '')}
        </select>
        <div class="sect-label" style="margin-top:6px">Subcategory</div>
        <select id="subSel" onchange="onSubChange(this)">
          #{subcategory_options(i[:category] || '', i[:subcategory] || '')}
        </select>
        <button class="apply-btn" onclick="doApply()">Apply</button>
      HTML
    end

    def self.build_multi_body(entities)
      count = entities.length

      # Model source summary (multiverse)
      model_summary = ''
      if TakeoffTool.active_mv_view
        a_count = 0; b_count = 0
        entities.each do |e|
          ms = (e.get_attribute('FormAndField', 'model_source') rescue nil) || 'model_a'
          ms == 'model_a' ? a_count += 1 : b_count += 1
        end
        parts = []
        parts << "<span style=\"color:#a6e3a1;font-weight:600\">#{a_count} Model A</span>" if a_count > 0
        parts << "<span style=\"color:#89b4fa;font-weight:600\">#{b_count} Model B</span>" if b_count > 0
        model_summary = "<div style=\"font-size:11px;color:#a6adc8;margin-bottom:10px\">#{parts.join(' &bull; ')}</div>"
      end

      # Unique definitions with counts
      def_counts = Hash.new(0)
      entities.each do |e|
        defn = e.respond_to?(:definition) ? e.definition : nil
        name = defn ? clean_name(defn.name) : '(unknown)'
        def_counts[name] += 1
      end
      sorted = def_counts.sort_by { |_, c| -c }

      list_items = sorted.map { |name, cnt|
        "<li><span class=\"dname\" title=\"#{h(name)}\">#{h(name)}</span><span class=\"dcount\">(x#{cnt})</span></li>"
      }.join("\n")

      <<~HTML
        <h1>Identify &mdash; #{count} entities selected</h1>
        #{model_summary}
        <div class="sect-label">Definitions</div>
        <ul class="def-list">
          #{list_items}
        </ul>
        <hr>
        <div class="sect-label">Set Category (all #{count})</div>
        <select id="catSel" onchange="onCatChange(this)">
          <option value="">-- Select --</option>
          #{category_options('')}
        </select>
        <div class="sect-label" style="margin-top:6px">Subcategory</div>
        <select id="subSel" onchange="onSubChange(this)">
          <option value="">--</option>
          <option value="__custom_sub__">+ Custom...</option>
        </select>
        <button class="apply-btn" onclick="doApply()">Apply</button>
      HTML
    end

    def self.build_single(entity)
      body = build_single_body(entity)
      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>#{MOCHA_CSS}#{MODAL_CSS}</style></head><body>
        <div id="idContent">#{body}</div>
        #{MODAL_HTML}
        <script>#{IDENTIFY_JS}</script>
        </body></html>
      HTML
    end

    def self.build_multi(entities)
      body = build_multi_body(entities)
      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>#{MOCHA_CSS}#{MODAL_CSS}</style></head><body>
        <div id="idContent">#{body}</div>
        #{MODAL_HTML}
        <script>#{IDENTIFY_JS}</script>
        </body></html>
      HTML
    end
  end
end
