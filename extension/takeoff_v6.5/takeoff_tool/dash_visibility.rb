module TakeoffTool
  class DashVisibility
    def self.register_callbacks(dialog)

      dialog.add_action_callback('highlightAll') do |_ctx|
        Highlighter.highlight_all(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments)
        dialog.execute_script("if(typeof clearAllDotStates==='function')clearAllDotStates();")
      end

      dialog.add_action_callback('highlightCategory') do |_ctx, cat_str|
        Highlighter.clear_all
        Highlighter.highlight_category(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
        dialog.execute_script("if(typeof clearAllDotStates==='function')clearAllDotStates();")
      end

      dialog.add_action_callback('highlightSingle') do |_ctx, eid_str|
        Highlighter.highlight_single(eid_str.to_s)
      end

      dialog.add_action_callback('highlightEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.highlight_entities(ids)
      end

      dialog.add_action_callback('highlightCategoryColor') do |_ctx, cat_str|
        Highlighter.highlight_category_color(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      dialog.add_action_callback('clearCategoryColor') do |_ctx, cat_str|
        Highlighter.clear_category_color(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      dialog.add_action_callback('clearHighlights') do |_ctx|
        Highlighter.clear_all
        dialog.execute_script("if(typeof clearAllDotStates==='function')clearAllDotStates();")
      end

      dialog.add_action_callback('isolateCategory') do |_ctx, cat_str|
        cat = cat_str.to_s
        puts "Dashboard: isolateCategory cat='#{cat}' fsr=#{TakeoffTool.filtered_scan_results.length} ca_keys=#{TakeoffTool.category_assignments.keys.length} mv_view=#{TakeoffTool.active_mv_view}"
        VisibilityManager.isolate_by_category(cat, source: "scan")
      end

      dialog.add_action_callback('isolateTag') do |_ctx, tag_str|
        fsr = TakeoffTool.filtered_scan_results
        ids = fsr.select { |r| r[:tag] == tag_str.to_s }.map { |r| r[:entity_id] }
        VisibilityManager.isolate(ids, source: "scan")
      end

      dialog.add_action_callback('hideCategory') do |_ctx, cat_str|
        fsr = TakeoffTool.filtered_scan_results
        ca = TakeoffTool.category_assignments
        ids = fsr.select { |r| (ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized') == cat_str.to_s }.map { |r| r[:entity_id] }
        VisibilityManager.hide(ids)
      end

      dialog.add_action_callback('showCategory') do |_ctx, cat_str|
        fsr = TakeoffTool.filtered_scan_results
        ca = TakeoffTool.category_assignments
        ids = fsr.select { |r| (ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized') == cat_str.to_s }.map { |r| r[:entity_id] }
        VisibilityManager.show(ids)
      end

      dialog.add_action_callback('showAll') do |_ctx|
        VisibilityManager.show_all
      end

      dialog.add_action_callback('isolateCategoryForModel') do |_ctx, json_str|
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
            # Skip CAD and gridline layers — they manage their own visibility
            next if ln.start_with?('FF_CAD_')
            next if ln == 'FF_Gridlines'
            next if ln == 'FF_Elevation_Tags'
            l = m.layers[ln]
            l.visible = true if l && !l.visible?
          end
          m.commit_operation
        rescue => e
          puts "Dashboard: isolateCategoryForModel error: #{e.message}"
        end
      end

      dialog.add_action_callback('showAllForModel') do |_ctx, model_id_str|
        begin
          m = Sketchup.active_model
          next unless m
          prefix = model_id_str.to_s.start_with?('model_b') ? 'model_b' : 'model_a'

          m.start_operation('Show All Model', true)
          visible = []
          TakeoffTool.filtered_scan_results.each do |r|
            e = TakeoffTool.find_entity(r[:entity_id])
            next unless e && e.valid?
            # Skip CAD overlays and gridlines — they manage their own visibility
            next if e.is_a?(Sketchup::Group) && (e.get_attribute('FF_CadOverlay', 'sheet_name') rescue false)
            next if e.is_a?(Sketchup::Group) && (e.get_attribute('TakeoffGridline', 'label') rescue false)
            next if e.is_a?(Sketchup::Group) && (e.get_attribute('TakeoffMeasurement', 'type') rescue nil) == 'GRID'
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

      dialog.add_action_callback('hideEntities') do |_ctx, ids_str|
        eids_to_hide = ids_str.to_s.split(',').map(&:to_i)
        VisibilityManager.hide(eids_to_hide)
      end

      dialog.add_action_callback('showEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        VisibilityManager.show(ids)
      end

      dialog.add_action_callback('isolatePartGroup') do |_ctx, eid_str|
        begin
          eid = eid_str.to_s.to_i
          e = TakeoffTool.find_entity(eid)
          next unless e && e.valid?
          VisibilityManager.isolate([eid], source: "assembly")
          Sketchup.active_model&.active_view&.zoom(e)
          puts "[FF Parts] Isolated part group eid=#{eid}"
        rescue => ex
          puts "[FF Parts] isolatePartGroup error: #{ex.message}"
        end
      end

      dialog.add_action_callback('highlightCategoryScan') do |_ctx, json_str|
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

      dialog.add_action_callback('highlightBeamEntities') do |_ctx, json_str|
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

      dialog.add_action_callback('highlightCompareGroup') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.highlight_entities(ids) if ids.any?
      end

      # Isolate specific entities by ID
      dialog.add_action_callback('isolateEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        puts "Takeoff: isolateEntities #{ids.length} items"
        VisibilityManager.isolate(ids, source: "scan")
      end

      # NE review isolation: only hides/shows entities in the new entities list,
      # leaves all other scan entities untouched (no casework bleed-through)
      dialog.add_action_callback('neIsolate') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          show_ids = (data['show'] || []).map(&:to_i)
          hide_ids = (data['hide'] || []).map(&:to_i)
          VisibilityManager.hide(hide_ids) if hide_ids.any?
          VisibilityManager.show(show_ids) if show_ids.any?
          puts "Takeoff: neIsolate show=#{show_ids.length} hide=#{hide_ids.length}"
        rescue => e
          puts "Takeoff: neIsolate error: #{e.message}"
        end
      end

      dialog.add_action_callback('highlightScannerGroup') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.highlight_entities(ids)
      end

      dialog.add_action_callback('clearScannerHighlight') do |_ctx|
        Highlighter.clear_all
      end

    end
  end
end
