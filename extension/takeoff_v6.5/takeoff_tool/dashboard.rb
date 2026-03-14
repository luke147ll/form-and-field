module TakeoffTool
  module Dashboard
    @dialog = nil
    @data_dirty = false   # Set true when data changes; checked on close

    def self.load_custom_colors
      require 'json'
      json = Sketchup.active_model.get_attribute('FormAndField', 'custom_colors', '{}')
      JSON.parse(json) rescue {}
    end

    def self.save_custom_colors(colors)
      require 'json'
      Sketchup.active_model.set_attribute('FormAndField', 'custom_colors', JSON.generate(colors))
    end

    # Per-model custom colors: returns the right color set for the active multiverse view
    def self.load_custom_colors_for_view
      mv_view = TakeoffTool.active_mv_view
      return load_custom_colors unless mv_view
      case mv_view
      when 'a'
        key = 'custom_colors_model_a'
      when 'b'
        key = 'custom_colors_model_b'
      else
        return load_custom_colors
      end
      require 'json'
      json = Sketchup.active_model.get_attribute('FormAndField', key, '{}')
      JSON.parse(json) rescue {}
    end

    def self.save_custom_colors_for_view(colors)
      mv_view = TakeoffTool.active_mv_view
      unless mv_view && mv_view != 'ab'
        save_custom_colors(colors)
        return
      end
      key = mv_view == 'a' ? 'custom_colors_model_a' : 'custom_colors_model_b'
      require 'json'
      Sketchup.active_model.set_attribute('FormAndField', key, JSON.generate(colors))
    end

    def self.show(sr, ca, cca)
      if @dialog && @dialog.visible?; send_live_data; return; end

      @dialog = UI::HtmlDialog.new(dialog_title:"Form and Field \u2014 Takeoff Report", preferences_key:"TakeoffDash",
        width:1280, height:780, left:80, top:80, resizable:true, style:UI::HtmlDialog::STYLE_DIALOG)
      @dialog.set_file(File.join(PLUGIN_DIR,'ui','dashboard.html'))

      # All callbacks receive a single JSON string argument and parse it in Ruby.
      # This avoids all multi-arg and encoding issues with skp: protocol.

      @dialog.add_action_callback('requestData') do |_ctx|
        begin
          puts "[FF Dashboard] requestData: #{TakeoffTool.scan_results.length} results, mv=#{TakeoffTool.active_mv_view || 'none'}"
          send_live_data
        rescue => e
          puts "Dashboard: requestData error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        end
      end

      @dialog.add_action_callback('setCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['val'].to_s
          puts "Takeoff: setCategory eid=#{eid} cat=#{cat}"
          _ca = TakeoffTool.category_assignments
          _sr = TakeoffTool.scan_results
          old_cat = _ca[eid] || _sr.find { |r| r[:entity_id] == eid }&.dig(:parsed, :auto_category) || 'Uncategorized'
          _ca[eid] = cat
          RecatLog.log_change(eid, cat)
          # Persist to model — clear subcategory on category change
          TakeoffTool.save_assignment(eid, 'category', cat)
          TakeoffTool.save_assignment(eid, 'subcategory', '')
          _sr.each { |r| if r[:entity_id] == eid; r[:parsed][:auto_subcategory] = ''; break; end }
          # Cascade to nested children (IFC arrays/groups contain child scan entities)
          nested = TakeoffTool.find_nested_scan_eids(eid)
          if nested.any?
            puts "  cascading '#{cat}' to #{nested.length} nested children"
            nested.each do |ceid|
              _ca[ceid] = cat
              TakeoffTool.save_assignment(ceid, 'category', cat)
              TakeoffTool.save_assignment(ceid, 'subcategory', '')
              _sr.each { |r| if r[:entity_id] == ceid; r[:parsed][:auto_subcategory] = ''; break; end }
            end
          end
          # IFC: cascade to all instances of the same definition (compound layers)
          # so the duplicate instance stays in sync
          if (IFCParser.ifc_model?(Sketchup.active_model) rescue false)
            match = _sr.find { |r| r[:entity_id] == eid }
            if match
              dname = match[:definition_name]
              _sr.each do |r|
                next if r[:entity_id] == eid
                next unless r[:definition_name] == dname
                ceid = r[:entity_id]
                next if _ca[ceid] == cat  # already correct
                _ca[ceid] = cat
                TakeoffTool.save_assignment(ceid, 'category', cat)
                TakeoffTool.save_assignment(ceid, 'subcategory', '')
                r[:parsed][:auto_subcategory] = ''
              end
            end
          end
          # Learning system: capture reclassification
          begin; LearningSystem.capture(eid, old_cat, cat); rescue => le; puts "Learning capture error: #{le.message}"; end
          send_live_data
          send_measurement_data  # Auto-update category_scan measurements
          TakeoffTool.trigger_backup
        rescue => e
          puts "Takeoff setCategory error: #{e.message}\n  #{e.backtrace.first(3).join("\n  ")}"
        end
      end

      @dialog.add_action_callback('setCostCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          code = data['val'].to_s
          puts "Takeoff: setCostCode eid=#{eid} code=#{code}"
          TakeoffTool.cost_code_assignments[eid] = code
          # Persist to model
          TakeoffTool.save_assignment(eid, 'cost_code', code)
        rescue => e
          puts "Takeoff setCostCode error: #{e.message}"
        end
      end

      @dialog.add_action_callback('setSize') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          val = data['val'].to_s
          puts "Takeoff: setSize eid=#{eid} size=#{val}"
          # Save to entity attribute
          TakeoffTool.save_assignment(eid, 'size', val)
          # Update scan results
          TakeoffTool.scan_results.each do |r|
            if r[:entity_id] == eid
              r[:parsed][:size_nominal] = val
              break
            end
          end
        rescue => e
          puts "Takeoff setSize error: #{e.message}"
        end
      end

      # Set measurement type for a category (saves to model-level attribute)
      @dialog.add_action_callback('setMeasurementType') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s
          mt = data['mt'].to_s
          puts "Takeoff: setMeasurementType cat=#{cat} mt=#{mt}"
          # Save to model-level attribute dictionary
          m = Sketchup.active_model
          if m
            m.set_attribute('TakeoffMeasurementTypes', cat, mt)
          end
          # Update all entities in this category in scan results
          _ca = TakeoffTool.category_assignments
          TakeoffTool.scan_results.each do |r|
            ecat = _ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
            if ecat == cat
              r[:parsed][:measurement_type] = mt
            end
          end
          # Recalculate SF areas for entities that may not have been computed during scan
          Scanner.recalculate_sf if %w[sf sf_cy sf_sheets].include?(mt)
          # Resend data so dashboard shows updated measurement types
          send_live_data
        rescue => e
          puts "Takeoff setMeasurementType error: #{e.message}"
        end
      end

      @dialog.add_action_callback('setSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          val = data['val'].to_s
          puts "Takeoff: setSubcategory eid=#{eid} sub=#{val}"
          TakeoffTool.save_assignment(eid, 'subcategory', val)
        rescue => e
          puts "Takeoff setSubcategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('bulkSetSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          val = data['val'].to_s
          puts "Takeoff: bulkSetSubcategory #{eids.length} items -> #{val}"
          eids.each do |eid|
            TakeoffTool.save_assignment(eid.to_i, 'subcategory', val)
          end
          send_live_data
        rescue => e
          puts "Takeoff bulkSetSubcategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('selectEntity') do |_ctx, eid_str|
        e = TakeoffTool.find_entity(eid_str.to_s.to_i)
        if e && e.valid?
          m = Sketchup.active_model; m.selection.clear; m.selection.add(e)
        end
      end

      @dialog.add_action_callback('zoomToEntity') do |_ctx, eid_str|
        e = TakeoffTool.find_entity(eid_str.to_s.to_i)
        if e && e.valid?
          m = Sketchup.active_model; m.selection.clear; m.selection.add(e)
          m.active_view.zoom(e)
        end
      end

      @dialog.add_action_callback('highlightAll') do |_ctx|
        Highlighter.highlight_all(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments)
        @dialog.execute_script("if(typeof clearAllDotStates==='function')clearAllDotStates();")
      end

      @dialog.add_action_callback('highlightCategory') do |_ctx, cat_str|
        Highlighter.clear_all
        Highlighter.highlight_category(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
        @dialog.execute_script("if(typeof clearAllDotStates==='function')clearAllDotStates();")
      end

      @dialog.add_action_callback('highlightSingle') do |_ctx, eid_str|
        Highlighter.highlight_single(eid_str.to_s)
      end

      @dialog.add_action_callback('highlightEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.highlight_entities(ids)
      end

      @dialog.add_action_callback('highlightCategoryColor') do |_ctx, cat_str|
        Highlighter.highlight_category_color(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      @dialog.add_action_callback('clearCategoryColor') do |_ctx, cat_str|
        Highlighter.clear_category_color(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      @dialog.add_action_callback('clearHighlights') do |_ctx|
        Highlighter.clear_all
        @dialog.execute_script("if(typeof clearAllDotStates==='function')clearAllDotStates();")
      end

      @dialog.add_action_callback('isolateCategory') do |_ctx, cat_str|
        cat = cat_str.to_s
        fsr = TakeoffTool.filtered_scan_results
        ca = TakeoffTool.category_assignments
        puts "Dashboard: isolateCategory cat='#{cat}' fsr=#{fsr.length} ca_keys=#{ca.keys.length} mv_view=#{TakeoffTool.active_mv_view}"
        Highlighter.isolate_category(fsr, ca, cat)
      end

      @dialog.add_action_callback('isolateTag') do |_ctx, tag_str|
        Highlighter.isolate_tag(tag_str.to_s)
      end

      @dialog.add_action_callback('hideCategory') do |_ctx, cat_str|
        Highlighter.hide_category(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      @dialog.add_action_callback('showCategory') do |_ctx, cat_str|
        Highlighter.show_category(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      @dialog.add_action_callback('showAll') do |_ctx|
        Highlighter.show_all
      end

      @dialog.add_action_callback('isolateCategoryForModel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          category = data['category'].to_s
          model_id = data['modelId'].to_s
          m = Sketchup.active_model
          next unless m

          prefix = model_id.start_with?('model_b') ? 'model_b' : 'model_a'

          # Collect entities for this model
          visible = []
          hide = []
          found_cats = {}
          fsr = TakeoffTool.filtered_scan_results
          fsr.each do |r|
            e = TakeoffTool.find_entity(r[:entity_id])
            next unless e && e.valid?
            ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'
            next unless ms.start_with?(prefix)
            cat = TakeoffTool.category_assignments[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
            found_cats[cat] = (found_cats[cat] || 0) + 1
            if cat == category
              visible << e
            else
              hide << e
            end
          end

          puts "Dashboard: isolateForModel prefix=#{prefix} cat='#{category}' fsr=#{fsr.length} visible=#{visible.length} hide=#{hide.length} cats=#{found_cats.map{|k,v| "#{k}(#{v})"}.first(8).join(', ')}"

          # Safety: if no entities matched, don't hide everything
          if visible.empty?
            puts "Dashboard: WARNING — no entities matched '#{category}' for #{prefix}, skipping isolate"
            next
          end

          # Build keep-visible set with ancestors
          keep_ids, keep_layers = Highlighter.build_keep_visible_set(visible)

          m.start_operation('Isolate Model Category', true)
          hide.each { |e| e.visible = false unless keep_ids[e.entityID] }
          visible.each { |e| e.visible = true }
          keep_ids.each_value { |a| a.visible = true if a.valid? && !a.visible? }
          keep_layers.each_key do |ln|
            l = m.layers[ln]
            l.visible = true if l && !l.visible?
          end
          m.commit_operation
        rescue => e
          puts "Dashboard: isolateCategoryForModel error: #{e.message}"
        end
      end

      @dialog.add_action_callback('showAllForModel') do |_ctx, model_id_str|
        begin
          m = Sketchup.active_model
          next unless m
          prefix = model_id_str.to_s.start_with?('model_b') ? 'model_b' : 'model_a'

          m.start_operation('Show All Model', true)
          visible = []
          TakeoffTool.filtered_scan_results.each do |r|
            e = TakeoffTool.find_entity(r[:entity_id])
            next unless e && e.valid?
            ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'
            next unless ms.start_with?(prefix)
            e.visible = true
            visible << e
          end
          Highlighter.ensure_ancestors_visible(visible, m) if visible.any?
          m.commit_operation
        rescue => e
          puts "Dashboard: showAllForModel error: #{e.message}"
        end
      end

      @dialog.add_action_callback('hideEntities') do |_ctx, ids_str|
        m = Sketchup.active_model
        m.start_operation('Hide', true)
        meas_changed = false
        eids_to_hide = ids_str.to_s.split(',').map(&:to_i)
        hide_set = Set.new(eids_to_hide)
        scan_eid_set = Set.new((TakeoffTool.scan_results || []).map { |r| r[:entity_id] })
        eids_to_hide.each do |id|
          e = TakeoffTool.find_entity(id)
          next unless e && e.valid?
          # Route measurement entities through highlight hide
          if e.is_a?(Sketchup::Group) && e.get_attribute('TakeoffMeasurement', 'type')
            mtype = e.get_attribute('TakeoffMeasurement', 'type')
            if mtype == 'LF' || mtype == 'ELEV' || mtype == 'BENCHMARK' || mtype == 'NOTE'
              e.visible = false
            elsif mtype == 'SF'
              Highlighter.hide_sf_measurement_faces(m, e)
            end
            e.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
            meas_changed = true
          else
            # Part groups: hide directly (children are intentionally inside)
            is_part = (e.get_attribute('FormAndField', 'is_part') rescue nil) == true
            unless is_part
              # Don't hide if this entity contains scan children that should stay visible
              # (SketchUp cascades hide to all children)
              if e.respond_to?(:definition) && _has_visible_scan_child?(e.definition, scan_eid_set, hide_set)
                next
              end
            end
            e.visible = false
          end
        end
        m.commit_operation
        send_measurement_data if meas_changed
      end

      @dialog.add_action_callback('showEntities') do |_ctx, ids_str|
        m = Sketchup.active_model
        ids = ids_str.to_s.split(',').map(&:to_i)
        meas_changed = false
        m.start_operation('Show', true)
        regular_ids = []
        ids.each do |id|
          e = TakeoffTool.find_entity(id)
          next unless e && e.valid?
          if e.is_a?(Sketchup::Group) && e.get_attribute('TakeoffMeasurement', 'type')
            mtype = e.get_attribute('TakeoffMeasurement', 'type')
            if mtype == 'LF' || mtype == 'ELEV' || mtype == 'BENCHMARK' || mtype == 'NOTE'
              e.visible = true
            elsif mtype == 'SF'
              Highlighter.show_sf_measurement_faces(m, e)
            end
            e.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
            meas_changed = true
          else
            e.visible = true
            regular_ids << e
          end
        end
        Highlighter.ensure_ancestors_visible(regular_ids, m) if regular_ids.any?
        m.commit_operation
        send_measurement_data if meas_changed
      end

      @dialog.add_action_callback('movePartCategory') do |_ctx, arg_str|
        begin
          require 'json'
          data = JSON.parse(arg_str.to_s)
          part_name = data['name'].to_s
          new_cat = data['category'].to_s
          next if part_name.empty? || new_cat.empty?
          parts = TakeoffTool.load_parts rescue {}
          pdata = parts[part_name]
          next unless pdata
          old_cat = pdata['category']
          pdata['category'] = new_cat
          TakeoffTool.save_parts(parts)
          # Update group attribute
          grp = TakeoffTool.find_part_group(part_name)
          if grp
            grp.set_attribute('TakeoffAssignments', 'category', new_cat)
          end
          puts "[FF Parts] Moved part '#{part_name}' from #{old_cat} to #{new_cat}"
          send_live_data
        rescue => e
          puts "[FF Parts] movePartCategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('movePartSubcategory') do |_ctx, arg_str|
        begin
          require 'json'
          data = JSON.parse(arg_str.to_s)
          part_name = data['name'].to_s
          new_sub = data['subcategory'].to_s
          next if part_name.empty?
          parts = TakeoffTool.load_parts rescue {}
          pdata = parts[part_name]
          next unless pdata
          pdata['subcategory'] = new_sub
          TakeoffTool.save_parts(parts)
          grp = TakeoffTool.find_part_group(part_name)
          if grp
            grp.set_attribute('TakeoffAssignments', 'subcategory', new_sub)
          end
          puts "[FF Parts] Moved part '#{part_name}' to subcategory '#{new_sub}'"
          send_live_data
        rescue => e
          puts "[FF Parts] movePartSubcategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('renamePart') do |_ctx, arg_str|
        begin
          require 'json'
          data = JSON.parse(arg_str.to_s)
          old_name = data['oldName'].to_s.strip
          new_name = data['newName'].to_s.strip
          next if old_name.empty? || new_name.empty? || old_name == new_name
          parts = TakeoffTool.load_parts rescue {}
          next unless parts.key?(old_name)
          if parts.key?(new_name)
            puts "[FF Parts] renamePart: '#{new_name}' already exists"
            next
          end
          TakeoffTool.rename_part(old_name, new_name)
          puts "[FF Parts] Renamed part '#{old_name}' -> '#{new_name}'"
          send_live_data
        rescue => e
          puts "[FF Parts] renamePart error: #{e.message}"
        end
      end

      # Part-aware isolate: handles part groups that may not be in scan results
      @dialog.add_action_callback('isolatePartGroup') do |_ctx, eid_str|
        begin
          eid = eid_str.to_s.to_i
          e = TakeoffTool.find_entity(eid)
          next unless e && e.valid?
          m = Sketchup.active_model
          m.start_operation('Isolate Part', true)
          # Hide all top-level entities except this part group
          m.active_entities.each do |ent|
            next unless ent.respond_to?(:visible=)
            ent.visible = (ent.entityID == eid)
          end
          m.commit_operation
          m.active_view.zoom(e)
          puts "[FF Parts] Isolated part group eid=#{eid}"
        rescue => ex
          puts "[FF Parts] isolatePartGroup error: #{ex.message}"
        end
      end

      @dialog.add_action_callback('zoomToEntities') do |_ctx, ids_str|
        m = Sketchup.active_model
        bb = Geom::BoundingBox.new
        ids_str.to_s.split(',').each do |id|
          e = TakeoffTool.find_entity(id.to_i)
          bb.add(e.bounds) if e && e.valid?
        end
        m.active_view.zoom(bb) unless bb.empty?
      end

      @dialog.add_action_callback('exportCSV') do |_ctx|
        Exporter.export_csv(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
      end

      @dialog.add_action_callback('exportHTML') do |_ctx|
        Exporter.export_html(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
      end

      @dialog.add_action_callback('rescan') do |_ctx, tpl_str|
        tpl = tpl_str.to_s.strip
        if !tpl.empty? && defined?(CategoryTemplates)
          puts "Takeoff: Applying template '#{tpl}' before scan"
          CategoryTemplates.apply_template(tpl)
        end
        TakeoffTool.run_scan
      end

      @dialog.add_action_callback('listTemplates') do |_ctx|
        names = defined?(CategoryTemplates) ? CategoryTemplates.list : []
        require 'json'
        safe = JSON.generate(names).gsub('</') { '<\\/' }
        @dialog.execute_script("receiveTemplates(#{safe})")
      end

      @dialog.add_action_callback('activateLF') do |_ctx|
        TakeoffTool.activate_lf_tool
      end

      @dialog.add_action_callback('activateLFForCat') do |_ctx, cat_str|
        TakeoffTool.activate_lf_tool_for_category(cat_str.to_s)
      end

      @dialog.add_action_callback('activateSF') do |_ctx|
        TakeoffTool.activate_sf_tool
      end

      @dialog.add_action_callback('activateSFForCat') do |_ctx, cat_str|
        TakeoffTool.activate_sf_tool_for_category(cat_str.to_s)
      end

      @dialog.add_action_callback('startNormalSample') do |_ctx, cat_str|
        TakeoffTool.activate_normal_sample_tool(cat_str.to_s)
      end

      @dialog.add_action_callback('activateBox') do |_ctx|
        TakeoffTool.activate_box_tool
      end

      @dialog.add_action_callback('activateBoxForCat') do |_ctx, cat_str|
        TakeoffTool.activate_box_tool_for_category(cat_str.to_s)
      end

      @dialog.add_action_callback('importCadSheet') do |_ctx|
        CadOverlay.import_sheet
      end

      @dialog.add_action_callback('toggleCadSheet') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          show = data['show']
          grp = CadOverlay.find_sheet_group(Sketchup.active_model, eid)
          if grp && grp.layer
            grp.layer.visible = !!show
          end
        rescue => e
          puts "Dashboard: toggleCadSheet error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deleteCadSheet') do |_ctx, eid_str|
        CadOverlay.delete_sheet(eid_str.to_i)
        send_cad_sheets
      end

      @dialog.add_action_callback('zoomCadSheet') do |_ctx, eid_str|
        model = Sketchup.active_model
        grp = CadOverlay.find_sheet_group(model, eid_str.to_i)
        if grp
          model.selection.clear
          model.selection.add(grp)
          model.active_view.zoom(model.selection)
        end
      end

      @dialog.add_action_callback('alignCadSheet') do |_ctx, eid_str|
        model = Sketchup.active_model
        grp = CadOverlay.find_sheet_group(model, eid_str.to_i)
        if grp
          tool = SectionAlignTool.new(grp)
          model.select_tool(tool)
        end
      end

      @dialog.add_action_callback('setCadCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          CadOverlay.set_sheet_category(data['eid'].to_i, data['category'].to_s)
          send_cad_sheets
        rescue => e
          puts "Dashboard: setCadCategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('showAllCad') do |_ctx|
        model = Sketchup.active_model
        model.active_entities.grep(Sketchup::Group).each do |grp|
          next unless grp.valid? && grp.get_attribute('FF_CadOverlay', 'sheet_name')
          grp.layer.visible = true if grp.layer
        end
        send_cad_sheets
      end

      @dialog.add_action_callback('clearNormal') do |_ctx, cat_str|
        begin
          cat = cat_str.to_s
          m = Sketchup.active_model
          m.set_attribute('TakeoffSFNormals', cat, nil) if m
          puts "Takeoff: Cleared sampled normal for '#{cat}'"
          Scanner.recalculate_sf
          send_live_data
        rescue => e
          puts "Takeoff clearNormal error: #{e.message}"
        end
      end

      @dialog.add_action_callback('openHyperParse') do |_ctx|
        HyperParser.show_dialog
      end

      @dialog.add_action_callback('addCustomCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        unless name.empty?
          TakeoffTool.add_custom_category(name)
          puts "Takeoff: addCustomCategory '#{name}'"
        end
      end

      # Bulk set category for multiple entities at once
      @dialog.add_action_callback('bulkSetCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          cat = data['val'].to_s
          puts "Takeoff: bulkSetCategory #{eids.length} items -> #{cat}"
          _ca = TakeoffTool.category_assignments
          _sr = TakeoffTool.scan_results
          first_old_cat = nil
          all_eids = []
          eids.each do |eid|
            eid_i = eid.to_i
            all_eids << eid_i
            # Cascade to nested children
            nested = TakeoffTool.find_nested_scan_eids(eid_i)
            all_eids.concat(nested) if nested.any?
          end
          all_eids.uniq!
          puts "  (#{all_eids.length} total with nested children)" if all_eids.length > eids.length
          all_eids.each do |eid_i|
            old_cat = _ca[eid_i] || _sr.find { |r| r[:entity_id] == eid_i }&.dig(:parsed, :auto_category) || 'Uncategorized'
            first_old_cat ||= old_cat
            _ca[eid_i] = cat
            RecatLog.log_change(eid_i, cat)
            TakeoffTool.save_assignment(eid_i, 'category', cat)
            TakeoffTool.save_assignment(eid_i, 'subcategory', '')
            _sr.each { |r| if r[:entity_id] == eid_i; r[:parsed][:auto_subcategory] = ''; break; end }
          end
          # Learning system: capture from first entity in bulk
          if eids.length > 0 && first_old_cat
            begin; LearningSystem.capture(eids.first.to_i, first_old_cat, cat); rescue => le; puts "Learning capture error: #{le.message}"; end
          end
          send_live_data
          TakeoffTool.trigger_backup
        rescue => e
          puts "Takeoff bulkSetCategory error: #{e.message}"
        end
      end

      # Rename an entire category (delegates to atomic TakeoffTool.rename_category)
      @dialog.add_action_callback('renameCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          old_name = data['oldName'].to_s.strip
          new_name = data['newName'].to_s.strip
          puts "Takeoff: renameCategory '#{old_name}' -> '#{new_name}'"
          TakeoffTool.rename_category(old_name, new_name)
        rescue => e
          puts "Takeoff renameCategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deleteCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        TakeoffTool.remove_category(name)
        puts "Takeoff: deleteCategory '#{name}'"
      end

      @dialog.add_action_callback('addEmptyCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        unless name.empty?
          TakeoffTool.add_custom_category(name)
          send_live_data
          puts "Takeoff: addEmptyCategory '#{name}'"
        end
      end

      @dialog.add_action_callback('debugHTML') do |_ctx, html|
        puts "=== RENDERED HTML (first 5000 chars) ==="
        puts html.to_s
        puts "=== END ==="
      end

      @dialog.add_action_callback('debugMsg') do |_ctx, msg|
        puts "[FF Debug]\n#{msg}"
      end

      @dialog.add_action_callback('recalculateSF') do |_ctx|
        begin
          count = Scanner.recalculate_sf
          send_live_data
          @dialog.execute_script("console.log('Recalculated SF for #{count} entities')")
        rescue => e
          puts "Dashboard: recalculateSF error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      @dialog.add_action_callback('debugArea') do |_ctx, eid_str|
        begin
          eid = eid_str.to_i
          Scanner.debug_area(eid)
        rescue => e
          puts "[FF Debug] debugArea error: #{e.message}"
        end
      end

      @dialog.add_action_callback('debugAreaCategory') do |_ctx, cat_str|
        begin
          Scanner.debug_area_category(cat_str.to_s)
        rescue => e
          puts "[FF Debug] debugAreaCategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('debugOcclusion') do |_ctx, cat_str|
        begin
          Scanner.debug_occlusion(cat_str.to_s)
        rescue => e
          puts "[FF Debug] debugOcclusion error: #{e.message}"
        end
      end

      @dialog.add_action_callback('debugOccSingle') do |_ctx, eid_str|
        begin
          Scanner.debug_occlusion_single(eid_str.to_i)
        rescue => e
          puts "[FF Debug] debugOccSingle error: #{e.message}"
        end
      end

      @dialog.add_action_callback('clearDebug') do |_ctx|
        begin
          Scanner.clear_debug
        rescue => e
          puts "[FF Debug] clearDebug error: #{e.message}"
        end
      end

      @dialog.add_action_callback('addContainer') do |_ctx, name_str|
        begin
          name = name_str.to_s.strip
          unless name.empty?
            TakeoffTool.add_container(name)
            puts "[FF] addContainer '#{name}' — now #{(TakeoffTool.master_containers || []).length} containers"
            send_live_data
          end
        rescue => e
          puts "[FF] addContainer ERROR: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      @dialog.add_action_callback('addCategoryToContainer') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat_name = data['category'].to_s.strip
          cont_name = data['container'].to_s.strip
          unless cat_name.empty? || cont_name.empty?
            TakeoffTool.add_category_to_container(cat_name, cont_name)
            send_live_data
            puts "Takeoff: addCategoryToContainer '#{cat_name}' in '#{cont_name}'"
          end
        rescue => e
          puts "Takeoff addCategoryToContainer error: #{e.message}"
        end
      end

      @dialog.add_action_callback('addSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          name = data['name'].to_s.strip
          TakeoffTool.add_subcategory(cat, name)
        rescue => e
          puts "Takeoff addSubcategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('renameSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          old_name = data['oldName'].to_s.strip
          new_name = data['newName'].to_s.strip
          TakeoffTool.rename_subcategory(cat, old_name, new_name)
        rescue => e
          puts "Takeoff renameSubcategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deleteSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          name = data['name'].to_s.strip
          TakeoffTool.remove_subcategory(cat, name)
        rescue => e
          puts "Takeoff deleteSubcategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('moveSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          source_cat = data['sourceCat'].to_s.strip
          sub_name = data['sub'].to_s.strip
          target_cat = data['targetCat'].to_s.strip
          TakeoffTool.move_subcategory(source_cat, sub_name, target_cat)
        rescue => e
          puts "Takeoff moveSubcategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('moveCategoryToContainer') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat_name = data['category'].to_s.strip
          target_cont = data['targetContainer'].to_s.strip
          TakeoffTool.move_category_to_container(cat_name, target_cont)
        rescue => e
          puts "Takeoff moveCategoryToContainer error: #{e.message}"
        end
      end

      # Bulk set size for multiple entities at once
      @dialog.add_action_callback('bulkSetSize') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          val = data['val'].to_s
          puts "Takeoff: bulkSetSize #{eids.length} items -> #{val}"
          eids.each do |eid|
            eid_i = eid.to_i
            TakeoffTool.save_assignment(eid_i, 'size', val)
            TakeoffTool.scan_results.each do |r|
              if r[:entity_id] == eid_i
                r[:parsed][:size_nominal] = val
                break
              end
            end
          end
          send_live_data
        rescue => e
          puts "Takeoff bulkSetSize error: #{e.message}"
        end
      end

      # Bulk set cost code for multiple entities at once
      @dialog.add_action_callback('bulkSetCostCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          code = data['val'].to_s
          puts "Takeoff: bulkSetCostCode #{eids.length} items -> #{code}"
          eids.each do |eid|
            eid_i = eid.to_i
            TakeoffTool.cost_code_assignments[eid_i] = code
            TakeoffTool.save_assignment(eid_i, 'cost_code', code)
          end
          send_live_data
        rescue => e
          puts "Takeoff bulkSetCostCode error: #{e.message}"
        end
      end

      # ─── Cosmetic flag ───
      @dialog.add_action_callback('setCosmetic') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          val = data['val'] == true
          eids.each do |eid|
            e = TakeoffTool.find_entity(eid.to_i)
            next unless e && e.valid?
            if val
              e.set_attribute('FormAndField', 'cosmetic', true)
            else
              e.delete_attribute('FormAndField', 'cosmetic')
            end
          end
          puts "[FF] setCosmetic #{eids.length} items -> #{val}"
          send_live_data
        rescue => e
          puts "setCosmetic error: #{e.message}"
        end
      end

      # ─── Measurement visibility callbacks ───

      @dialog.add_action_callback('toggleMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          show = data['show']
          if show
            Highlighter.show_measurement_highlight(eid)
          else
            Highlighter.hide_measurement_highlight(eid)
          end
        rescue => e
          puts "Takeoff toggleMeasurement error: #{e.message}"
        end
      end

      @dialog.add_action_callback('showAllMeasurements') do |_ctx|
        Highlighter.show_all_measurement_highlights
        send_measurement_data
      end

      @dialog.add_action_callback('hideAllMeasurements') do |_ctx|
        Highlighter.hide_all_measurement_highlights
        send_measurement_data
      end

      @dialog.add_action_callback('deleteMeasurement') do |_ctx, eid_str|
        begin
          eid = eid_str.to_s.to_i
          Highlighter.delete_measurement(eid)
          send_live_data
          send_measurement_data
        rescue => e
          puts "Takeoff deleteMeasurement error: #{e.message}"
        end
      end

      @dialog.add_action_callback('requestMeasurements') do |_ctx|
        send_measurement_data
      end

      # ── Derived Parts ──
      @dialog.add_action_callback('createDerivedPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          id = "dp_#{Time.now.to_i}_#{rand(1000)}"
          parts[id] = data
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          send_measurement_data
        rescue => e
          puts "Dashboard createDerivedPart error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deleteDerivedPart') do |_ctx, id_str|
        begin
          require 'json'
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          parts.delete(id_str.to_s)
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          send_measurement_data
        rescue => e
          puts "Dashboard deleteDerivedPart error: #{e.message}"
        end
      end

      @dialog.add_action_callback('editDerivedPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          id = data.delete('id')
          if parts[id]
            data.each { |k, v| parts[id][k] = v }
            m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          end
          send_measurement_data
        rescue => e
          puts "Dashboard editDerivedPart error: #{e.message}"
        end
      end

      # ── Category Scan Measurement ──
      # User-initiated: scans all entities in a category, sums the requested
      # quantity type, and stores the result as a derived part (sourceType=category_scan).
      @dialog.add_action_callback('generateCategoryMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat  = data['category'].to_s
          unit = data['unit'].to_s       # LF, SF, CF, or BM (beam → treated as LF)
          unit = 'LF' if unit == 'BM'    # Beam inventory uses LF computation
          m = Sketchup.active_model

          sr = TakeoffTool.filtered_scan_results || []
          ca = TakeoffTool.category_assignments || {}
          reg = TakeoffTool.instance_variable_get(:@entity_registry) || {}
          total = 0.0
          count = 0
          eids  = []
          seen_eids = {}
          mv_active = TakeoffTool.active_mv_view != nil
          seen_defns = mv_active ? {} : nil
          is_ifc = (IFCParser.ifc_model?(m) rescue false)
          skipped_mv = 0
          skipped_ifc = 0

          # IFC two-pass: find preferred instance per definition
          # (prefer explicitly assigned instances so recategorized entities count correctly)
          ifc_preferred = nil
          if is_ifc
            ifc_preferred = {}
            sr.each do |r|
              next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
              dname = r[:definition_name] || r[:display_name] || ''
              next if dname.empty?
              eid2 = r[:entity_id]
              has_ca = !!ca[eid2]
              if !has_ca
                e2 = reg[eid2]
                has_ca = !!(e2 && e2.valid? && (e2.get_attribute('TakeoffAssignments', 'category') rescue nil))
              end
              prev = ifc_preferred[dname]
              if prev.nil? || (has_ca && !prev[:assigned])
                ifc_preferred[dname] = { eid: eid2, assigned: has_ca }
              end
            end
          end

          puts ""
          puts "═══ generateCategoryMeasurement: '#{cat}' #{unit} ═══"
          puts "  scan_results total: #{sr.length}#{mv_active ? ' (multiverse dedup ON)' : ''}#{is_ifc ? ' (IFC dedup ON)' : ''}"

          sr.each do |r|
            next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
            eid = r[:entity_id]
            assigned = ca[eid]
            auto = (r[:parsed][:auto_category] rescue nil)
            if assigned.nil?
              e = reg[eid]
              assigned = (e && e.valid?) ? (e.get_attribute('TakeoffAssignments', 'category') rescue nil) : nil
            end
            rcat = assigned || auto || 'Uncategorized'
            next unless rcat == cat

            val = case unit
                  when 'LF' then (r[:linear_ft] || 0).to_f
                  when 'SF' then (r[:area_sf] || 0).to_f
                  when 'CF' then (r[:volume_ft3] || 0).to_f
                  else 0.0
                  end
            next if val <= 0

            if seen_eids[eid]
              next
            end
            seen_eids[eid] = true

            # Multiverse dedup only when A/B is active
            if seen_defns
              e ||= reg[eid]
              defn_name = (e && e.valid? && e.respond_to?(:definition)) ? e.definition.name : (r[:definition_name] || r[:display_name])
              dedup_key = "#{defn_name}|#{val.round(2)}"
              if seen_defns[dedup_key]
                skipped_mv += 1
                next
              end
              seen_defns[dedup_key] = true
            end

            # IFC compound layer dedup: only count the preferred instance per definition
            if ifc_preferred
              dname = r[:definition_name] || r[:display_name] || ''
              pref = ifc_preferred[dname]
              if pref && pref[:eid] != eid
                skipped_ifc += 1
                next
              end
            end

            total += val
            count += 1
            eids << eid
            puts "  #{count}. eid=#{eid} '#{r[:display_name]}' = #{val.round(2)} #{unit}"
          end
          puts "  Skipped #{skipped_mv} multiverse duplicates" if skipped_mv > 0
          puts "  Skipped #{skipped_ifc} IFC compound duplicates" if skipped_ifc > 0
          puts "  TOTAL: #{total.round(2)} #{unit} from #{count} entities"
          puts "═══════════════════════════════════════════════"

          if total > 0
            dp_json = m.get_attribute('FormAndField', 'derived_parts')
            parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
            # Replace existing category_scan for same category+unit (prevent duplicates)
            existing = parts.find { |_k, v| v['sourceType'] == 'category_scan' && v['category'] == cat && v['unit'] == unit }
            id = existing ? existing[0] : "csm_#{Time.now.to_i}_#{rand(1000)}"
            parts[id] = {
              'name'          => "#{cat} (auto #{unit})",
              'category'      => cat,
              'sourceType'    => 'category_scan',
              'sourceUnit'    => unit,
              'unit'          => unit,
              'multiplier'    => 1.0,
              'computedValue' => total.round(2),
              'entityCount'   => count,
              'entityIds'     => eids,
              'note'          => "Scanned from #{count} entities"
            }
            m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
            send_measurement_data
          else
            @dialog.execute_script("showToast('No #{unit} data found for #{cat.gsub("'","\\\\'")}','warning')")
          end
        rescue => e
          puts "Dashboard generateCategoryMeasurement error: #{e.message}"
        end
      end

      @dialog.add_action_callback('highlightCategoryScan') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat  = data['category'].to_s
          unit = data['unit'].to_s

          if unit == 'SF' && !cat.empty?
            # Use face-level debug: paints measured faces green, excluded red
            Scanner.clear_debug
            Scanner.debug_area_category(cat)
          elsif unit == 'LF' && !cat.empty?
            # Use face-level debug: paints end caps blue, side faces green
            Scanner.clear_debug
            Scanner.debug_lf_category(cat)
          else
            # CF/other: highlight whole entities
            eids = data['entityIds'] || []
            ids = eids.map(&:to_i)
            Highlighter.clear_all
            Highlighter.highlight_entities(ids) if ids.any?
          end
        rescue => e
          puts "Dashboard highlightCategoryScan error: #{e.message}"
        end
      end

      @dialog.add_action_callback('highlightBeamEntities') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = (data['eids'] || []).map(&:to_i)
          Highlighter.clear_all
          Highlighter.highlight_entities(eids) if eids.any?
        rescue => e
          puts "Dashboard highlightBeamEntities error: #{e.message}"
        end
      end

      @dialog.add_action_callback('updateElevLabel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          new_label = data['label'].to_s.strip
          m = Sketchup.active_model
          grp = TakeoffTool.find_entity(eid)
          if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'ELEV'
            m.start_operation('Update Elevation Label', true)
            grp.set_attribute('TakeoffMeasurement', 'custom_label', new_label)
            m.commit_operation
            send_measurement_data
          end
        rescue => e
          puts "Takeoff updateElevLabel error: #{e.message}"
        end
      end

      @dialog.add_action_callback('updateNoteText') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          new_text = data['text'].to_s.strip
          grp = TakeoffTool.find_entity(eid)
          if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'NOTE'
            m = Sketchup.active_model
            m.start_operation('Update Note Text', true)
            grp.set_attribute('TakeoffMeasurement', 'note', new_text)
            m.commit_operation
            send_measurement_data
          end
        rescue => e
          puts "Takeoff updateNoteText error: #{e.message}"
        end
      end

      @dialog.add_action_callback('activateNote') do |_ctx|
        TakeoffTool.activate_note_tool
      end

      @dialog.add_action_callback('requestBenchmark') do |_ctx|
        send_benchmark_data
      end

      @dialog.add_action_callback('activateBenchmark') do |_ctx|
        TakeoffTool.activate_benchmark_tool
      end

      @dialog.add_action_callback('activateElevation') do |_ctx|
        TakeoffTool.activate_elevation_tool
      end

      # ═══ SECTION CUTS ═══

      @dialog.add_action_callback('requestSectionCuts') do |_ctx|
        send_section_cuts
      end

      @dialog.add_action_callback('activateSectionCut') do |_ctx, name_str|
        begin
          name = name_str.to_s
          puts "Dashboard: activateSectionCut '#{name}'"
          SectionCuts.activate_cut(name)
          send_section_cuts
        rescue => e
          puts "Dashboard: activateSectionCut error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      @dialog.add_action_callback('deactivateSectionCuts') do |_ctx|
        begin
          SectionCuts.deactivate_all
          send_section_cuts
        rescue => e
          puts "Dashboard: deactivateSectionCuts error: #{e.message}"
        end
      end

      @dialog.add_action_callback('refreshSectionCuts') do |_ctx|
        begin
          SectionCuts.remove_all_planes
          SectionCuts.cuts.clear
          SectionCuts.build_presets
          SectionCuts.sync_planes
          send_section_cuts
        rescue => e
          puts "Dashboard: refreshSectionCuts error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      @dialog.add_action_callback('removeSectionCut') do |_ctx, name_str|
        SectionCuts.remove_cut(name_str.to_s)
        send_section_cuts
      end

      @dialog.add_action_callback('addCustomSectionCut') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          label = data['label'].to_s.strip
          z = data['z'].to_f
          next if label.empty? || z == 0
          SectionCuts.add_custom_cut(label, z)
          send_section_cuts
        rescue => e
          puts "Dashboard: addCustomSectionCut error: #{e.message}"
        end
      end

      # ═══ MULTIVERSE ═══

      @dialog.add_action_callback('setMultiverseView') do |_ctx, mode_str|
        TakeoffTool.set_multiverse_view(mode_str.to_s)
      end

      @dialog.add_action_callback('importComparisonModel') do |_ctx|
        TakeoffTool.import_comparison_model
      end

      @dialog.add_action_callback('removeComparisonModel') do |_ctx|
        TakeoffTool.remove_comparison_model
      end

      @dialog.add_action_callback('requestMultiverseData') do |_ctx|
        send_multiverse_data
      end

      @dialog.add_action_callback('rescanModelB') do |_ctx|
        TakeoffTool.rescan_model_b
      end

      # ═══ SCENES ═══

      @dialog.add_action_callback('requestScenes') do |_ctx|
        begin
          m = Sketchup.active_model
          if m
            require 'json'
            pages = m.pages
            scenes = pages.map { |p| { name: p.name, description: p.description.to_s } }
            active_name = pages.selected_page ? pages.selected_page.name : ''
            data = { scenes: scenes, active: active_name }
            @dialog.execute_script("receiveScenes(#{JSON.generate(data)})")
          end
        rescue => e
          puts "Dashboard: requestScenes error: #{e.message}"
        end
      end

      @dialog.add_action_callback('activateScene') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s
          m = Sketchup.active_model
          if m
            page = m.pages[name]
            if page
              m.pages.selected_page = page
              puts "Dashboard: Activated scene '#{name}'"
            else
              puts "Dashboard: Scene '#{name}' not found"
            end
          end
        rescue => e
          puts "Dashboard: activateScene error: #{e.message}"
        end
      end

      # ═══ MODEL COMPARISON (Quantity Delta + Visual Diff) ═══

      @dialog.add_action_callback('runCompare') do |_ctx|
        begin
          if SmartDiff.active?
            puts "Dashboard: runCompare blocked — SmartDiff is active"
            next
          end
          # Part 1: synchronous quantity delta
          TakeoffTool.compute_quantity_delta
          send_comparison_results
          # Part 2: async visual diff (batched via UI.start_timer)
          TakeoffTool.compute_visual_diff
        rescue => e
          puts "Dashboard: runCompare error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          require 'json'
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          @dialog.execute_script("receiveComparisonResults('#{ejs}')")
        end
      end

      @dialog.add_action_callback('toggleDiff') do |_ctx|
        begin
          next if SmartDiff.active?
          is_on = TakeoffTool.toggle_diff
          @dialog.execute_script("setDiffToggle(#{is_on})")
        rescue => e
          puts "Dashboard: toggleDiff error: #{e.message}"
        end
      end

      @dialog.add_action_callback('showChangeReport') do |_ctx|
        begin
          TakeoffTool.show_change_report
        rescue => e
          puts "Dashboard: showChangeReport error: #{e.message}"
        end
      end

      @dialog.add_action_callback('clearCompareHighlights') do |_ctx|
        begin
          TakeoffTool.clear_compare_highlights
        rescue => e
          puts "Dashboard: clearCompare error: #{e.message}"
        end
        @dialog.execute_script("clearCompareUI()")
      end

      # ═══ SMART DIFF ═══

      @dialog.add_action_callback('computeSmartDiff') do |_ctx|
        begin
          SmartDiff.enter
          counts = SmartDiff.counts || {}
          require 'json'
          @dialog.execute_script("onSmartDiffComplete(#{JSON.generate(counts)})")
        rescue => e
          msg = "SmartDiff error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          puts msg
          esc = e.message.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", ' ')
          @dialog.execute_script("hideLoading();alert('Smart Diff Error: #{esc}')")
        end
      end

      @dialog.add_action_callback('setSmartDiffOpacity') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          state = data['state'].to_s
          value = data['value'].to_f
          SmartDiff.set_opacity(state, value)
        rescue => e
          puts "setSmartDiffOpacity error: #{e.message}"
        end
      end

      @dialog.add_action_callback('setSmartDiffVisibility') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          state = data['state'].to_s
          visible = data['visible'] == true
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.set_visibility(state, visible)
          SmartDiff.toggle_state_fast(state, visible, category_filter: cats)
        rescue => e
          puts "setSmartDiffVisibility error: #{e.message}"
        end
      end

      # ═══ SMART DIFF — CATEGORY FILTER ═══

      @dialog.add_action_callback('smartDiffFilterCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.repaint(category_filter: cats)
        rescue => e
          puts "smartDiffFilterCategory error: #{e.message}"
        end
      end

      @dialog.add_action_callback('smartDiffIsolateWithCat') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          state_str = data['state'].to_s
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.isolate_state(state_str, categories: cats)
          @dialog.execute_script("onSmartDiffVisUpdate(#{JSON.generate(SmartDiff.visibility_settings)})")
        rescue => e
          puts "smartDiffIsolateWithCat error: #{e.message}"
        end
      end

      @dialog.add_action_callback('smartDiffShowAllWithCat') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.show_all(categories: cats)
          @dialog.execute_script("onSmartDiffVisUpdate(#{JSON.generate(SmartDiff.visibility_settings)})")
        rescue => e
          puts "smartDiffShowAllWithCat error: #{e.message}"
        end
      end

      @dialog.add_action_callback('removeSmartDiff') do |_ctx|
        begin
          SmartDiff.exit
          @dialog.execute_script("onSmartDiffRemoved()")
        rescue => e
          puts "removeSmartDiff error: #{e.message}"
        end
      end

      @dialog.add_action_callback('acceptCompare') do |_ctx|
        begin
          result = TakeoffTool.accept_compare
          require 'json'
          js = JSON.generate(result)
          esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
          @dialog.execute_script("receiveAcceptResult('#{esc}')")
          # Switch JS UI to Model A view (accept_compare already set Ruby state)
          @dialog.execute_script("setMvViewUI('a')")
          # Refresh dashboard with Model A filtered data
          send_live_data
        rescue => e
          puts "Dashboard: acceptCompare error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          @dialog.execute_script("receiveAcceptResult('#{ejs}')")
        end
      end

      # ═══ OVERCOUNT FIX ═══

      @dialog.add_action_callback('fixOvercount') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          category = data['category']
          sr = TakeoffTool.scan_results
          reg = TakeoffTool.entity_registry
          next unless sr && reg && category

          removed = 0
          sr.reject! do |r|
            next false unless r[:parsed][:auto_category] == category
            entity = reg[r[:entity_id]]
            next false unless entity && entity.valid?
            mt = r[:parsed][:measurement_type] || Parser.measurement_for(category)
            next false unless mt && mt.start_with?('ea')
            # Check if this entity is nested inside a parent in the same category
            p = entity.parent
            if p.is_a?(Sketchup::ComponentDefinition)
              cat_eids = sr.select { |r2| r2[:parsed][:auto_category] == category }.map { |r2| r2[:entity_id] }
              is_child = p.instances.any? { |pinst| pinst.valid? && cat_eids.include?(pinst.entityID) }
              if is_child
                removed += 1
                true
              else
                false
              end
            else
              false
            end
          end

          puts "[FF] fixOvercount: removed #{removed} children from #{category}"
          send_live_data
        rescue => e
          puts "fixOvercount error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      # ═══ COMMIT TO MAIN ═══

      @dialog.add_action_callback('commitToMain') do |_ctx, cat_str|
        begin
          category = cat_str.to_s.strip
          next if category.empty?
          result = TakeoffTool.commit_to_main(category)
          require 'json'
          js = JSON.generate(result)
          esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
          @dialog.execute_script("receiveCommitResult('#{esc}')")
          @dialog.execute_script("setMvViewUI('a')")
          send_live_data
        rescue => e
          puts "Dashboard: commitToMain error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          @dialog.execute_script("receiveCommitResult('#{ejs}')")
        end
      end

      @dialog.add_action_callback('commitCompareEntities') do |_ctx|
        begin
          result = TakeoffTool.commit_compare_entities
          require 'json'
          js = JSON.generate(result)
          esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
          @dialog.execute_script("receiveCommitResult('#{esc}')")
          @dialog.execute_script("setMvViewUI('a')")
          send_live_data
        rescue => e
          puts "Dashboard: commitCompareEntities error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          @dialog.execute_script("receiveCommitResult('#{ejs}')")
        end
      end

      @dialog.add_action_callback('recallFromVault') do |_ctx|
        result = TakeoffTool.recall_from_vault
        require 'json'
        js = JSON.generate(result)
        esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
        @dialog.execute_script("receiveRecallResult('#{esc}')")
      end

      @dialog.add_action_callback('requestVaultSummary') do |_ctx|
        require 'json'
        data = TakeoffTool.vault_summary
        js = JSON.generate(data)
        esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
        @dialog.execute_script("receiveVaultSummary('#{esc}')")
      end

      @dialog.add_action_callback('highlightCompareGroup') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.highlight_entities(ids) if ids.any?
      end

      # Isolate specific entities by ID
      @dialog.add_action_callback('isolateEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        puts "Takeoff: isolateEntities #{ids.length} items"
        Highlighter.isolate_entities(TakeoffTool.filtered_scan_results, ids)
      end

      # NE review: approve entities — commits scanner category as a firm assignment
      @dialog.add_action_callback('neApprove') do |_ctx, json_str|
        begin
          require 'json'
          eids = JSON.parse(json_str.to_s).map(&:to_i)
          ca = TakeoffTool.category_assignments
          sr = TakeoffTool.scan_results
          count = 0
          eids.each do |eid|
            # Get the entity's current effective category
            cat = ca[eid]
            if cat.nil? || cat.empty? || cat == 'Uncategorized'
              r = sr.find { |r| r[:entity_id] == eid }
              cat = r[:parsed][:auto_category] if r
            end
            next unless cat && !cat.empty? && cat != 'Uncategorized'
            ca[eid] = cat
            TakeoffTool.save_assignment(eid, 'category', cat)
            count += 1
          end
          puts "Takeoff: neApprove committed #{count} entities"
          send_live_data if count > 0
        rescue => e
          puts "Takeoff: neApprove error: #{e.message}"
        end
      end

      # NE review isolation: only hides/shows entities in the new entities list,
      # leaves all other scan entities untouched (no casework bleed-through)
      @dialog.add_action_callback('neIsolate') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          show_ids = (data['show'] || []).map(&:to_i)
          hide_ids = (data['hide'] || []).map(&:to_i)
          show_set = show_ids.to_set
          hide_set = hide_ids.to_set
          m = Sketchup.active_model; next unless m
          m.start_operation('NE Isolate', true)
          visible = []
          hide_ids.each do |eid|
            e = TakeoffTool.find_entity(eid); next unless e && e.valid?
            e.visible = false
          end
          show_ids.each do |eid|
            e = TakeoffTool.find_entity(eid); next unless e && e.valid?
            e.visible = true
            visible << e
          end
          Highlighter.ensure_ancestors_visible(visible, m) if visible.any?
          m.commit_operation
          puts "Takeoff: neIsolate show=#{show_ids.length} hide=#{hide_ids.length}"
        rescue => e
          puts "Takeoff: neIsolate error: #{e.message}"
        end
      end

      # ═══ CUSTOM COLORS (via ColorController) ═══

      @dialog.add_action_callback('setCustomColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          type = data['type'].to_s
          key = data['key'].to_s
          color = data['color'].to_s
          opacity = data['opacity'] ? data['opacity'].to_f : nil
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements','container'=>'containers'}
          section = plural[type] || (type + 's')
          ColorController.set_color(section, key, color, opacity)
          # Also update legacy custom_colors for backward compat
          colors = load_custom_colors_for_view
          colors[section] ||= {}
          colors[section][key] = color
          save_custom_colors_for_view(colors)
          Highlighter.refresh_highlights
          send_live_data
        rescue => e
          puts "Takeoff setCustomColor error: #{e.message}"
        end
      end

      @dialog.add_action_callback('clearCustomColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          type = data['type'].to_s
          key = data['key'].to_s
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements','container'=>'containers'}
          section = plural[type] || (type + 's')
          ColorController.clear_color(section, key)
          # Also update legacy custom_colors for backward compat
          colors = load_custom_colors_for_view
          if colors[section]
            colors[section].delete(key)
          end
          save_custom_colors_for_view(colors)
          Highlighter.refresh_highlights
          send_live_data
        rescue => e
          puts "Takeoff clearCustomColor error: #{e.message}"
        end
      end

      @dialog.add_action_callback('setCustomOpacity') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          type = data['type'].to_s
          key = data['key'].to_s
          opacity = data['opacity'].to_f
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements','container'=>'containers'}
          section = plural[type] || (type + 's')
          ColorController.set_opacity(section, key, opacity)
        rescue => e
          puts "Takeoff setCustomOpacity error: #{e.message}"
        end
      end

      # ═══ ASSEMBLIES ═══

      @dialog.add_action_callback('loadAssemblies') do |_ctx|
        send_assemblies
      end

      @dialog.add_action_callback('createAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          ids = data['entityIds'] || []
          notes = data['notes'].to_s
          puts "Takeoff: createAssembly received #{ids.length} entity IDs from JS (first 5: #{ids.first(5).inspect})"
          next if name.empty? || ids.empty?
          TakeoffTool.create_assembly(name, ids, notes)
          puts "Takeoff: Created assembly '#{name}' with #{ids.length} entities"
          send_assemblies
        rescue => e
          puts "Takeoff createAssembly error: #{e.message}"
        end
      end

      # Create assembly from all entities currently VISIBLE in the viewport
      # This captures every isolation method (eye toggles, category isolate,
      # filter isolation, search) since they all set entity.visible = false
      @dialog.add_action_callback('createAssemblyFromVisible') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          notes = data['notes'].to_s
          next if name.empty?

          visible_ids = []
          (TakeoffTool.scan_results || []).each do |r|
            eid = r[:entity_id]
            e = TakeoffTool.find_entity(eid)
            next unless e && e.valid? && e.visible?
            visible_ids << eid
          end

          if visible_ids.empty?
            puts "Takeoff: createAssemblyFromVisible — no visible entities found"
            @dialog.execute_script("alert('No visible entities to save.')")
            next
          end

          TakeoffTool.create_assembly(name, visible_ids, notes)
          puts "Takeoff: Created assembly '#{name}' with #{visible_ids.length} visible entities (of #{(TakeoffTool.scan_results || []).length} total)"
          send_assemblies
        rescue => e
          puts "Takeoff createAssemblyFromVisible error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deleteAssembly') do |_ctx, name_str|
        begin
          name = name_str.to_s.strip
          TakeoffTool.delete_assembly(name)
          puts "Takeoff: Deleted assembly '#{name}'"
          send_assemblies
        rescue => e
          puts "Takeoff deleteAssembly error: #{e.message}"
        end
      end

      @dialog.add_action_callback('renameAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          old_name = data['oldName'].to_s.strip
          new_name = data['newName'].to_s.strip
          next if old_name.empty? || new_name.empty?
          TakeoffTool.rename_assembly(old_name, new_name)
          puts "Takeoff: Renamed assembly '#{old_name}' -> '#{new_name}'"
          send_assemblies
        rescue => e
          puts "Takeoff renameAssembly error: #{e.message}"
        end
      end

      @dialog.add_action_callback('updateAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          next if name.empty?
          ids = data['entityIds']
          notes = data.key?('notes') ? data['notes'].to_s : nil
          TakeoffTool.update_assembly(name, entity_ids: ids, notes: notes)
          puts "Takeoff: Updated assembly '#{name}'"
          send_assemblies
        rescue => e
          puts "Takeoff updateAssembly error: #{e.message}"
        end
      end

      @dialog.add_action_callback('createAssemblyFromSelection') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          notes = data['notes'].to_s
          sel = Sketchup.active_model&.selection
          next unless sel && !sel.empty? && !name.empty?
          ids = sel.to_a.select { |e| e.respond_to?(:entityID) }.map(&:entityID)
          next if ids.empty?
          TakeoffTool.create_assembly(name, ids, notes)
          puts "Takeoff: Created assembly '#{name}' from selection (#{ids.length} entities)"
          send_assemblies
        rescue => e
          puts "Takeoff createAssemblyFromSelection error: #{e.message}"
        end
      end

      # ── Scanner Mode Callbacks ──

      @dialog.add_action_callback('enterScannerMode') do |_ctx|
        groups = InteractiveScanner.current_groups
        if groups && groups.length > 0
          all_eids = groups.flat_map { |g| g[:entity_ids] }
          Highlighter.isolate_entities(TakeoffTool.filtered_scan_results, all_eids)
          send_scanner_groups
        end
      end

      @dialog.add_action_callback('exitScannerMode') do |_ctx|
        Highlighter.show_all
        Highlighter.clear_all
        send_live_data
      end

      @dialog.add_action_callback('regroupScanner') do |_ctx, mode_str|
        InteractiveScanner.regroup(mode_str.to_s)
        send_scanner_groups
      end

      @dialog.add_action_callback('highlightScannerGroup') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.highlight_entities(ids)
      end

      @dialog.add_action_callback('clearScannerHighlight') do |_ctx|
        Highlighter.clear_all
      end

      @dialog.add_action_callback('applyScannerGroup') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          idx = data['groupIdx'].to_i
          category = data['category'].to_s.strip
          subcategory = (data['subcategory'] || '').to_s.strip
          cost_code = (data['costCode'] || '').to_s.strip
          groups = InteractiveScanner.current_groups
          next if category.empty? || idx < 0 || idx >= groups.length

          group = groups[idx]
          InteractiveScanner.apply_to_group(group, category, subcategory, cost_code,
            InteractiveScanner.current_sr, InteractiveScanner.current_ca)
          group[:applied] = true
          (group[:sub_groups] || []).each { |sg| sg[:applied] = true }

          LearningSystem.capture(
            group[:entity_ids].first, 'Uncategorized', category,
            new_subcategory: subcategory.empty? ? nil : subcategory,
            new_cost_code: cost_code.empty? ? nil : cost_code
          )

          send_scanner_groups
          TakeoffTool.trigger_backup
        rescue => e
          puts "Scanner applyScannerGroup error: #{e.message}"
        end
      end

      @dialog.add_action_callback('skipScannerGroup') do |_ctx, idx_str|
        idx = idx_str.to_s.to_i
        groups = InteractiveScanner.current_groups
        if idx >= 0 && idx < groups.length
          groups[idx][:applied] = true
          groups[idx][:skipped] = true
          send_scanner_groups
        end
      end

      @dialog.add_action_callback('createScannerCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        unless name.empty?
          TakeoffTool.add_custom_category(name)
          send_scanner_groups
        end
      end

      @dialog.set_on_closed {
        @dialog = nil
        # Defer save so the dialog closes immediately — no freeze.
        # save_scan_to_model is already called after every major operation
        # (scan, import, accept, commit), so we skip it here.
        # Only the lightweight saves run as a safety net.
        if @data_dirty
          UI.start_timer(0.1, false) {
            begin
              puts "[FF Dashboard] Deferred save (dirty=true)..."
              TakeoffTool.save_master_categories rescue nil
              TakeoffTool.save_master_subcategories rescue nil
              TakeoffTool.save_multiverse_data rescue nil
              puts "[FF Dashboard] Deferred save complete."
            rescue => e
              puts "[FF Dashboard] Deferred save error: #{e.message}"
            end
            @data_dirty = false
          }
        else
          puts "[FF Dashboard] Dialog closed — no unsaved changes."
        end
      }

      @dialog.show
    end

    # ── Scanner Mode Send Methods ──

    def self.send_scanner_banner(summary)
      return unless @dialog
      require 'json'
      js = JSON.generate(summary)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("if(typeof receiveScannerBanner==='function')receiveScannerBanner('#{esc}')")
    end

    def self.send_new_entities_banner(count, by_cat)
      return unless @dialog && @dialog.visible?
      require 'json'
      cats = by_cat.sort_by { |_k, v| -v.length }.map { |cat, names| { name: cat, count: names.length } }
      # Also send the full entity list for the review panel
      new_ents = defined?(CategoryTemplates) ? CategoryTemplates.new_entities : []
      entities = new_ents.map do |ne|
        {
          eid: ne[:entity_id],
          name: ne[:display_name],
          defn: ne[:definition_name],
          tag: ne[:tag],
          ifc: ne[:ifc_type],
          scannerCat: ne[:scanner_category]
        }
      end
      payload = { count: count, categories: cats, entities: entities }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("if(typeof receiveNewEntitiesBanner==='function')receiveNewEntitiesBanner('#{esc}')")
    end

    def self.send_scanner_groups
      return unless @dialog
      require 'json'
      groups = InteractiveScanner.serialize_groups
      cats = TakeoffTool.master_categories
      msub = TakeoffTool.master_subcategories
      payload = { groups: groups, categories: cats, subcategories: msub }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("if(typeof receiveScannerGroups==='function')receiveScannerGroups('#{esc}')")
    end

    def self.send_assemblies
      return unless @dialog && @dialog.visible?
      require 'json'
      assemblies = TakeoffTool.load_assemblies

      # Build entity→category lookup from scan results
      mv_view = TakeoffTool.active_mv_view
      sr = (mv_view && mv_view != 'ab') ? TakeoffTool.filtered_scan_results : (TakeoffTool.scan_results || [])
      ca = TakeoffTool.category_assignments || {}

      # Multiverse: filter assemblies to only those with entities in current view
      if mv_view && mv_view != 'ab'
        view_eids = {}
        sr.each { |r| view_eids[r[:entity_id].to_i] = true }
        assemblies = assemblies.select do |_name, asm|
          (asm['entity_ids'] || []).any? { |eid| view_eids[eid.to_i] }
        end.to_h
        # Filter each assembly's entity_ids to current-view entities
        assemblies.each do |_name, asm|
          asm['entity_ids'] = (asm['entity_ids'] || []).select { |eid| view_eids[eid.to_i] }
        end
      end
      eid_cat = {}
      sr.each do |r|
        eid_cat[r[:entity_id].to_i] = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      end

      # Add category breakdown to each assembly
      assemblies.each do |_name, asm|
        eids = asm['entity_ids'] || []
        breakdown = {}
        eids.each do |eid|
          cat = eid_cat[eid.to_i] || 'Uncategorized'
          breakdown[cat] ||= 0
          breakdown[cat] += 1
        end
        total = eids.length.to_f
        asm['breakdown'] = breakdown.map { |cat, count|
          { 'category' => cat, 'count' => count, 'percent' => (total > 0 ? (count / total * 100).round(1) : 0) }
        }.sort_by { |b| -b['count'] }
      end

      js = JSON.generate(assemblies)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveAssemblies('#{esc}')")
    end

    def self.send_parts_data
      return unless @dialog && @dialog.visible?
      require 'json'
      parts = TakeoffTool.load_parts rescue {}
      return if parts.empty?
      js = JSON.generate(parts)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveParts('#{esc}')") rescue nil
    end

    def self.send_comparison_results
      return unless @dialog
      require 'json'
      data = TakeoffTool.serialize_comparison_results
      return unless data
      js = JSON.generate(data)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveComparisonResults('#{esc}')")
    end

    def self.send_diff_results
      return unless @dialog
      require 'json'
      diff = TakeoffTool.diff_data
      total = diff ? diff.length : 0
      payload = { 'totalEntities' => total, 'diffActive' => TakeoffTool.diff_active? }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveDiffResults('#{esc}')")
    end

    def self.scroll_to_entity(eid)
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("scrollToEntity(#{eid})")
    end

    def self.mark_dirty
      @data_dirty = true
    end

    def self.portal_complete(text)
      return unless @dialog
      esc = text.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("updatePortalProgress(100,'#{esc}');setTimeout(function(){hidePortal()},800)")
    end

    def self.update_portal_progress(pct, text)
      return unless @dialog
      esc = text.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("updatePortalProgress(#{pct},'#{esc}')")
    end

    def self.portal_error(text)
      return unless @dialog
      esc = text.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("hidePortal();showPortalError('Error','#{esc}')")
    end



    # Helper: always sends data using live module state (no stale closures)
    # Check if a definition contains scan entities that are NOT being hidden.
    # Prevents hiding a parent from cascading to visible children in SketchUp.
    def self._has_visible_scan_child?(defn, scan_eid_set, hide_set, visited = Set.new)
      return false if visited.include?(defn.object_id)
      visited.add(defn.object_id)
      defn.entities.each do |e|
        next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        eid = e.entityID
        return true if scan_eid_set.include?(eid) && !hide_set.include?(eid)
        if e.respond_to?(:definition)
          return true if _has_visible_scan_child?(e.definition, scan_eid_set, hide_set, visited)
        end
      end
      false
    end

    def self.send_live_data
      @data_dirty = true
      send_data(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
    end

    def self.send_data(sr, ca, cca)
      return unless @dialog
      begin
      # Multiverse: filter to active model's entities
      mv_view = TakeoffTool.active_mv_view
      if mv_view && mv_view != 'ab'
        sr = TakeoffTool.filtered_scan_results
      end
      custom_colors = load_custom_colors_for_view
      cc = []; ccm = {}
      begin
        p = File.join(PLUGIN_DIR, 'config', 'cost_codes.json')
        if File.exist?(p)
          require 'json'
          d = JSON.parse(File.read(p))
          cc = d['codes'] || []
          ccm = d['category_to_cost_code'] || {}
        end
      rescue => e
        puts "CC load err: #{e.message}"
      end

      # Parts are now SketchUp Groups — scanner already skips children and injects part rows.
      # Between scans, also inject from registry so parts appear immediately after creation.
      all_parts = TakeoffTool.load_parts rescue {}
      part_grp_ids = {}
      all_parts.each { |_n, pd| part_grp_ids[(pd['group_id'] || 0).to_i] = true }

      # Check if scan results already include parts (post-scan) or need injection (pre-scan)
      sr_has_parts = sr.any? { |r| r[:entity_type] == 'Part' }

      rows = sr.map do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        sc = ccm[cat] || []
        assigned = cca[r[:entity_id]]
        # Only show as overlap if multiple codes AND user hasn't picked one yet
        has_assigned = assigned && !assigned.empty?

        # Check for parser-assigned cost code from cost_code_map
        parser_cc = r[:parsed][:cost_code]
        auto_cc = if has_assigned
          assigned
        elsif parser_cc && !parser_cc.to_s.empty?
          parser_cc
        elsif sc.length == 1
          sc[0]
        else
          ''
        end
        has_overlap = sc.length > 1 && !has_assigned && !parser_cc

        mt_default = Parser.measurement_for(cat)
        # Default to EA until user explicitly sets a measurement type
        m_override = Sketchup.active_model.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
        mt = (m_override && !m_override.empty?) ? m_override : 'ea'

        # Confidence flag for interactive scanner
        conf_pct = InteractiveScanner.confidence_pct(r) rescue 100
        flagged = conf_pct >= InteractiveScanner::MEDIUM_CONFIDENCE && conf_pct < InteractiveScanner::HIGH_CONFIDENCE

        {
          entityId: r[:entity_id], tag: r[:tag], defaultMT: mt_default,
          definitionName: r[:display_name] || r[:definition_name],
          rawDefName: r[:definition_name],
          elementType: r[:parsed][:element_type], function: r[:parsed][:function],
          material: r[:parsed][:material] || r[:material], thickness: r[:parsed][:thickness],
          sizeNominal: r[:parsed][:size_nominal], isSolid: r[:is_solid],
          volumeFt3: r[:volume_ft3], volumeBF: r[:volume_bf], areaSF: r[:area_sf],
          linearFt: r[:linear_ft],
          bbWidth: r[:bb_width_in], bbHeight: r[:bb_height_in], bbDepth: r[:bb_depth_in],
          category: cat, measurementType: mt, costCode: auto_cc,
          subcategory: (TakeoffTool.find_entity(r[:entity_id])&.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || '',
          suggestedCodes: sc, hasOverlap: has_overlap,
          warnings: r[:warnings] || [],
          revitId: r[:parsed][:revit_id], ifcType: r[:ifc_type],
          flagged: flagged, confidencePct: conf_pct,
          categorySource: r[:parsed][:category_source],
          customColor: custom_colors.dig('entities', r[:entity_id].to_s) ||
                        custom_colors.dig('subcategories', "#{cat}|#{(TakeoffTool.find_entity(r[:entity_id])&.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || ''}") ||
                        custom_colors.dig('categories', cat),
          modelSource: (TakeoffTool.find_entity(r[:entity_id])&.get_attribute('FormAndField', 'model_source') rescue nil) || 'model_a',
          visible: (TakeoffTool.find_entity(r[:entity_id])&.visible? rescue true),
          cosmetic: (TakeoffTool.find_entity(r[:entity_id])&.get_attribute('FormAndField', 'cosmetic') rescue nil) == true,
          isPart: r[:entity_type] == 'Part',
          partChildCount: r[:part_child_count] || 0
        }
      end

      # Inject part rows if scan results don't already include them (e.g. before rescan)
      unless sr_has_parts
        all_parts.each do |part_name, pdata|
          pcat = pdata['category'] || 'Uncategorized'
          psub = pdata['subcategory'] || ''
          pcc = ccm[pcat] || []
          auto_cc = pcc.length == 1 ? pcc[0] : ''
          grp_eid = pdata['group_id']
          grp = grp_eid ? TakeoffTool.find_entity(grp_eid.to_i) : nil
          grp_vis = grp && grp.valid? ? grp.visible? : true
          rows << {
            entityId: grp_eid || "part_#{part_name}", tag: '', defaultMT: 'ea',
            definitionName: part_name, rawDefName: part_name,
            elementType: nil, function: nil, material: nil, thickness: nil,
            sizeNominal: nil, isSolid: false,
            volumeFt3: 0.0, volumeBF: 0.0, areaSF: nil, linearFt: nil,
            bbWidth: 0.0, bbHeight: 0.0, bbDepth: 0.0,
            category: pcat, measurementType: 'ea', costCode: auto_cc,
            subcategory: psub, suggestedCodes: pcc, hasOverlap: false,
            warnings: [], revitId: nil, ifcType: nil,
            flagged: false, confidencePct: 100,
            categorySource: 'part', customColor: nil,
            modelSource: 'model_a', visible: grp_vis, cosmetic: false,
            isPart: true, partChildCount: pdata['child_count'] || 0
          }
        end
      end
      puts "[FF send_data] #{all_parts.length} part(s)" if all_parts.any?

      cats = (mv_view && mv_view != 'ab') ? TakeoffTool.filtered_master_categories : TakeoffTool.master_categories
      all_cats = TakeoffTool.master_categories  # Full list for assignment dropdowns

      # Build per-category measurement type map from ALL categories
      cat_mt = {}
      all_cats.each do |c|
        next if c == '_IGNORE'
        def_mt = Parser.measurement_for(c)
        ovr = Sketchup.active_model.get_attribute('TakeoffMeasurementTypes', c) rescue nil
        cur_mt = (ovr && !ovr.empty?) ? ovr : 'ea'
        cat_mt[c] = { 'mt' => cur_mt, 'defaultMT' => def_mt }
        sn_json = Sketchup.active_model.get_attribute('TakeoffSFNormals', c) rescue nil
        if sn_json
          sn = (JSON.parse(sn_json) rescue nil)
          cat_mt[c]['sampledNormal'] = sn if sn.is_a?(Array) && sn.length == 3
        end
      end

      require 'json'
      msub = (mv_view && mv_view != 'ab') ? TakeoffTool.filtered_master_subcategories : TakeoffTool.master_subcategories
      all_msub = TakeoffTool.master_subcategories  # Full for assignment dropdowns
      containers = TakeoffTool.master_containers || []
      cont_names = containers.map { |c| c['name'] rescue '?' }
      puts "[FF send_data] #{rows.length} rows, #{containers.length} containers: #{cont_names.join(', ')}"
      color_settings = ColorController.get_settings rescue {}
      oc_warnings = Scanner.overcount_warnings rescue []
      js = JSON.generate({ rows: rows, categories: cats, allCategories: all_cats, costCodes: cc, catCostCodeMap: ccm, masterSubcategories: msub, allMasterSubcategories: all_msub, categoryMT: cat_mt, customColors: custom_colors, colorSettings: color_settings, containers: containers, overcountWarnings: oc_warnings })
      # Double-escape backslashes, escape single quotes for JS string
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveData('#{esc}')")

      send_measurement_data
      send_assemblies
      send_parts_data
      send_multiverse_data
      send_cad_sheets

      rescue => e
        puts "[FF Dashboard] send_data error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end
    end

    def self.send_measurement_data
      return unless @dialog && @dialog.visible?
      require 'json'
      m = Sketchup.active_model
      return unless m

      measurements = []
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype

        cat = grp.get_attribute('TakeoffMeasurement', 'category') || 'Custom'
        visible = grp.get_attribute('TakeoffMeasurement', 'highlights_visible')
        visible = false if visible.nil?
        note = grp.get_attribute('TakeoffMeasurement', 'note') || ''
        rgba_json = grp.get_attribute('TakeoffMeasurement', 'color_rgba')
        color = begin; JSON.parse(rgba_json); rescue; nil; end

        part_name = grp.get_attribute('TakeoffMeasurement', 'part_name') || ''

        entry = {
          eid: grp.entityID,
          type: mtype,
          category: cat,
          visible: visible,
          note: note,
          color: color,
          partName: part_name
        }

        if mtype == 'SF'
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
          entry[:unit] = 'SF'
          entry[:faceCount] = grp.get_attribute('TakeoffMeasurement', 'face_count') || 0
        elsif mtype == 'ELEV'
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'elevation') || 0
          entry[:unit] = grp.get_attribute('TakeoffMeasurement', 'benchmark_unit') || 'feet'
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'elevation_label') || ''
          entry[:custom_label] = grp.get_attribute('TakeoffMeasurement', 'custom_label') || ''
        elsif mtype == 'NOTE'
          entry[:value] = 0
          entry[:unit] = ''
          entry[:label_type] = grp.get_attribute('TakeoffMeasurement', 'label_type') || ''
          entry[:author] = grp.get_attribute('TakeoffMeasurement', 'author') || ''
          entry[:created] = grp.get_attribute('TakeoffMeasurement', 'timestamp') || ''
          entry[:point] = grp.get_attribute('TakeoffMeasurement', 'point') || ''
        elsif mtype == 'BOX'
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'volume_cf') || 0
          entry[:unit] = 'CF'
          entry[:width_in] = grp.get_attribute('TakeoffMeasurement', 'width_in') || 0
          entry[:depth_in] = grp.get_attribute('TakeoffMeasurement', 'depth_in') || 0
          entry[:height_in] = grp.get_attribute('TakeoffMeasurement', 'height_in') || 0
          entry[:total_sf] = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
          entry[:net_wall_sf] = grp.get_attribute('TakeoffMeasurement', 'net_wall_sf') || 0
        elsif mtype == 'BENCHMARK'
          next  # Don't show benchmark point in measurement panel
        else
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0
          entry[:unit] = 'LF'
          entry[:segments] = grp.get_attribute('TakeoffMeasurement', 'segment_count') || 1
        end

        measurements << entry
      end

      # Compute per-category scan totals (excludes manual measurements)
      scan_totals = {}
      sr = TakeoffTool.filtered_scan_results || []
      ca = TakeoffTool.category_assignments || {}
      reg = TakeoffTool.instance_variable_get(:@entity_registry) || {}
      mv_active = TakeoffTool.active_mv_view != nil
      st_seen = {}
      st_defns = mv_active ? {} : nil
      # IFC dedup: the IFC importer often creates 2+ instances per element
      # (compound structure layers sharing the same definition/GlobalId).
      # Two-pass: first identify the preferred instance per definition
      # (the one with an explicit category assignment), then count only that one.
      is_ifc = (IFCParser.ifc_model?(m) rescue false)
      ifc_preferred = nil
      if is_ifc
        ifc_preferred = {}
        sr.each do |r|
          next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
          dname = r[:definition_name] || r[:display_name] || ''
          next if dname.empty?
          eid = r[:entity_id]
          has_ca = !!ca[eid]
          if !has_ca
            e = reg[eid]
            has_ca = !!(e && e.valid? && (e.get_attribute('TakeoffAssignments', 'category') rescue nil))
          end
          prev = ifc_preferred[dname]
          if prev.nil? || (has_ca && !prev[:assigned])
            ifc_preferred[dname] = { eid: eid, assigned: has_ca }
          end
        end
      end
      net_sec_cache = {}   # cache beam_net_section by definition name
      sr.each do |r|
        next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
        eid = r[:entity_id]
        next if st_seen[eid]
        st_seen[eid] = true
        assigned = ca[eid]
        if assigned.nil?
          e = reg[eid]
          assigned = (e && e.valid?) ? (e.get_attribute('TakeoffAssignments', 'category') rescue nil) : nil
        end
        cat = assigned || (r[:parsed][:auto_category] rescue nil) || 'Uncategorized'
        # Multiverse dedup only when A/B is active
        if st_defns
          e ||= reg[eid]
          defn_name = (e && e.valid? && e.respond_to?(:definition)) ? e.definition.name : (r[:definition_name] || r[:display_name])
          sf_val = (r[:area_sf] || 0).to_f
          dedup_key = "#{cat}|#{defn_name}|#{sf_val.round(2)}"
          next if st_defns[dedup_key]
          st_defns[dedup_key] = true
        end
        # IFC compound layer dedup: only count the preferred instance per definition
        if ifc_preferred
          dname = r[:definition_name] || r[:display_name] || ''
          pref = ifc_preferred[dname]
          next if pref && pref[:eid] != eid
        end
        scan_totals[cat] ||= { lf: 0.0, sf: 0.0, vol: 0.0, count: 0 }
        scan_totals[cat][:count] += 1
        scan_totals[cat][:lf]  += (r[:linear_ft] || 0).to_f
        scan_totals[cat][:sf]  += (r[:area_sf] || 0).to_f
        scan_totals[cat][:vol] += (r[:volume_ft3] || 0).to_f

        # Collect beam inventory data for any category with LF values
        if (r[:linear_ft] || 0) > 0
          scan_totals[cat][:beam_items] ||= []

          # Cross-section: oriented BB for beam categories, definition bounds otherwise
          sec_str = nil
          ent_for_beam = reg[r[:entity_id]]
          if ent_for_beam && ent_for_beam.valid? && ent_for_beam.respond_to?(:definition)
            bdefn = ent_for_beam.definition
            dname = bdefn.name
            if cat =~ Scanner::BEAM_RE
              # Full oriented bounding box for beam categories
              unless net_sec_cache.key?(dname)
                begin
                  net_sec_cache[dname] = Scanner.beam_net_section(bdefn)
                rescue => ex
                  puts "[FF beam_net_section ERROR] #{dname}: #{ex.message}"
                  net_sec_cache[dname] = nil
                end
              end
              ns = net_sec_cache[dname]
              sec_str = "#{ns[0].round(1)}x#{ns[1].round(1)}" if ns
            end
            # Fallback: definition bounds (local space, no angle distortion)
            unless sec_str
              dbb = bdefn.bounds
              ddims = [dbb.width, dbb.height, dbb.depth].sort
              sec_str = "#{ddims[0].round(1)}x#{ddims[1].round(1)}"
            end
          end
          # Last resort: scan result BB (world-space)
          unless sec_str
            dims = [r[:bb_width_in] || 0, r[:bb_height_in] || 0, r[:bb_depth_in] || 0].sort
            sec_str = "#{dims[0].round(1)}x#{dims[1].round(1)}"
          end

          scan_totals[cat][:beam_items] << {
            defn: r[:display_name] || r[:definition_name] || 'Unknown',
            lf: (r[:linear_ft] || 0).to_f,
            section: sec_str,
            eid: r[:entity_id]
          }
        end
      end

      # Load derived parts (deduplicate category_scan entries)
      derived = begin
        dp_json = m.get_attribute('FormAndField', 'derived_parts')
        dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
      rescue; {} end
      seen_scans = {}
      dups = []
      derived.each do |k, v|
        next unless v['sourceType'] == 'category_scan'
        key = "#{v['category']}|#{v['unit']}"
        if seen_scans[key]
          dups << k
        else
          seen_scans[key] = k
        end
      end
      if dups.any?
        dups.each { |k| derived.delete(k) }
        m.set_attribute('FormAndField', 'derived_parts', JSON.generate(derived))
        puts "[FF] Cleaned #{dups.length} duplicate category_scan entries"
      end

      # Recompute all derived part values from current scan data + assignments
      dirty = false
      derived.each do |_k, v|
        src = v['sourceType']
        dunit = v['unit'] || 'SF'
        mult = (v['multiplier'] || 1.0).to_f

        if src == 'category_scan'
          # Auto-scan measurement: value = scan_totals for its category
          dcat = v['category']
          st = scan_totals[dcat]
          new_val = if st
                      case dunit
                      when 'LF' then st[:lf]
                      when 'CF' then st[:vol]
                      else st[:sf]
                      end
                    else
                      0.0
                    end
          new_val = new_val.round(2)
          new_count = st ? st[:count] : 0
          if v['computedValue'] != new_val || v['entityCount'] != new_count
            v['computedValue'] = new_val
            v['entityCount'] = new_count
            v['note'] = "Scanned from #{new_count} entities"
            dirty = true
          end

          # Build beam inventory for LF beam categories
          if dunit == 'LF' && st && st[:beam_items]
            inv = {}
            st[:beam_items].each do |bi|
              # Key by section so beams with same display name but different
              # cross-sections are separate groups (e.g. 2.0x13.5 vs 9.5x13.5)
              inv_key = "#{bi[:defn]}|#{bi[:section]}"
              inv[inv_key] ||= { defn: bi[:defn], section: bi[:section], items: [] }
              inv[inv_key][:items] << { lf: bi[:lf].round(2), eid: bi[:eid] }
            end
            beam_inv = []
            inv.sort_by { |_dn, d| -d[:items].sum { |i| i[:lf] } }.each do |dn, d|
              all_eids = d[:items].map { |i| i[:eid] }
              # Group lengths (round to nearest 3" = 0.25')
              len_groups = {}
              d[:items].each do |item|
                key = ((item[:lf] * 4).round / 4.0)
                len_groups[key] ||= { qty: 0, eids: [] }
                len_groups[key][:qty] += 1
                len_groups[key][:eids] << item[:eid]
              end
              rows = len_groups.sort_by { |l, _g| -l }.map do |len, g|
                { 'l' => len, 'qty' => g[:qty], 'total' => (len * g[:qty]).round(1), 'eids' => g[:eids] }
              end
              beam_inv << {
                'defn' => d[:defn],
                'section' => d[:section],
                'count' => d[:items].length,
                'totalLF' => d[:items].sum { |i| i[:lf] }.round(1),
                'eids' => all_eids,
                'rows' => rows
              }
            end
            v['beamInventory'] = beam_inv if beam_inv.any?
          else
            v.delete('beamInventory')
          end

        elsif src == 'category_total'
          # Derived from a category's scan total × multiplier
          src_cat = v['sourceCategory'] || v['category']
          src_unit = v['sourceUnit'] || dunit
          st = scan_totals[src_cat]
          base = if st
                   case src_unit
                   when 'LF' then st[:lf]
                   when 'CF' then st[:vol]
                   else st[:sf]
                   end
                 else
                   0.0
                 end
          new_val = (base * mult).round(2)
          if v['computedValue'] != new_val
            v['computedValue'] = new_val
            dirty = true
          end

        elsif src == 'manual'
          # Manual fixed value × multiplier
          base = (v['manualValue'] || 0).to_f
          new_val = (base * mult).round(2)
          if v['computedValue'] != new_val
            v['computedValue'] = new_val
            dirty = true
          end
        end
      end
      # Strip transient beamInventory before persisting (it's computed, not stored)
      if dirty
        save_derived = {}
        derived.each { |k, v| save_derived[k] = v.reject { |fk, _| fk == 'beamInventory' } }
        m.set_attribute('FormAndField', 'derived_parts', JSON.generate(save_derived))
      end

      # Log what we're sending
      puts "[FF send_meas] #{measurements.length} manual, #{derived.length} derived parts"
      derived.each do |k, v|
        bi = v['beamInventory']
        bi_info = bi ? " [beamInventory: #{bi.length} types]" : ""
        puts "  [#{k}] #{v['name']} = #{v['computedValue']} #{v['unit']} (#{v['sourceType']}, cat=#{v['category']})#{bi_info}"
      end

      # Strip :beam_items from scan_totals before serializing (used internally only)
      clean_totals = {}
      scan_totals.each { |k, v| clean_totals[k] = v.reject { |fk, _| fk == :beam_items } }

      # Payload includes beamInventory (transient, for display only)
      payload = { measurements: measurements, scanTotals: clean_totals, derivedParts: derived }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveMeasurements('#{esc}')")
      send_benchmark_data
      send_section_cuts
    end

    def self.send_cad_sheets
      return unless @dialog && @dialog.visible?
      require 'json'
      sheets = CadOverlay.list_sheets
      js = JSON.generate(sheets)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveCadSheets('#{esc}')")
    end

    def self.send_multiverse_data
      return unless @dialog && @dialog.visible?
      require 'json'
      mv = TakeoffTool.multiverse_data
      if mv && mv['models'] && mv['models'].length > 1
        summary = TakeoffTool.build_comparison_summary
        payload = {
          models: mv['models'],
          activeView: mv['active_view'] || 'a',
          comparison: summary,
          needsScan: !!mv['needs_scan']
        }
      else
        payload = { models: [], activeView: 'a', comparison: [], needsScan: false }
      end
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveMultiverseData('#{esc}')")
    end

    def self.send_benchmark_data
      return unless @dialog && @dialog.visible?
      require 'json'
      bmk = TakeoffTool.get_elevation_benchmark
      js = bmk ? JSON.generate(bmk) : 'null'
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveBenchmark('#{esc}')")
    end

    def self.send_section_cuts
      return unless @dialog && @dialog.visible?
      begin
        require 'json'
        payload = SectionCuts.build_payload
        js = JSON.generate(payload)
        esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
        @dialog.execute_script("receiveSectionCuts('#{esc}')")
      rescue => e
        puts "Dashboard: send_section_cuts error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end
    end

    def self.visible?
      @dialog && @dialog.visible?
    end

    def self.scan_log_start
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("scanStart()")
    end

    def self.scan_log_msg(msg)
      return unless @dialog && @dialog.visible?
      esc = msg.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("scanMsg('#{esc}')")
    end

    def self.scan_log_count(n)
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("scanCount(#{n.to_i})")
    end

    def self.scan_log_status(text)
      return unless @dialog && @dialog.visible?
      esc = text.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("scanStatus('#{esc}')")
    end

    def self.scan_log_pill(name)
      return unless @dialog && @dialog.visible?
      esc = name.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("addLoadingPill('#{esc}')")
    end

    def self.scan_log_end(summary)
      return unless @dialog && @dialog.visible?
      esc = summary.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("scanEnd('#{esc}')")
    end

    def self.close
      # Turn off color-by-layer when dashboard closes
      m = Sketchup.active_model
      m.rendering_options['DisplayColorByLayer'] = false if m rescue nil
      @dialog.close if @dialog
      @dialog = nil
    end
  end
end
