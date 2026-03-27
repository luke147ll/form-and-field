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

    def self.send_vis_state
      return unless @dialog && @dialog.visible?
      return if @current_entities.empty?

      vm = VisibilityManager
      vis_map = {}
      @current_entities.each do |e|
        next unless e.valid?
        eid = e.entityID
        if vm.isolation_active
          vis_map[eid] = vm.isolated_entity_ids.include?(eid)
        else
          vis_map[eid] = !vm.hidden_entity_ids.include?(eid)
        end
      end

      isolated = vm.isolation_active

      require 'json'
      b64 = [JSON.generate({ vis: vis_map, isolated: isolated })].pack('m0')
      @dialog.execute_script("receiveVisState(JSON.parse(atob('#{b64}')))")
    rescue => e
      puts "[FF IdentifyDialog send_vis_state] error: #{e.message}"
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
        if VisibilityManager.isolated?
          @current_entities.each do |e|
            VisibilityManager.on_category_changed(e.entityID, cat)
            hidden_count += 1 unless (TakeoffTool.find_entity(e.entityID)&.visible? rescue true)
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
        raw = name_str.to_s.strip
        next if raw.empty?
        container = nil
        if raw.start_with?('{')
          require 'json'
          data = JSON.parse(raw) rescue {}
          name = (data['name'] || '').strip
          container = (data['container'] || '').strip
          container = nil if container.empty?
        else
          name = raw
        end
        next if name.empty?
        TakeoffTool.add_custom_category(name, target_container: container)
        puts "Takeoff: IdentifyDialog addCustomCategory '#{name}' → container: #{container || 'auto'}"
      end

      @dialog.add_action_callback('createPart') do |_ctx, arg_str|
        begin
          puts "[FF Parts] createPart callback fired, arg: #{arg_str}"
          require 'json'
          data = JSON.parse(arg_str.to_s)
          part_name = data['name'].to_s.strip
          target_cat = data['category'].to_s.strip
          target_sub = data['subcategory'].to_s.strip
          if part_name.empty?
            puts "[FF Parts] ERROR: empty part name"
            next
          end

          entities = @current_entities
          if entities.nil? || entities.empty?
            puts "[FF Parts] ERROR: no current entities"
            next
          end

          # If no category selected in dropdown, fall back to first entity's category
          if target_cat.empty?
            entities.each do |e|
              c = e.get_attribute('TakeoffAssignments', 'category') rescue nil
              unless c
                sr = TakeoffTool.scan_results.find { |r| r[:entity_id] == e.entityID }
                c = sr[:parsed][:auto_category] if sr
              end
              target_cat = c if c && !c.empty?
              break if !target_cat.empty?
            end
            target_cat = 'Uncategorized' if target_cat.empty?
          end

          puts "[FF Parts] Creating part '#{part_name}' from #{entities.length} entities -> #{target_cat}"

          # Move all entities to the target category
          moved = 0
          eids = []
          entities.each do |e|
            c = e.get_attribute('TakeoffAssignments', 'category') rescue nil
            unless c
              sr = TakeoffTool.scan_results.find { |r| r[:entity_id] == e.entityID }
              c = sr[:parsed][:auto_category] if sr
            end
            c ||= 'Uncategorized'
            if c != target_cat
              TakeoffTool.apply_category_to_selection([e], target_cat)
              moved += 1
            end
            TakeoffTool.save_assignment(e.entityID, 'subcategory', target_sub) unless target_sub.empty?
            eids << e.entityID
          end

          TakeoffTool.create_part(part_name, eids, target_cat, target_sub)
          puts "Takeoff: Created part '#{part_name}' with #{eids.length} entities in #{target_cat}#{moved > 0 ? " (#{moved} moved)" : ''}"
          Dashboard.send_live_data if defined?(Dashboard) && Dashboard.respond_to?(:send_live_data)
          msg = "Part '#{part_name}' created - #{eids.length} entities = 1 EA in #{target_cat}"
          @dialog.execute_script("showApplyMsg('#{msg.gsub("'", "\\\\'")}',false)") rescue nil
        rescue => e
          puts "[FF Parts] createPart ERROR: #{e.message}"
          puts e.backtrace.first(5).join("\n")
        end
      end

      @dialog.add_action_callback('addToPart') do |_ctx, arg_str|
        begin
          require 'json'
          data = JSON.parse(arg_str.to_s)
          part_name = data['name'].to_s.strip
          next if part_name.empty?
          entities = @current_entities
          next if entities.nil? || entities.empty?

          # Filter: skip entities that are already part groups
          valid_ents = entities.reject { |e|
            (e.get_attribute('FormAndField', 'is_part') rescue nil) == true
          }
          next if valid_ents.empty?

          eids = valid_ents.map(&:entityID)
          added = TakeoffTool.add_to_part(part_name, eids)
          puts "[FF Parts] Added #{added} entities to part '#{part_name}'"
          Dashboard.send_live_data if defined?(Dashboard) && Dashboard.respond_to?(:send_live_data)
          msg = "Added #{added} to '#{part_name}'"
          @dialog.execute_script("showApplyMsg('#{msg.gsub("'", "\\\\'")}',false)") rescue nil
        rescue => e
          puts "[FF Parts] addToPart ERROR: #{e.message}"
          puts e.backtrace.first(3).join("\n")
        end
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

      @dialog.add_action_callback('idIsolateEntity') do |_ctx|
        eids = @current_entities.select { |e| e.valid? }.map(&:entityID)
        next if eids.empty?
        VisibilityManager.isolate(eids, source: "identify")
        Dashboard.send_vis_state if Dashboard.respond_to?(:send_vis_state)
      end

      @dialog.add_action_callback('idIsolateCategory') do |_ctx, cat_str|
        cat = cat_str.to_s
        next if cat.empty?
        VisibilityManager.isolate_by_category(cat, source: "identify")
        Dashboard.send_vis_state if Dashboard.respond_to?(:send_vis_state)
      end

      @dialog.add_action_callback('idIsolateAssembly') do |_ctx, asm_id_str|
        asm_id = asm_id_str.to_s.strip
        next if asm_id.empty?
        assemblies = TakeoffTool.load_assemblies rescue {}
        asm = assemblies[asm_id]
        next unless asm
        eids = (asm['parts'] || []).reject { |p| p['is_virtual'] }.map { |p| p['entity_id'] }.compact.map(&:to_i)
        next if eids.empty?
        VisibilityManager.isolate(eids, source: "identify:assembly")
        Dashboard.send_vis_state if Dashboard.respond_to?(:send_vis_state)
      end

      @dialog.add_action_callback('idShowAll') do |_ctx|
        VisibilityManager.show_all
        Dashboard.send_vis_state if Dashboard.respond_to?(:send_vis_state)
      end

      @dialog.add_action_callback('idReady') do |_ctx|
        body = @current_entities.length == 1 ? build_single_body(@current_entities.first) : build_multi_body(@current_entities)
        require 'json'
        safe = JSON.generate(body)
        @dialog.execute_script("updateContent(#{safe})")
        send_categories
        send_vis_state
      end

      @dialog.set_file(File.join(PLUGIN_DIR, 'ui', 'identify.html'))
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

      # SKU & Zone
      sku = (e.get_attribute('TakeoffAssignments', 'sku') rescue nil) || ''
      zone = (e.get_attribute('TakeoffAssignments', 'zone') rescue nil) || ''

      # Cost code
      cca = TakeoffTool.cost_code_assignments || {}
      cost_code = cca[eid] || ''

      # Assembly membership
      assemblies = TakeoffTool.assemblies_for_entity(eid) rescue []
      all_asms = TakeoffTool.load_assemblies rescue {}
      assemblies = assemblies.map do |a|
        asm_data = all_asms[a[:asm_id]] || {}
        a.merge(zone: asm_data['zone'] || '')
      end

      # Scan result quantities
      sr = (TakeoffTool.filtered_scan_results rescue []).find { |r| r[:entity_id] == eid }
      linear_ft = sr ? (sr[:linear_ft] || 0).to_f : 0.0
      volume_bf = sr ? (sr[:volume_bf] || 0).to_f : 0.0
      volume_ft3 = sr ? (sr[:volume_ft3] || 0).to_f : 0.0
      area_sf = sr ? (sr[:area_sf] || 0).to_f : 0.0

      {
        name: clean_name(iname || dname),
        definition: dname,
        category: cat, subcategory: sub || '',
        tag: tag, ifc: ifc, material: mat,
        w: w, h: h_val, d: d,
        is_solid: is_solid, volume: vol,
        instance_count: inst_count,
        model_source: model_label,
        sku: sku, zone: zone, cost_code: cost_code,
        assemblies: assemblies,
        linear_ft: linear_ft, volume_bf: volume_bf,
        volume_ft3: volume_ft3, area_sf: area_sf
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
          opts += "<option value=\"__custom_in__#{h(cont['name'])}\">+ Custom...</option>"
          opts += "</optgroup>"
        end
        orphans = all_cats.reject { |c| in_cont[c] }.sort_by(&:downcase)
        if orphans.any?
          opts += "<optgroup label=\"Other\">"
          orphans.each do |c|
            sel = c == selected ? ' selected' : ''
            opts += "<option value=\"#{h(c)}\"#{sel}>#{h(c)}</option>"
          end
          opts += "<option value=\"__custom__\">+ Custom...</option>"
          opts += "</optgroup>"
        end
        opts
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


    def self.build_single_body(entity)
      i = entity_info(entity)
      dim = "#{fmt_dim(i[:w])} &times; #{fmt_dim(i[:h])} &times; #{fmt_dim(i[:d])}"

      vol_str = (i[:is_solid] && i[:volume]) ? fmt_vol(i[:volume]) : 'N/A'
      solid = i[:is_solid] ? '<span class="badge badge-yes">Yes</span>' : '<span class="badge badge-no">No</span>'

      defn_line = ''
      if i[:definition] && !i[:definition].empty? && clean_name(i[:definition]) != i[:name]
        defn_line = "<div class=\"def-name-sub\">Definition: #{h(i[:definition])}</div>"
      end

      # Model badge in header
      model_badge = ''
      if TakeoffTool.active_mv_view
        mc = i[:model_source] == 'A' ? '#a6e3a1' : '#89b4fa'
        model_badge = "<span style=\"font-size:9px;font-weight:700;padding:2px 6px;border-radius:3px;color:#11111b;background:#{mc};margin-left:8px\">Model #{i[:model_source]}</span>"
      end

      # Badge row — category + subcategory only
      badges = ''
      cat_text = i[:category] || 'Unassigned'
      cat_class = i[:category] ? 'id-badge-cat' : ''
      cat_style = i[:category] ? '' : 'color:#f38ba8;background:rgba(243,139,168,.1);border:1px solid rgba(243,139,168,.25);'
      badges += "<span class=\"id-badge #{cat_class}\" style=\"#{cat_style}\" onclick=\"sketchup.idIsolateCategory('#{h(cat_text)}')\" title=\"Isolate category\"><span class=\"id-badge-dot\" style=\"background:#{i[:category] ? '#a6e3a1' : '#f38ba8'}\"></span>#{h(cat_text)}<span class=\"id-badge-iso\">&#8857;</span></span>"

      if i[:subcategory] && !i[:subcategory].empty?
        badges += "<span class=\"id-badge id-badge-sub\"><span class=\"id-badge-dot\" style=\"background:#94e2d5\"></span>#{h(i[:subcategory])}</span>"
      end

      # Assembly cards
      asm_html = ''
      if i[:assemblies] && i[:assemblies].any?
        asm_html = '<div class="sect-label">Assemblies</div><div class="id-asm-list">'
        i[:assemblies].each do |a|
          asm_zone = a[:zone] && !a[:zone].empty? ? "<span class=\"id-asm-zone\">#{h(a[:zone])}</span>" : ''
          asm_html += "<div class=\"id-asm-card\" onclick=\"sketchup.idIsolateAssembly('#{h(a[:asm_id])}')\" title=\"Isolate assembly\"><span class=\"id-asm-dot\"></span><span class=\"id-asm-name\">#{h(a[:name])}</span>#{asm_zone}<span class=\"id-asm-iso\">&#8857;</span></div>"
        end
        asm_html += '</div>'
      end

      # Quantity cards
      qty_html = ''
      has_qty = i[:linear_ft] > 0 || i[:volume_bf] > 0 || i[:volume_ft3] > 0 || i[:area_sf] > 0
      if has_qty
        qty_html = '<div class="sect-label">Quantities</div><div class="id-qty-row">'
        if i[:linear_ft] > 0
          qty_html += "<div class=\"id-qty-card\"><div class=\"id-qty-val\" style=\"color:#74c7ec\">#{i[:linear_ft].round(1)}'</div><div class=\"id-qty-lbl\">Linear Ft</div></div>"
        end
        if i[:volume_bf] > 0
          qty_html += "<div class=\"id-qty-card\"><div class=\"id-qty-val\" style=\"color:#f9e2af\">#{i[:volume_bf].round(0).to_i}</div><div class=\"id-qty-lbl\">Board Ft</div></div>"
        end
        if i[:area_sf] > 0
          qty_html += "<div class=\"id-qty-card\"><div class=\"id-qty-val\" style=\"color:#a6e3a1\">#{i[:area_sf].round(1)}</div><div class=\"id-qty-lbl\">Sq Ft</div></div>"
        end
        if i[:volume_ft3] > 0
          qty_html += "<div class=\"id-qty-card\"><div class=\"id-qty-val\" style=\"color:#fab387\">#{i[:volume_ft3].round(1)}</div><div class=\"id-qty-lbl\">Cubic Ft</div></div>"
        end
        qty_html += '</div>'
      end

      ifc_row = i[:ifc] ? "<div class=\"row\"><span class=\"label\">IFC Type</span><span class=\"value\">#{h(i[:ifc])}</span></div>" : ''

      <<~HTML
        <div style="display:flex;align-items:center;margin-bottom:14px;padding-bottom:8px;border-bottom:2px solid #313244">
          <span style="font-size:13px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1.5px">Identify</span>
          #{model_badge}
        </div>
        <div class="entity-name">#{h(i[:name])}</div>
        #{defn_line}
        <div style="display:flex;gap:6px;margin-bottom:10px">
          <span class="id-iso-btn" onclick="sketchup.idIsolateEntity()" title="Isolate this entity">&#8857; Isolate</span>
          <span class="id-showall-btn" onclick="sketchup.idShowAll()" title="Show all entities">Show All</span>
        </div>
        <div class="id-badges">#{badges}</div>
        #{asm_html}
        #{qty_html}
        <div class="sect-label" style="margin-top:6px">Properties</div>
        <div class="row"><span class="label">Size</span><span class="value dim">#{dim}</span></div>
        <div class="row"><span class="label">Solid</span><span class="value">#{solid}</span></div>
        <div class="row"><span class="label">Volume</span><span class="value">#{vol_str}</span></div>
        <div class="row"><span class="label">Instances</span><span class="value">#{i[:instance_count]}</span></div>
        #{ifc_row}
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
        <div style="display:flex;gap:6px;margin-bottom:10px">
          <span class="id-iso-btn" onclick="sketchup.idIsolateEntity()" title="Isolate selected entities">&#8857; Isolate</span>
          <span class="id-showall-btn" onclick="sketchup.idShowAll()" title="Show all entities">Show All</span>
        </div>
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
        <hr>
        <div class="sect-label">Create Part</div>
        <div style="display:flex;gap:6px">
          <input type="text" id="partNameInput" placeholder="Part name (e.g. Bunk-1)"
            style="flex:1;padding:7px 8px;background:#313244;color:#cdd6f4;border:1px solid #45475a;border-radius:4px;font-size:12px;font-family:inherit"
            onkeydown="if(event.key==='Enter')doCreatePart()">
          <button class="apply-btn" onclick="doCreatePart()" style="width:auto;padding:8px 14px">Create</button>
        </div>
        #{part_add_section}
      HTML
    end

    def self.part_add_section
      parts = TakeoffTool.load_parts rescue {}
      return '' if parts.empty?
      opts = parts.map { |name, pd|
        cat = pd['category'] || '?'
        cnt = pd['child_count'] || 0
        "<option value=\"#{h(name)}\">#{h(name)} (#{cat}, #{cnt} items)</option>"
      }.join("\n")
      <<~HTML
        <div style="margin-top:10px">
          <div class="sect-label">Add to Existing Part</div>
          <div style="display:flex;gap:6px">
            <select id="addToPartSel" style="flex:1;padding:7px 8px;background:#313244;color:#cdd6f4;border:1px solid #45475a;border-radius:4px;font-size:12px">
              <option value="">-- Select Part --</option>
              #{opts}
            </select>
            <button class="apply-btn" onclick="doAddToPart()" style="width:auto;padding:8px 14px;background:#f9e2af;color:#1e1e2e">Add</button>
          </div>
        </div>
      HTML
    end

  end

  # Subscribe to event bus — refresh ID dialog category list when categories change
  subscribe(EVENT_CATEGORIES_CHANGED) do |_payload|
    IdentifyDialog.send_categories if defined?(IdentifyDialog) && IdentifyDialog.respond_to?(:send_categories)
  end
end
