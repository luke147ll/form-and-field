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
        fsr = TakeoffTool.filtered_scan_results
        ca = TakeoffTool.category_assignments
        puts "Dashboard: isolateCategory cat='#{cat}' fsr=#{fsr.length} ca_keys=#{ca.keys.length} mv_view=#{TakeoffTool.active_mv_view}"
        Highlighter.isolate_category(fsr, ca, cat)
      end

      dialog.add_action_callback('isolateTag') do |_ctx, tag_str|
        Highlighter.isolate_tag(tag_str.to_s)
      end

      dialog.add_action_callback('hideCategory') do |_ctx, cat_str|
        Highlighter.hide_category(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      dialog.add_action_callback('showCategory') do |_ctx, cat_str|
        Highlighter.show_category(TakeoffTool.filtered_scan_results, TakeoffTool.category_assignments, cat_str.to_s)
      end

      dialog.add_action_callback('showAll') do |_ctx|
        Highlighter.show_all
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
              if e.respond_to?(:definition) && Dashboard._has_visible_scan_child?(e.definition, scan_eid_set, hide_set)
                next
              end
            end
            e.visible = false
          end
        end
        m.commit_operation
        Dashboard.send_measurement_data if meas_changed
      end

      dialog.add_action_callback('showEntities') do |_ctx, ids_str|
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
        Dashboard.send_measurement_data if meas_changed
      end

      dialog.add_action_callback('isolatePartGroup') do |_ctx, eid_str|
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
        Highlighter.isolate_entities(TakeoffTool.filtered_scan_results, ids)
      end

      # NE review isolation: only hides/shows entities in the new entities list,
      # leaves all other scan entities untouched (no casework bleed-through)
      dialog.add_action_callback('neIsolate') do |_ctx, json_str|
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
