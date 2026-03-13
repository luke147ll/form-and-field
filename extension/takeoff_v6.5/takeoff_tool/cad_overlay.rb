module TakeoffTool
  CAD_TAG_PREFIX = 'FF_CAD_' unless defined?(CAD_TAG_PREFIX)
  CAD_DICT = 'FF_CadOverlay' unless defined?(CAD_DICT)

  CAD_CATEGORIES = {
    'site'       => { label: 'Site Plans',   icon: 'SP', color: '#94e2d5' },
    'plans'      => { label: 'Floor Plans',  icon: 'FP', color: '#89b4fa' },
    'elevations' => { label: 'Elevations',   icon: 'EL', color: '#a6e3a1' },
    'sections'   => { label: 'Sections',     icon: 'SC', color: '#fab387' },
    'details'    => { label: 'Details',       icon: 'DT', color: '#cba6f7' },
    'structural' => { label: 'Structural',   icon: 'ST', color: '#f9e2af' }
  }.freeze unless defined?(CAD_CATEGORIES)

  module CadOverlay

    # ═══════════════════════════════════════════════════════════════
    # IMPORT
    # ═══════════════════════════════════════════════════════════════

    def self.import_sheet
      model = Sketchup.active_model
      return unless model

      path = UI.openpanel('Import CAD Sheet', '', 'CAD Files|*.dwg;*.dxf||')
      return unless path

      filename = File.basename(path, File.extname(path))

      # Snapshot entity IDs before import
      before_ids = {}
      model.active_entities.each { |e| before_ids[e.entityID] = true }
      before_tag_names = {}
      model.layers.each { |t| before_tag_names[t.name] = true }

      # SketchUp shows native DWG import options dialog
      success = model.import(path)
      unless success
        UI.messagebox("Import cancelled or failed for #{File.basename(path)}")
        return
      end

      # Find new entities
      new_entities = model.active_entities.select { |e| !before_ids[e.entityID] }
      if new_entities.empty?
        UI.messagebox("No geometry was imported from #{File.basename(path)}")
        return
      end

      # Gather elevation presets from section cuts
      elev_presets = []
      begin
        presets = SectionCuts.build_presets
        presets.each do |p|
          elev_presets << {
            label: p[:source_label],
            z_inches: p[:source_z],
            z_feet: (p[:source_z] / 12.0).round(2)
          }
        end
      rescue => e
        puts "CadOverlay: could not load elevation presets: #{e.message}"
      end

      # Show naming/elevation dialog
      show_import_dialog(filename, new_entities, before_tag_names, elev_presets)
    end

    # ═══════════════════════════════════════════════════════════════
    # IMPORT DIALOG
    # ═══════════════════════════════════════════════════════════════

    def self.show_import_dialog(default_name, new_entities, before_tag_names, elev_presets = [])
      dlg = UI::HtmlDialog.new(
        dialog_title: "Import CAD Sheet",
        width: 300, height: 340,
        left: 200, top: 200,
        style: UI::HtmlDialog::STYLE_UTILITY,
        resizable: false
      )

      dlg.add_action_callback('save') do |_ctx, json_str|
        dlg.close rescue nil
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          name = default_name if name.empty?
          sheet_type = data['type'].to_s
          sheet_type = 'plan' if sheet_type.empty?

          if sheet_type == 'plan'
            z_inches = data['z_inches']
            if z_inches
              elev_ft = z_inches.to_f / 12.0
            else
              elev_ft = data['elevation'].to_f
            end
          else
            elev_ft = 0.0
          end
          finalize_import(name, elev_ft, new_entities, before_tag_names, sheet_type)
        rescue => e
          puts "CadOverlay: import error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dlg.add_action_callback('cancel') do |_ctx|
        dlg.close rescue nil
        # Undo the import
        begin
          model = Sketchup.active_model
          model.start_operation('Undo CAD Import', true)
          new_entities.each { |e| e.erase! if e.valid? }
          model.commit_operation
        rescue => e
          puts "CadOverlay: cancel cleanup error: #{e.message}"
        end
      end

      dlg.set_html(import_dialog_html(default_name, elev_presets))
      dlg.show
    end

    # ═══════════════════════════════════════════════════════════════
    # FINALIZE IMPORT
    # ═══════════════════════════════════════════════════════════════

    def self.finalize_import(sheet_name, elevation_ft, new_entities, before_tag_names, sheet_type = 'plan')
      model = Sketchup.active_model
      model.start_operation('Import CAD Sheet', true)

      # Flatten all CAD layer assignments to Layer0
      layer0 = model.layers['Layer0'] || model.layers[0]
      valid_entities = new_entities.select(&:valid?)
      flatten_entity_layers(valid_entities, layer0)

      # Group all imported entities
      grp = model.active_entities.add_group(valid_entities)
      grp.name = "CAD: #{sheet_name}"

      # Create tag for visibility toggle
      tag_name = "#{CAD_TAG_PREFIX}#{sheet_name}"
      tag = model.layers[tag_name] || model.layers.add(tag_name)
      tag.color = Sketchup::Color.new(137, 180, 250)
      grp.layer = tag

      # Rotate section to stand upright (Y → Z)
      if sheet_type == 'section'
        center = grp.bounds.center
        rot = Geom::Transformation.rotation(center, X_AXIS, 90.degrees)
        grp.transform!(rot)

        # Auto-rotate to match previously established reference angle
        stored_angle = model.get_attribute(CAD_DICT, 'section_ref_angle')
        if stored_angle
          center = grp.bounds.center
          rot_z = Geom::Transformation.rotation(center, Z_AXIS, stored_angle)
          grp.transform!(rot_z)
          puts "CadOverlay: Auto-rotated section by #{(stored_angle * 180.0 / Math::PI).round(1)}°"
        end
      end

      # Set Z elevation (plans only — sections use alignment tool)
      if sheet_type == 'plan' && elevation_ft.abs > 0.001
        elev_in = elevation_ft * 12.0
        grp.transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, 0, elev_in)))
      end

      # Store metadata
      grp.set_attribute(CAD_DICT, 'sheet_name', sheet_name)
      grp.set_attribute(CAD_DICT, 'elevation_ft', elevation_ft)
      grp.set_attribute(CAD_DICT, 'sheet_type', sheet_type)
      grp.set_attribute(CAD_DICT, 'sheet_category', detect_category(sheet_name, sheet_type))
      grp.set_attribute(CAD_DICT, 'imported_at', Time.now.to_s)

      # Clean up empty CAD layer tags
      cleanup_import_tags(model, before_tag_names)

      model.commit_operation

      # Update stored def_count so CAD imports don't trigger false rescan prompts
      saved = model.get_attribute('FormAndField', 'def_count')
      if saved && saved > 0
        model.set_attribute('FormAndField', 'def_count', TakeoffTool.scannable_def_count(model))
      end

      # Refresh dashboard CAD panel if open
      Dashboard.send_cad_sheets rescue nil

      puts "CadOverlay: Imported '#{sheet_name}' (#{sheet_type}) at EL #{elevation_ft}' (#{valid_entities.length} entities)"

      # Activate alignment tool for sections
      if sheet_type == 'section'
        tool = SectionAlignTool.new(grp)
        model.select_tool(tool)
      end
    end

    # ═══════════════════════════════════════════════════════════════
    # LAYER FLATTEN
    # ═══════════════════════════════════════════════════════════════

    def self.flatten_entity_layers(entities, layer0)
      entities.each do |e|
        next unless e.valid?
        e.layer = layer0 if e.respond_to?(:layer=)
        if e.is_a?(Sketchup::Group)
          flatten_entity_layers(e.entities.to_a, layer0)
        elsif e.respond_to?(:definition)
          flatten_entity_layers(e.definition.entities.to_a, layer0)
        end
      end
    end

    def self.cleanup_import_tags(model, before_tag_names)
      to_remove = []
      model.layers.each do |tag|
        next if before_tag_names[tag.name]
        next if tag.name == 'Layer0' || tag.name == 'Untagged'
        next if tag.name.start_with?(CAD_TAG_PREFIX)
        to_remove << tag
      end
      to_remove.each do |tag|
        begin
          model.layers.remove(tag)
        rescue => e
          puts "CadOverlay: could not remove tag '#{tag.name}': #{e.message}"
        end
      end
      puts "CadOverlay: Cleaned up #{to_remove.length} empty CAD layer tags" if to_remove.length > 0
    end

    # ═══════════════════════════════════════════════════════════════
    # SHEET CATEGORY
    # ═══════════════════════════════════════════════════════════════

    def self.detect_category(sheet_name, sheet_type)
      n = sheet_name
      # Keyword matches (strongest signals)
      return 'details'    if n =~ /\bdetail/i
      return 'sections'   if n =~ /\bsection/i
      return 'elevations' if n =~ /\belevation/i
      return 'site'       if n =~ /\bsite\b/i
      return 'structural' if n =~ /\bstruct/i || n =~ /\bfram/i || n =~ /\bfoundation/i
      # Sheet number prefix (A4-x → sections, A2-x → elevations, etc.)
      return 'details'    if n =~ /\bA5[\s\-\.]/i
      return 'sections'   if n =~ /\bA4[\s\-\.]/i
      return 'elevations' if n =~ /\bA2[\s\-\.]/i
      return 'site'       if n =~ /\bC\d[\s\-\.]/i
      return 'structural' if n =~ /\bS\d[\s\-\.]/i
      # sheet_type fallback
      return 'sections'   if sheet_type == 'section'
      return 'plans'  # default
    end

    def self.set_sheet_category(eid, category)
      model = Sketchup.active_model
      return unless model
      grp = find_sheet_group(model, eid)
      return unless grp
      grp.set_attribute(CAD_DICT, 'sheet_category', category)
    end

    # ═══════════════════════════════════════════════════════════════
    # SHEET MANAGEMENT
    # ═══════════════════════════════════════════════════════════════

    def self.list_sheets
      model = Sketchup.active_model
      return [] unless model
      bmk = TakeoffTool.get_elevation_benchmark
      sheets = []
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        name = grp.get_attribute(CAD_DICT, 'sheet_name')
        next unless name
        stype = grp.get_attribute(CAD_DICT, 'sheet_type') || 'plan'
        cat = grp.get_attribute(CAD_DICT, 'sheet_category')
        cat = detect_category(name, stype) unless cat && !cat.empty?
        elev_ft = grp.get_attribute(CAD_DICT, 'elevation_ft') || 0
        elev_label = ''
        if cat == 'plans' && bmk && elev_ft != 0
          z_inches = elev_ft * 12.0
          pt = Geom::Point3d.new(0, 0, z_inches)
          elev = TakeoffTool.calculate_elevation(pt)
          elev_label = TakeoffTool.format_elevation(elev, bmk['unit']) if elev
        end
        sheets << {
          eid: grp.entityID,
          name: name,
          sheet_type: stype,
          category: cat,
          elevation_ft: elev_ft,
          elevation_label: elev_label,
          imported_at: grp.get_attribute(CAD_DICT, 'imported_at') || '',
          visible: grp.layer ? grp.layer.visible? : true
        }
      end
      sheets
    end

    def self.toggle_sheet(eid)
      model = Sketchup.active_model
      return unless model
      grp = find_sheet_group(model, eid)
      return unless grp
      tag = grp.layer
      tag.visible = !tag.visible? if tag
    end

    def self.set_sheet_elevation(eid, new_elev_ft)
      model = Sketchup.active_model
      return unless model
      grp = find_sheet_group(model, eid)
      return unless grp

      old_elev = grp.get_attribute(CAD_DICT, 'elevation_ft') || 0
      delta_in = (new_elev_ft - old_elev) * 12.0

      model.start_operation('Set Sheet Elevation', true)
      grp.transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, 0, delta_in)))
      grp.set_attribute(CAD_DICT, 'elevation_ft', new_elev_ft)
      model.commit_operation
    end

    def self.delete_sheet(eid)
      model = Sketchup.active_model
      return unless model
      grp = find_sheet_group(model, eid)
      return unless grp

      model.start_operation('Delete CAD Sheet', true)
      tag = grp.layer
      grp.erase!
      if tag && tag.name.start_with?(CAD_TAG_PREFIX)
        model.layers.remove(tag) rescue nil
      end
      model.commit_operation
    end

    # ═══════════════════════════════════════════════════════════════
    # MANAGEMENT DIALOG
    # ═══════════════════════════════════════════════════════════════

    def self.show_manager
      if @manager_dlg && @manager_dlg.visible?
        @manager_dlg.bring_to_front
        refresh_manager
        return
      end

      @manager_dlg = UI::HtmlDialog.new(
        dialog_title: "CAD Overlays",
        width: 360, height: 420,
        left: 120, top: 150,
        style: UI::HtmlDialog::STYLE_UTILITY,
        resizable: true
      )

      @manager_dlg.add_action_callback('importSheet') do |_ctx|
        import_sheet
      end

      @manager_dlg.add_action_callback('toggleSheet') do |_ctx, eid_str|
        toggle_sheet(eid_str.to_i)
        refresh_manager
      end

      @manager_dlg.add_action_callback('setElevation') do |_ctx, json_str|
        require 'json'
        data = JSON.parse(json_str.to_s)
        set_sheet_elevation(data['eid'].to_i, data['elevation'].to_f)
        refresh_manager
      end

      @manager_dlg.add_action_callback('deleteSheet') do |_ctx, eid_str|
        delete_sheet(eid_str.to_i)
        refresh_manager
      end

      @manager_dlg.add_action_callback('zoomSheet') do |_ctx, eid_str|
        model = Sketchup.active_model
        grp = find_sheet_group(model, eid_str.to_i)
        if grp
          model.selection.clear
          model.selection.add(grp)
          model.active_view.zoom(model.selection)
        end
      end

      @manager_dlg.add_action_callback('alignSheet') do |_ctx, eid_str|
        model = Sketchup.active_model
        grp = find_sheet_group(model, eid_str.to_i)
        if grp
          tool = SectionAlignTool.new(grp)
          model.select_tool(tool)
        end
      end

      @manager_dlg.set_on_closed { @manager_dlg = nil }
      @manager_dlg.set_html(manager_html)
      @manager_dlg.show
      refresh_manager
    end

    def self.refresh_manager
      return unless @manager_dlg && @manager_dlg.visible?
      require 'json'
      sheets = list_sheets
      @manager_dlg.execute_script("updateSheets(#{JSON.generate(sheets)})") rescue nil
    end

    # ═══════════════════════════════════════════════════════════════
    # HELPERS
    # ═══════════════════════════════════════════════════════════════

    def self.find_sheet_group(model, eid)
      model.active_entities.grep(Sketchup::Group).find { |g|
        g.valid? && g.entityID == eid && g.get_attribute(CAD_DICT, 'sheet_name')
      }
    end

    # ═══════════════════════════════════════════════════════════════
    # DIALOG HTML
    # ═══════════════════════════════════════════════════════════════

    def self.import_dialog_html(default_name, elev_presets = [])
      require 'json'

      preset_opts = elev_presets.map { |p|
        "<option value=\"#{p[:z_inches]}\">#{p[:label]} (#{p[:z_feet]}&#39;)</option>"
      }.join

      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.4 'Segoe UI',system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;padding:14px}
        .hdr{font-size:11px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1px;text-align:center;margin-bottom:12px}
        label{display:block;color:#a6adc8;font-size:11px;margin-bottom:3px;margin-top:10px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px}
        label:first-of-type{margin-top:0}
        select,input{width:100%;padding:7px 9px;background:#313244;color:#cdd6f4;border:1px solid #585b70;border-radius:5px;font-size:12px;font-family:inherit}
        select:focus,input:focus{outline:none;border-color:#89b4fa}
        .info{font-size:10px;color:#6c7086;margin-top:3px}
        #customElev{display:none;margin-top:6px}
        #customElev.show{display:block}
        .note{font-size:11px;color:#89b4fa;margin-top:10px;padding:8px 10px;background:#313244;border-radius:5px;border-left:3px solid #89b4fa;display:none}
        .note.show{display:block}
        .btns{display:flex;gap:8px;margin-top:16px}
        .btn{flex:1;padding:8px 0;border:none;border-radius:5px;font-size:12px;font-weight:600;cursor:pointer;font-family:inherit;text-align:center}
        .btn-save{background:#a6e3a1;color:#1e1e2e}
        .btn-save:hover{background:#8cd68c}
        .btn-cancel{background:#45475a;color:#cdd6f4}
        .btn-cancel:hover{background:#585b70}
        </style></head><body>
        <div class="hdr">Import CAD Sheet</div>
        <label>Sheet Name</label>
        <input id="name" type="text" value=#{JSON.generate(default_name)}>
        <label>Type</label>
        <select id="sheetType" onchange="onTypeChange()">
          <option value="plan">Floor Plan</option>
          <option value="section">Section / Elevation</option>
        </select>
        <div id="elevSection">
          <label>Place at Elevation</label>
          <select id="elevRef" onchange="onElevChange()">
            #{preset_opts}
            <option value="__custom__">Custom...</option>
          </select>
          <div id="customElev">
            <input id="elev" type="number" value="0" step="0.5" placeholder="Elevation in feet">
          </div>
          <div class="info">Select an elevation benchmark or enter a custom value.</div>
        </div>
        <div id="sectionNote" class="note">Section will be rotated 90&deg; to stand upright. An alignment tool will activate after import.</div>
        <div class="btns">
          <button class="btn btn-cancel" onclick="doCancel()">Cancel</button>
          <button class="btn btn-save" onclick="doSave()">Import</button>
        </div>
        <script>
        function onTypeChange(){
          var t=document.getElementById('sheetType').value;
          document.getElementById('elevSection').style.display=t==='plan'?'':'none';
          document.getElementById('sectionNote').className=t==='section'?'note show':'note';
        }
        function onElevChange(){
          var sel=document.getElementById('elevRef');
          document.getElementById('customElev').className=sel.value==='__custom__'?'show':'';
        }
        function doSave(){
          var name=document.getElementById('name').value.trim();
          var type=document.getElementById('sheetType').value;
          var payload={name:name,type:type};
          if(type==='plan'){
            var sel=document.getElementById('elevRef');
            if(sel.value==='__custom__'){
              payload.elevation=parseFloat(document.getElementById('elev').value)||0;
            } else {
              payload.z_inches=parseFloat(sel.value)||0;
            }
          }
          sketchup.save(JSON.stringify(payload));
        }
        function doCancel(){sketchup.cancel();}
        document.getElementById('name').focus();
        document.getElementById('name').select();
        document.addEventListener('keydown',function(e){
          if(e.key==='Enter')doSave();
          if(e.key==='Escape')doCancel();
        });
        </script>
        </body></html>
      HTML
    end

    def self.manager_html
      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.4 'Segoe UI',system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;padding:14px;overflow-y:auto}
        .hdr{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}
        .hdr h1{font-size:11px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1px}
        .hdr button{background:#89b4fa;color:#1e1e2e;border:none;border-radius:4px;padding:5px 12px;font-size:11px;font-weight:600;cursor:pointer}
        .hdr button:hover{background:#74c7ec}
        .empty{padding:20px;color:#6c7086;font-size:11px;font-style:italic;text-align:center}
        .sheet{background:#313244;border-radius:6px;padding:10px 12px;margin-bottom:8px}
        .sheet-hdr{display:flex;justify-content:space-between;align-items:center}
        .sheet-name{font-weight:600;color:#cdd6f4;font-size:13px}
        .sheet-actions{display:flex;gap:4px}
        .sheet-actions button{background:none;border:none;cursor:pointer;padding:3px;border-radius:3px;display:flex;align-items:center}
        .sheet-actions button:hover{background:#45475a}
        .sheet-actions svg{width:16px;height:16px;stroke:#a6adc8;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
        .sheet-actions button.active svg{stroke:#a6e3a1}
        .sheet-actions button.del svg{stroke:#f38ba8}
        .sheet-detail{display:flex;gap:16px;margin-top:6px;font-size:11px;color:#6c7086}
        .elev-edit{display:inline-flex;align-items:center;gap:4px}
        .elev-edit input{width:60px;padding:2px 5px;background:#45475a;color:#cdd6f4;border:1px solid #585b70;border-radius:3px;font-size:11px;font-family:inherit}
        .elev-edit input:focus{outline:none;border-color:#89b4fa}
        .elev-edit button{background:#89b4fa;color:#1e1e2e;border:none;border-radius:3px;padding:2px 6px;font-size:10px;font-weight:600;cursor:pointer}
        </style></head><body>
        <div class="hdr">
          <h1>CAD Overlays</h1>
          <button onclick="sketchup.importSheet()">+ Import DWG</button>
        </div>
        <div id="sheets"><div class="empty">No CAD sheets imported yet.</div></div>
        <script>
        var ICO_EYE='<svg viewBox="0 0 24 24"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>';
        var ICO_EYE_OFF='<svg viewBox="0 0 24 24"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>';
        var ICO_ZOOM='<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>';
        var ICO_DEL='<svg viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>';
        function X(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML;}
        function updateSheets(sheets){
          var el=document.getElementById('sheets');
          if(!sheets||!sheets.length){el.innerHTML='<div class="empty">No CAD sheets imported yet.</div>';return;}
          var h='';
          for(var i=0;i<sheets.length;i++){
            var s=sheets[i];
            h+='<div class="sheet">';
            h+='<div class="sheet-hdr">';
            var badge=s.sheet_type==='section'?' <span style="font-size:9px;color:#cba6f7;font-weight:400">[SEC]</span>':'';
            h+='<span class="sheet-name">'+X(s.name)+badge+'</span>';
            h+='<div class="sheet-actions">';
            h+='<button class="'+(s.visible?'active':'')+'" onclick="sketchup.toggleSheet(\''+s.eid+'\')" title="'+(s.visible?'Hide':'Show')+'">'+( s.visible?ICO_EYE:ICO_EYE_OFF)+'</button>';
            h+='<button onclick="sketchup.zoomSheet(\''+s.eid+'\')" title="Zoom to Sheet">'+ICO_ZOOM+'</button>';
            if(s.sheet_type==='section'){h+='<button onclick="sketchup.alignSheet(\''+s.eid+'\')" title="Align Section" style="font-size:10px;font-weight:700;color:#cba6f7">&#x2316;</button>';}
            h+='<button class="del" onclick="if(confirm(\'Delete '+X(s.name)+'?\'))sketchup.deleteSheet(\''+s.eid+'\')" title="Delete">'+ICO_DEL+'</button>';
            h+='</div></div>';
            h+='<div class="sheet-detail">';
            h+='<span>EL. '+s.elevation_ft.toFixed(1)+"'</span>";
            h+='<div class="elev-edit"><input type="number" id="elev_'+s.eid+'" value="'+s.elevation_ft+'" step="0.5"><button onclick="setElev('+s.eid+')">Set</button></div>';
            h+='</div>';
            h+='</div>';
          }
          el.innerHTML=h;
        }
        function setElev(eid){
          var v=parseFloat(document.getElementById('elev_'+eid).value)||0;
          sketchup.setElevation(JSON.stringify({eid:eid,elevation:v}));
        }
        </script>
        </body></html>
      HTML
    end

  end

  # ═══════════════════════════════════════════════════════════════════
  # SECTION ALIGNMENT TOOL
  # ═══════════════════════════════════════════════════════════════════

  class SectionAlignTool
    PLANE_TOL = 1.0  # inches — edge counts as horizontal if Z delta < this

    def initialize(section_group)
      @group = section_group
      @ip = Sketchup::InputPoint.new

      # Annotation tags
      @anno_tags = []
      @elev_presets = []

      # 3 plane snaps — each independent
      @section_tag = nil       # selected section/detail tag
      @section_snapped = false
      @grid_tag = nil          # selected gridline tag
      @grid_snapped = false
      @elev_z = nil            # selected elevation (inches)
      @elev_label = ''
      @elev_snapped = false

      # Click mode: what the next click does
      @click_mode = nil  # :grid, :elev, :depth_sec, :depth_mod, :manual_plane
      @dtune_y = nil
      @manual_plane_pt1 = nil  # first click for manual plane

      # Hover
      @hover_plane_z = nil
      @hover_edge_pts = nil

      @panel = nil
    end

    # ── lifecycle ──

    def activate
      load_elevation_presets
      load_annotation_tags
      open_panel
      update_status
      Sketchup.active_model.active_view.invalidate
    end

    def deactivate(view)
      close_panel
      view.invalidate
    end

    def resume(view)
      update_status
      view.invalidate
    end

    # ── input ──

    def onMouseMove(flags, x, y, view)
      @ip.pick(view, x, y)
      @hover_plane_z = nil
      @hover_edge_pts = nil

      if @ip.valid?
        pt = @ip.position
        case @click_mode
        when :elev
          edge_pts = resolve_edge_model_pts
          if edge_pts
            p1, p2 = edge_pts
            if (p1.z - p2.z).abs < PLANE_TOL
              @hover_plane_z = (p1.z + p2.z) / 2.0
              @hover_edge_pts = edge_pts
              view.tooltip = "Z: #{'%.2f' % (@hover_plane_z / 12.0)}' (edge)"
            else
              view.tooltip = "Z: #{'%.2f' % (pt.z / 12.0)}'"
            end
          else
            view.tooltip = "Z: #{'%.2f' % (pt.z / 12.0)}'"
          end
        when :grid
          if @grid_tag
            axis = grid_axis(@grid_tag)
            if axis == :x
              dx = @grid_tag[:point].x - pt.x
              view.tooltip = "X: #{'%.1f' % pt.x}\" → #{@grid_tag[:label]} (dx: #{'%.1f' % dx}\")"
            else
              dy = @grid_tag[:point].y - pt.y
              view.tooltip = "Y: #{'%.1f' % pt.y}\" → #{@grid_tag[:label]} (dy: #{'%.1f' % dy}\")"
            end
          end
        when :manual_plane
          if @manual_plane_pt1
            view.tooltip = "Click second point to define plane direction"
          else
            view.tooltip = "Click first point on the section plane line"
          end
        when :depth_sec, :depth_mod
          view.tooltip = "Y: #{'%.1f' % pt.y}\""
        else
          view.tooltip = "#{'%.1f' % pt.x}\", #{'%.1f' % pt.y}\""
        end
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      @ip.pick(view, x, y)
      return unless @ip.valid?

      case @click_mode
      when :manual_plane
        if @manual_plane_pt1.nil?
          @manual_plane_pt1 = @ip.position.clone
        else
          snap_manual_plane(@manual_plane_pt1, @ip.position)
          @section_snapped = true
          @manual_plane_pt1 = nil
          @click_mode = nil
        end

      when :grid
        snap_grid(@ip.position)
        @grid_snapped = true
        @click_mode = nil

      when :elev
        picked_z = @hover_plane_z || @ip.position.z
        snap_elev(picked_z)
        @elev_snapped = true
        @click_mode = nil

      when :depth_sec
        @dtune_y = @ip.position.y
        @click_mode = :depth_mod

      when :depth_mod
        apply_depth_tune(@ip.position.y)
        @click_mode = nil
      end

      update_panel
      update_status
      view.invalidate
    end

    def onCancel(reason, view)
      case @click_mode
      when :manual_plane
        @click_mode = nil; @manual_plane_pt1 = nil
      when :grid
        @click_mode = nil
      when :elev
        @click_mode = nil
      when :depth_sec
        @click_mode = nil
      when :depth_mod
        @click_mode = nil; @dtune_y = nil
      else
        Sketchup.active_model.select_tool(nil); return
      end
      update_panel; update_status; view.invalidate
    end

    def getMenu(menu, flags, x, y, view)
      menu.add_item('Flip 180°') { flip_180; view.invalidate }
      if @section_snapped || @grid_snapped || @elev_snapped
        menu.add_item('Tune Depth') { @click_mode = :depth_sec; update_panel; update_status; view.invalidate }
      end
      menu.add_item('Skip / Exit') { Sketchup.active_model.select_tool(nil) }
    end

    # ── drawing ──

    def draw(view)
      @ip.draw(view) if @ip.valid?
      return unless @group.valid?
      bounds = @group.bounds

      # Edge highlight during elevation pick
      if @hover_edge_pts
        view.line_stipple = ''; view.line_width = 3
        view.drawing_color = Sketchup::Color.new(249, 226, 175)
        view.draw(GL_LINES, @hover_edge_pts[0], @hover_edge_pts[1])
      end

      # Z plane indicator during elevation pick
      if @click_mode == :elev && @hover_plane_z
        ym = bounds.center.y
        view.drawing_color = Sketchup::Color.new(137, 180, 250, 140)
        view.line_width = 1; view.line_stipple = '.'
        view.draw(GL_LINES,
          Geom::Point3d.new(bounds.min.x - 12, ym, @hover_plane_z),
          Geom::Point3d.new(bounds.max.x + 12, ym, @hover_plane_z))
      end

      # Target elevation line
      if @elev_z
        ym = bounds.center.y
        view.drawing_color = Sketchup::Color.new(203, 166, 247, 180)
        view.line_width = 2; view.line_stipple = '-'
        view.draw(GL_LINES,
          Geom::Point3d.new(bounds.min.x - 24, ym, @elev_z),
          Geom::Point3d.new(bounds.max.x + 24, ym, @elev_z))
        sp = view.screen_coords(Geom::Point3d.new(bounds.max.x + 36, ym, @elev_z))
        view.draw_text(sp, @elev_label, size: 11, color: Sketchup::Color.new(203, 166, 247))
      end

      # Manual plane line preview
      if @click_mode == :manual_plane && @manual_plane_pt1 && @ip.valid?
        view.drawing_color = Sketchup::Color.new(249, 226, 175, 200)
        view.line_width = 2; view.line_stipple = '-'
        view.draw(GL_LINES, @manual_plane_pt1, @ip.position)
        view.line_stipple = ''
        view.draw_points([@manual_plane_pt1], 10, 4, Sketchup::Color.new(249, 226, 175))
      end

      # Gridline target plane during grid pick
      if @grid_tag && @click_mode == :grid
        axis = grid_axis(@grid_tag)
        if axis == :x
          gx = @grid_tag[:point].x
          view.drawing_color = Sketchup::Color.new(243, 139, 168, 180)
          view.line_width = 2; view.line_stipple = '-'
          view.draw(GL_LINES,
            Geom::Point3d.new(gx, bounds.min.y - 24, bounds.center.z),
            Geom::Point3d.new(gx, bounds.max.y + 24, bounds.center.z))
          sp = view.screen_coords(Geom::Point3d.new(gx, bounds.max.y + 36, bounds.center.z))
          view.draw_text(sp, @grid_tag[:label], size: 11, color: Sketchup::Color.new(243, 139, 168))
        else
          gy = @grid_tag[:point].y
          view.drawing_color = Sketchup::Color.new(166, 227, 161, 180)
          view.line_width = 2; view.line_stipple = '-'
          view.draw(GL_LINES,
            Geom::Point3d.new(bounds.min.x - 24, gy, bounds.center.z),
            Geom::Point3d.new(bounds.max.x + 24, gy, bounds.center.z))
          sp = view.screen_coords(Geom::Point3d.new(bounds.max.x + 36, gy, bounds.center.z))
          view.draw_text(sp, @grid_tag[:label], size: 11, color: Sketchup::Color.new(166, 227, 161))
        end
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      bb.add(@group.bounds.min, @group.bounds.max) if @group.valid?
      bb.add(@section_tag[:point]) if @section_tag
      bb.add(@grid_tag[:point]) if @grid_tag
      bb
    end

    private

    def resolve_edge_model_pts
      edge = @ip.edge
      return nil unless edge
      t = @ip.transformation
      [t * edge.start.position, t * edge.end.position]
    rescue
      nil
    end

    # Determine which axis a gridline constrains
    def grid_axis(tag)
      case tag[:axis_lock]
      when 'red'   then :x
      when 'green' then :y
      else
        # Guess: if section was snapped, use the other axis
        if @section_tag && @section_tag[:axis_lock] == 'red'
          :y
        elsif @section_tag && @section_tag[:axis_lock] == 'green'
          :x
        else
          :x  # default
        end
      end
    end

    def load_annotation_tags
      @anno_tags = []
      model = Sketchup.active_model
      return unless model
      require 'json'
      scan_for_tags(model.entities)
      @anno_tags.sort_by! { |t| t[:label] }
      puts "SectionAlignTool: Found #{@anno_tags.length} annotation tags"
    rescue => e
      puts "SectionAlignTool: could not load annotation tags: #{e.message}"
      @anno_tags = []
    end

    def scan_for_tags(entities)
      require 'json'
      entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mode = grp.get_attribute('TakeoffMeasurement', 'tag_mode')
        if mode
          label = grp.get_attribute('TakeoffMeasurement', 'custom_label').to_s
          pt_json = grp.get_attribute('TakeoffMeasurement', 'point')
          axis_lock = grp.get_attribute('TakeoffMeasurement', 'axis_lock').to_s
          if !label.empty? && pt_json
            coords = JSON.parse(pt_json) rescue nil
            if coords && coords.length == 3
              plane_angle = grp.get_attribute('TakeoffMeasurement', 'plane_angle')
              @anno_tags << {
                label: label, mode: mode, axis_lock: axis_lock,
                plane_angle: plane_angle ? plane_angle.to_f : nil,
                point: Geom::Point3d.new(coords[0].to_f, coords[1].to_f, coords[2].to_f)
              }
            end
          end
        end
      end
    end

    def load_elevation_presets
      presets = SectionCuts.build_presets
      @elev_presets = presets.map { |p|
        { label: p[:source_label], z_inches: p[:source_z],
          z_feet: (p[:source_z] / 12.0).round(2) }
      }
    rescue => e
      puts "SectionAlignTool: could not load presets: #{e.message}"
      @elev_presets = []
    end

    # ── snap operations ──

    def snap_section(tag)
      return unless @group.valid?
      model = Sketchup.active_model
      model.start_operation('Snap Section Plane', true)

      # Rotate section to match the tag's plane direction
      stored_angle = model.get_attribute(CAD_DICT, 'section_ref_angle') || 0
      target_angle = tag[:plane_angle] || stored_angle
      delta = target_angle - stored_angle
      if delta.abs > 0.001
        center = @group.bounds.center
        @group.transform!(Geom::Transformation.rotation(center, Z_AXIS, delta))
        model.set_attribute(CAD_DICT, 'section_ref_angle', target_angle)
        puts "SectionAlignTool: Rotated section by #{(delta * 180.0 / Math::PI).round(1)}° to match #{tag[:label]}"
      end

      # Translate center to tag position
      center = @group.bounds.center
      tx = tag[:point].x - center.x
      ty = tag[:point].y - center.y
      @group.transform!(Geom::Transformation.translation(Geom::Vector3d.new(tx, ty, 0)))

      model.commit_operation
      Dashboard.send_cad_sheets rescue nil
      puts "SectionAlignTool: Section snap → #{tag[:label]} (tx=#{'%.1f' % tx}\", ty=#{'%.1f' % ty}\")"
    end

    def snap_manual_plane(pt1, pt2)
      return unless @group.valid?
      dx = pt2.x - pt1.x
      dy = pt2.y - pt1.y
      return if dx.abs < 0.1 && dy.abs < 0.1  # points too close

      # Angle of the clicked line in plan view
      target_angle = Math.atan2(dy, dx)
      # Normalize: the line defines the plane direction, but atan2 gives
      # the vector direction. A section's native orientation after 90° X-rotation
      # is a line along X (0 rad). We want the section to become parallel
      # to the clicked line, so rotate to match.
      model = Sketchup.active_model
      stored_angle = model.get_attribute(CAD_DICT, 'section_ref_angle') || 0
      delta = target_angle - stored_angle

      model.start_operation('Manual Plane Align', true)

      if delta.abs > 0.001
        center = @group.bounds.center
        @group.transform!(Geom::Transformation.rotation(center, Z_AXIS, delta))
        model.set_attribute(CAD_DICT, 'section_ref_angle', target_angle)
        puts "SectionAlignTool: Manual plane rotation #{'%.1f' % (delta * 180.0 / Math::PI)}°"
      end

      # Translate midpoint of the clicked line to group center's XY
      mid_x = (pt1.x + pt2.x) / 2.0
      mid_y = (pt1.y + pt2.y) / 2.0
      center = @group.bounds.center
      tx = mid_x - center.x
      ty = mid_y - center.y
      @group.transform!(Geom::Transformation.translation(Geom::Vector3d.new(tx, ty, 0)))

      model.commit_operation
      Dashboard.send_cad_sheets rescue nil
      puts "SectionAlignTool: Manual plane snap (tx=#{'%.1f' % tx}\", ty=#{'%.1f' % ty}\")"
    end

    def snap_grid(click_pt)
      return unless @group.valid? && @grid_tag
      axis = grid_axis(@grid_tag)
      model = Sketchup.active_model
      model.start_operation('Snap Gridline', true)
      if axis == :x
        dx = @grid_tag[:point].x - click_pt.x
        @group.transform!(Geom::Transformation.translation(Geom::Vector3d.new(dx, 0, 0)))
        puts "SectionAlignTool: Grid snap X → #{@grid_tag[:label]} (dx=#{'%.1f' % dx}\")"
      else
        dy = @grid_tag[:point].y - click_pt.y
        @group.transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, dy, 0)))
        puts "SectionAlignTool: Grid snap Y → #{@grid_tag[:label]} (dy=#{'%.1f' % dy}\")"
      end
      model.commit_operation
      Dashboard.send_cad_sheets rescue nil
    end

    def snap_elev(picked_z)
      return unless @group.valid? && @elev_z
      dz = @elev_z - picked_z
      model = Sketchup.active_model
      model.start_operation('Snap Elevation', true)
      @group.transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, 0, dz)))
      @group.set_attribute(CAD_DICT, 'elevation_ft', (@elev_z / 12.0).round(2))
      model.commit_operation
      Dashboard.send_cad_sheets rescue nil
      puts "SectionAlignTool: Elev snap dz=#{'%.1f' % dz}\" → #{@elev_label}"
    end

    def flip_180
      return unless @group.valid?
      model = Sketchup.active_model
      model.start_operation('Flip Section 180°', true)
      center = @group.bounds.center
      @group.transform!(Geom::Transformation.rotation(center, Z_AXIS, Math::PI))
      stored = model.get_attribute(CAD_DICT, 'section_ref_angle')
      model.set_attribute(CAD_DICT, 'section_ref_angle', (stored || 0) + Math::PI) if stored
      model.commit_operation
      Dashboard.send_cad_sheets rescue nil
      puts "SectionAlignTool: Flipped 180°"
    end

    def apply_depth_tune(model_y)
      return unless @group.valid? && @dtune_y
      dy = model_y - @dtune_y
      model = Sketchup.active_model
      model.start_operation('Tune Section Depth', true)
      @group.transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, dy, 0)))
      model.commit_operation
      Dashboard.send_cad_sheets rescue nil
      puts "SectionAlignTool: Depth tune #{'%.1f' % dy}\""
      @dtune_y = nil
      @click_mode = nil
    end

    # ── panel ──

    def open_panel
      @panel = UI::HtmlDialog.new(
        dialog_title: "Align Section",
        width: 280, height: 480,
        left: 100, top: 200,
        style: UI::HtmlDialog::STYLE_UTILITY,
        resizable: false
      )

      @panel.add_action_callback('setSection') do |_ctx, label|
        tag = @anno_tags.find { |t| t[:label] == label.to_s }
        if tag
          @section_tag = tag
          snap_section(tag)
          @section_snapped = true
          update_panel; update_status
          Sketchup.active_model.active_view.invalidate
        end
      end

      @panel.add_action_callback('setGridline') do |_ctx, label|
        tag = @anno_tags.find { |t| t[:label] == label.to_s }
        @grid_tag = tag
        @grid_snapped = false
        @click_mode = tag ? :grid : nil
        update_panel; update_status
        Sketchup.active_model.active_view.invalidate
      end

      @panel.add_action_callback('setElevation') do |_ctx, z_str|
        z = z_str.to_f
        preset = @elev_presets.find { |p| (p[:z_inches] - z).abs < 0.5 }
        @elev_z = z
        @elev_label = preset ? preset[:label] : "EL. #{'%.2f' % (z / 12.0)}'"
        @elev_snapped = false
        @click_mode = :elev
        update_panel; update_status
        Sketchup.active_model.active_view.invalidate
      end

      @panel.add_action_callback('manualPlane') do |_ctx|
        @manual_plane_pt1 = nil
        @click_mode = :manual_plane
        update_panel; update_status
        Sketchup.active_model.active_view.invalidate
      end

      @panel.add_action_callback('refreshTags') do |_ctx|
        load_annotation_tags
        send_tag_options
        @section_tag = nil; @section_snapped = false
        @grid_tag = nil; @grid_snapped = false
        @click_mode = nil
        update_panel
      end

      @panel.add_action_callback('flip180') do |_ctx|
        flip_180
        Sketchup.active_model.active_view.invalidate
      end

      @panel.add_action_callback('tuneDepth') do |_ctx|
        @click_mode = :depth_sec
        update_panel; update_status
        Sketchup.active_model.active_view.invalidate
      end

      @panel.add_action_callback('skip') do |_ctx|
        Sketchup.active_model.select_tool(nil)
      end

      @panel.set_on_closed {
        @panel = nil
        Sketchup.active_model.select_tool(nil)
      }

      @panel.set_html(align_panel_html)
      @panel.show
    end

    def close_panel
      if @panel
        @panel.set_on_closed {}
        @panel.close rescue nil
        @panel = nil
      end
    end

    def send_tag_options
      return unless @panel && @panel.visible?
      require 'json'
      sec_opts = @anno_tags.select { |t| t[:mode] == 'section' || t[:mode] == 'detail' }.map { |t|
        { value: t[:label], text: t[:label] }
      }
      grid_opts = @anno_tags.select { |t| t[:mode] == 'grid_num' || t[:mode] == 'grid_alpha' }.map { |t|
        axis = case t[:axis_lock]; when 'red' then 'X'; when 'green' then 'Y'; else '' end
        { value: t[:label], text: "#{t[:label]}#{axis.empty? ? '' : " (#{axis})"}" }
      }
      @panel.execute_script("refreshDropdowns(#{JSON.generate(sec_opts)}, #{JSON.generate(grid_opts)})")
    end

    def update_panel
      return unless @panel && @panel.visible?
      require 'json'
      @panel.execute_script("updateState(#{JSON.generate({
        section_snapped: @section_snapped,
        section_label: @section_tag ? @section_tag[:label] : nil,
        grid_snapped: @grid_snapped,
        grid_label: @grid_tag ? @grid_tag[:label] : nil,
        grid_selected: @grid_tag ? true : false,
        elev_snapped: @elev_snapped,
        elev_label: @elev_label,
        elev_selected: @elev_z ? true : false,
        click_mode: @click_mode ? @click_mode.to_s : nil,
        manual_pt1: @manual_plane_pt1 ? true : false
      })})") rescue nil
    end

    def update_status
      Sketchup.status_text = case @click_mode
      when :manual_plane
        if @manual_plane_pt1
          "Click second point to define the section plane line"
        else
          "Click first point along the section plane line"
        end
      when :grid      then "Click gridline #{@grid_tag[:label]} on the section"
      when :elev      then "Click a line at #{@elev_label} on the section"
      when :depth_sec then "Tune Depth — click a point on the section"
      when :depth_mod then "Tune Depth — click matching point on the model"
      else
        if @section_snapped && @grid_snapped && @elev_snapped
          "Aligned — right-click for Tune Depth or Exit"
        else
          "Select references from the panel"
        end
      end
    end

    def align_panel_html
      require 'json'
      elev_opts = @elev_presets.map { |p|
        "<option value=\"#{p[:z_inches]}\">#{p[:label]} (#{p[:z_feet]}&#39;)</option>"
      }.join

      sec_opts = @anno_tags.select { |t| t[:mode] == 'section' || t[:mode] == 'detail' }.map { |t|
        escaped = t[:label].gsub('"', '&quot;')
        "<option value=\"#{escaped}\">#{t[:label]}</option>"
      }.join

      grid_opts = @anno_tags.select { |t| t[:mode] == 'grid_num' || t[:mode] == 'grid_alpha' }.map { |t|
        axis = case t[:axis_lock]; when 'red' then ' (X)'; when 'green' then ' (Y)'; else '' end
        escaped = t[:label].gsub('"', '&quot;')
        "<option value=\"#{escaped}\">#{t[:label]}#{axis}</option>"
      }.join

      has_tags = !@anno_tags.empty?

      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.4 'Segoe UI',system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;padding:14px;overflow-y:auto}
        .hdr{font-size:11px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1px;text-align:center;margin-bottom:12px}
        .refresh{display:flex;justify-content:flex-end;margin-bottom:8px}
        .refresh span{cursor:pointer;font-size:14px;color:#89b4fa}.refresh span:hover{color:#74c7ec}
        .card{background:#313244;border-radius:6px;padding:10px 12px;margin-bottom:8px;border-left:3px solid #585b70}
        .card.done{border-left-color:#a6e3a1}
        .card.waiting{border-left-color:#89b4fa}
        .card-title{font-size:10px;font-weight:700;color:#a6adc8;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
        .card.done .card-title{color:#a6e3a1}
        .card.waiting .card-title{color:#89b4fa}
        select{width:100%;padding:7px 9px;background:#45475a;color:#cdd6f4;border:1px solid #585b70;border-radius:5px;font-size:12px;font-family:inherit}
        select:focus{outline:none;border-color:#89b4fa}
        .card-status{font-size:10px;margin-top:5px;color:#6c7086}
        .card.done .card-status{color:#a6e3a1}
        .card.waiting .card-status{color:#89b4fa}
        .btns{display:flex;gap:8px;margin-top:12px}
        .btn{flex:1;padding:7px 0;border:none;border-radius:5px;font-size:12px;font-weight:600;cursor:pointer;font-family:inherit;text-align:center}
        .btn-skip{background:#45475a;color:#cdd6f4}.btn-skip:hover{background:#585b70}
        .btn-flip{background:#f9e2af;color:#1e1e2e}.btn-flip:hover{background:#f5c2e7}
        .btn-tune{background:#89b4fa;color:#1e1e2e;display:none}.btn-tune:hover{background:#74c7ec}
        .btn-manual{width:100%;padding:6px 0;margin-top:6px;border:none;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer;font-family:inherit;background:#f9e2af;color:#1e1e2e}.btn-manual:hover{background:#f5c2e7}
        .btn-manual.active{background:#89b4fa;color:#1e1e2e}
        .empty{font-size:10px;color:#f38ba8;font-style:italic;margin-bottom:8px}
        .or-divider{text-align:center;color:#6c7086;font-size:10px;margin:6px 0;text-transform:uppercase;letter-spacing:1px}
        </style></head><body>
        <div class="hdr">Align Section</div>
        <div class="refresh"><span onclick="sketchup.refreshTags()" title="Reload tags">&#x21bb; Refresh Tags</span></div>
        #{has_tags ? '' : '<div class="empty">No annotation tags found — place tags then refresh</div>'}

        <div class="card" id="cardSec">
          <div class="card-title">1 — Section Plane</div>
          <select id="secDrop" onchange="if(this.value)sketchup.setSection(this.value)">
            <option value="">— Select section tag —</option>
            #{sec_opts}
          </select>
          <div class="or-divider">— or —</div>
          <button class="btn-manual" id="btnManual" onclick="sketchup.manualPlane()">Click to Set Plane</button>
          <div class="card-status" id="secStatus">Select a section tag or click to set plane manually</div>
        </div>

        <div class="card" id="cardGrid">
          <div class="card-title">2 — Gridline</div>
          <select id="gridDrop" onchange="if(this.value)sketchup.setGridline(this.value)">
            <option value="">— Select gridline —</option>
            #{grid_opts}
          </select>
          <div class="card-status" id="gridStatus">Select a gridline reference</div>
        </div>

        <div class="card" id="cardElev">
          <div class="card-title">3 — Elevation</div>
          <select id="elevDrop" onchange="if(this.value)sketchup.setElevation(this.value)">
            <option value="">— Select elevation —</option>
            #{elev_opts}
          </select>
          <div class="card-status" id="elevStatus">Select an elevation reference</div>
        </div>

        <div class="btns">
          <button class="btn btn-flip" onclick="sketchup.flip180()">Flip 180&deg;</button>
          <button class="btn btn-tune" id="btnTune" onclick="sketchup.tuneDepth()">Tune Depth</button>
          <button class="btn btn-skip" onclick="sketchup.skip()">Skip</button>
        </div>
        <script>
        function refreshDropdowns(secs, grids){
          var sd=document.getElementById('secDrop');
          var gd=document.getElementById('gridDrop');
          var sh='<option value="">— Select section —</option>';
          secs.forEach(function(t){sh+='<option value="'+t.value+'">'+t.text+'</option>';});
          sd.innerHTML=sh;
          var gh='<option value="">— Select gridline —</option>';
          grids.forEach(function(t){gh+='<option value="'+t.value+'">'+t.text+'</option>';});
          gd.innerHTML=gh;
        }
        function updateState(d){
          var cs=document.getElementById('cardSec');
          var ss=document.getElementById('secStatus');
          var bm=document.getElementById('btnManual');
          if(d.section_snapped){
            cs.className='card done';
            ss.textContent='Snapped'+(d.section_label?' to '+d.section_label:' — manual plane');
            bm.className='btn-manual';
          } else if(d.click_mode==='manual_plane'){
            cs.className='card waiting';
            ss.textContent=d.manual_pt1?'Click second point to define plane':'Click first point along the section plane';
            bm.className='btn-manual active';
          } else {
            cs.className='card';
            ss.textContent='Select a section tag or click to set plane manually';
            bm.className='btn-manual';
          }

          var cg=document.getElementById('cardGrid');
          var gs=document.getElementById('gridStatus');
          if(d.grid_snapped){cg.className='card done';gs.textContent='Snapped to '+d.grid_label;}
          else if(d.grid_selected){cg.className='card waiting';gs.textContent='Click gridline '+d.grid_label+' on the section';}
          else{cg.className='card';gs.textContent='Select a gridline reference';}

          var ce=document.getElementById('cardElev');
          var es=document.getElementById('elevStatus');
          if(d.elev_snapped){ce.className='card done';es.textContent='Snapped to '+d.elev_label;}
          else if(d.elev_selected){ce.className='card waiting';es.textContent='Click elevation line on the section';}
          else{ce.className='card';es.textContent='Select an elevation reference';}

          var tune=document.getElementById('btnTune');
          tune.style.display=(d.section_snapped||d.grid_snapped||d.elev_snapped)?'':'none';

          if(d.click_mode==='depth_sec'){es.textContent='Tune Depth — click point on section';ce.className='card waiting';}
          if(d.click_mode==='depth_mod'){es.textContent='Tune Depth — click matching point on model';ce.className='card waiting';}
        }
        </script>
        </body></html>
      HTML
    end
  end

  def self.import_cad_sheet
    CadOverlay.import_sheet
  end

  def self.show_cad_manager
    CadOverlay.show_manager
  end
end
