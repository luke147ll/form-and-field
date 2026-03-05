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
          # Learning system: capture reclassification
          begin; LearningSystem.capture(eid, old_cat, cat); rescue => le; puts "Learning capture error: #{le.message}"; end
          send_live_data
          TakeoffTool.trigger_backup
        rescue => e
          puts "Takeoff setCategory error: #{e.message}"
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
        ids_str.to_s.split(',').each do |id|
          e = TakeoffTool.find_entity(id.to_i)
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

      @dialog.add_action_callback('rescan') do |_ctx|
        TakeoffTool.run_scan
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
          eids.each do |eid|
            eid_i = eid.to_i
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

      # ═══ CATEGORY COMPARE ═══

      @dialog.add_action_callback('compareCategories') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat_a = data['catA'].to_s.strip
          cat_b = data['catB'].to_s.strip
          next if cat_a.empty? || cat_b.empty?
          TakeoffTool.compare_categories(cat_a, cat_b)
          TakeoffTool.apply_compare_highlights
          send_compare_results
        rescue => e
          puts "Dashboard: compareCategories error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          @dialog.execute_script("receiveCompareResults('#{ejs}')")
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

      # ═══ CUSTOM COLORS ═══

      @dialog.add_action_callback('setCustomColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          type = data['type'].to_s
          key = data['key'].to_s
          color = data['color'].to_s
          colors = load_custom_colors_for_view
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements'}
          section = plural[type] || (type + 's')
          colors[section] ||= {}
          colors[section][key] = color
          save_custom_colors_for_view(colors)
          Highlighter.clear_cached_material(key) if type == 'category'
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
          colors = load_custom_colors_for_view
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements'}
          section = plural[type] || (type + 's')
          if colors[section]
            colors[section].delete(key)
          end
          save_custom_colors_for_view(colors)
          Highlighter.clear_cached_material(key) if type == 'category'
          Highlighter.refresh_highlights
          send_live_data
        rescue => e
          puts "Takeoff clearCustomColor error: #{e.message}"
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

    def self.send_compare_results
      return unless @dialog
      require 'json'
      data = TakeoffTool.serialize_compare_results
      return unless data
      js = JSON.generate(data)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveCompareResults('#{esc}')")
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
        mt = mt_default
        # Check for user override stored in model attributes
        m_override = Sketchup.active_model.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
        mt = m_override if m_override && !m_override.empty?

        # Confidence flag for interactive scanner
        conf_pct = InteractiveScanner.confidence_pct(r) rescue 100
        flagged = conf_pct >= InteractiveScanner::MEDIUM_CONFIDENCE && conf_pct < InteractiveScanner::HIGH_CONFIDENCE

        {
          entityId: r[:entity_id], tag: r[:tag], defaultMT: mt_default,
          definitionName: r[:display_name] || r[:definition_name],
          elementType: r[:parsed][:element_type], function: r[:parsed][:function],
          material: r[:parsed][:material] || r[:material], thickness: r[:parsed][:thickness],
          sizeNominal: r[:parsed][:size_nominal], isSolid: r[:is_solid],
          instanceCount: r[:instance_count],
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
          visible: (TakeoffTool.find_entity(r[:entity_id])&.visible? rescue true)
        }
      end

      cats = (mv_view && mv_view != 'ab') ? TakeoffTool.filtered_master_categories : TakeoffTool.master_categories

      # Build per-category measurement type map (for empty categories)
      cat_mt = {}
      cats.each do |c|
        next if c == '_IGNORE'
        def_mt = Parser.measurement_for(c)
        ovr = Sketchup.active_model.get_attribute('TakeoffMeasurementTypes', c) rescue nil
        cur_mt = (ovr && !ovr.empty?) ? ovr : def_mt
        cat_mt[c] = { 'mt' => cur_mt, 'defaultMT' => def_mt }
      end

      require 'json'
      msub = (mv_view && mv_view != 'ab') ? TakeoffTool.filtered_master_subcategories : TakeoffTool.master_subcategories
      containers = TakeoffTool.master_containers || []
      cont_names = containers.map { |c| c['name'] rescue '?' }
      puts "[FF send_data] #{rows.length} rows, #{containers.length} containers: #{cont_names.join(', ')}"
      js = JSON.generate({ rows: rows, categories: cats, costCodes: cc, masterSubcategories: msub, categoryMT: cat_mt, customColors: custom_colors, containers: containers })
      # Double-escape backslashes, escape single quotes for JS string
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveData('#{esc}')")

      send_measurement_data
      send_assemblies
      send_multiverse_data

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

        entry = {
          eid: grp.entityID,
          type: mtype,
          category: cat,
          visible: visible,
          note: note,
          color: color
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
        elsif mtype == 'BENCHMARK'
          next  # Don't show benchmark point in measurement panel
        else
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0
          entry[:unit] = 'LF'
          entry[:segments] = grp.get_attribute('TakeoffMeasurement', 'segment_count') || 1
        end

        measurements << entry
      end

      js = JSON.generate(measurements)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveMeasurements('#{esc}')")
      send_benchmark_data
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
