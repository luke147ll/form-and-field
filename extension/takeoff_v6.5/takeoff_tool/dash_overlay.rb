module TakeoffTool
  class DashOverlay
    def self.register_callbacks(dialog)

      # ═══ CAD OVERLAYS ═══

      dialog.add_action_callback('importCadSheet') do |_ctx|
        CadOverlay.import_sheet
      end

      dialog.add_action_callback('toggleCadSheet') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          show = data['show']
          grp = CadOverlay.find_sheet_group(Sketchup.active_model, eid)
          if grp && grp.layer
            grp.layer.visible = !!show
          end
          Dashboard.send_overlay_vis_state
        rescue => e
          puts "Dashboard: toggleCadSheet error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteCadSheet') do |_ctx, eid_str|
        CadOverlay.delete_sheet(eid_str.to_i)
        Dashboard.send_cad_sheets
      end

      dialog.add_action_callback('zoomCadSheet') do |_ctx, eid_str|
        model = Sketchup.active_model
        grp = CadOverlay.find_sheet_group(model, eid_str.to_i)
        if grp
          model.selection.clear
          model.selection.add(grp)
          model.active_view.zoom(model.selection)
        end
      end

      dialog.add_action_callback('alignCadSheet') do |_ctx, eid_str|
        model = Sketchup.active_model
        grp = CadOverlay.find_sheet_group(model, eid_str.to_i)
        if grp
          stype = grp.get_attribute(CAD_DICT, 'sheet_type') || 'plan'
          tool = (stype == 'section') ? SectionAlignTool.new(grp) : PlanAlignTool.new(grp)
          model.select_tool(tool)
        end
      end

      dialog.add_action_callback('setCadCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          CadOverlay.set_sheet_category(data['eid'].to_i, data['category'].to_s)
          Dashboard.send_cad_sheets
        rescue => e
          puts "Dashboard: setCadCategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('showAllCad') do |_ctx|
        model = Sketchup.active_model
        model.active_entities.grep(Sketchup::Group).each do |grp|
          next unless grp.valid? && grp.get_attribute('FF_CadOverlay', 'sheet_name')
          grp.layer.visible = true if grp.layer
        end
        Dashboard.send_cad_sheets
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('hideAllCad') do |_ctx|
        model = Sketchup.active_model
        model.active_entities.grep(Sketchup::Group).each do |grp|
          next unless grp.valid? && grp.get_attribute('FF_CadOverlay', 'sheet_name')
          grp.layer.visible = false if grp.layer
        end
        Dashboard.send_cad_sheets
        Dashboard.send_overlay_vis_state
      end

      # ═══ ELEVATION / NOTE / BENCHMARK ═══

      dialog.add_action_callback('updateElevLabel') do |_ctx, json_str|
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
            Dashboard.invalidate_measurement_cache
            Dashboard.send_measurement_data
          end
        rescue => e
          puts "Takeoff updateElevLabel error: #{e.message}"
        end
      end

      dialog.add_action_callback('updateNoteText') do |_ctx, json_str|
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
            Dashboard.invalidate_measurement_cache
            Dashboard.send_measurement_data
          end
        rescue => e
          puts "Takeoff updateNoteText error: #{e.message}"
        end
      end

      dialog.add_action_callback('activateNote') do |_ctx|
        TakeoffTool.activate_note_tool
      end

      dialog.add_action_callback('requestBenchmark') do |_ctx|
        Dashboard.send_benchmark_data
      end

      dialog.add_action_callback('activateBenchmark') do |_ctx|
        TakeoffTool.activate_benchmark_tool
      end

      dialog.add_action_callback('activateElevation') do |_ctx|
        TakeoffTool.activate_elevation_tool
      end

      # ═══ SECTION CUTS ═══

      dialog.add_action_callback('requestSectionCuts') do |_ctx|
        Dashboard.send_section_cuts
      end

      dialog.add_action_callback('activateSectionCut') do |_ctx, name_str|
        begin
          name = name_str.to_s
          puts "Dashboard: activateSectionCut '#{name}'"
          SectionCuts.activate_cut(name)
          Dashboard.send_section_cuts
        rescue => e
          puts "Dashboard: activateSectionCut error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('deactivateSectionCuts') do |_ctx|
        begin
          SectionCuts.deactivate_all
          Dashboard.send_section_cuts
        rescue => e
          puts "Dashboard: deactivateSectionCuts error: #{e.message}"
        end
      end

      dialog.add_action_callback('refreshSectionCuts') do |_ctx|
        begin
          SectionCuts.remove_all_planes
          SectionCuts.cuts.clear
          SectionCuts.build_presets
          SectionCuts.sync_planes
          Dashboard.send_section_cuts
        rescue => e
          puts "Dashboard: refreshSectionCuts error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('removeSectionCut') do |_ctx, name_str|
        SectionCuts.remove_cut(name_str.to_s)
        Dashboard.send_section_cuts
      end

      dialog.add_action_callback('addCustomSectionCut') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          label = data['label'].to_s.strip
          z = data['z'].to_f
          next if label.empty? || z == 0
          SectionCuts.add_custom_cut(label, z)
          Dashboard.send_section_cuts
        rescue => e
          puts "Dashboard: addCustomSectionCut error: #{e.message}"
        end
      end

      # ═══ GRIDLINES ═══

      dialog.add_action_callback('startGridNum') do |_ctx|
        TakeoffTool.activate_annotation_tag_tool_with_mode('grid_num')
      end

      dialog.add_action_callback('startGridAlpha') do |_ctx|
        TakeoffTool.activate_annotation_tag_tool_with_mode('grid_alpha')
      end

      dialog.add_action_callback('createGridSet') do |_ctx, json_str|
        require 'json'
        data = JSON.parse(json_str.to_s)
        axis = data['axis'] == 'x' ? :x : :y
        start_in = (data['start'] || 0).to_f * 12.0
        spacing_in = (data['spacing'] || 10).to_f * 12.0
        count = (data['count'] || 5).to_i
        labels = data['labels']
        Dashboard.heartbeat_start('Creating gridlines...') rescue nil
        results = TakeoffTool::GridlineSystem.create_grid_set(axis, start_in, spacing_in, count, labels)
        Dashboard.heartbeat_stop rescue nil
        safe = JSON.generate(results).gsub('</') { '<\\/' }
        dialog.execute_script("receiveGridResult(#{safe})") rescue nil
        dialog.execute_script("refreshGridlines()") rescue nil
      end

      dialog.add_action_callback('createSingleGridline') do |_ctx, json_str|
        require 'json'
        data = JSON.parse(json_str.to_s)
        axis = data['axis'] == 'x' ? :x : :y
        pos_in = (data['position'] || 0).to_f * 12.0
        label = data['label'].to_s.strip
        TakeoffTool::GridlineSystem.create_gridline(axis, pos_in, label) unless label.empty?
        dialog.execute_script("refreshGridlines()") rescue nil
      end

      dialog.add_action_callback('deleteGridline') do |_ctx, label_str|
        TakeoffTool::GridlineSystem.delete_gridline(label_str.to_s)
        dialog.execute_script("refreshGridlines()") rescue nil
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('clearAllGridlines') do |_ctx|
        TakeoffTool::GridlineSystem.clear_all
        dialog.execute_script("refreshGridlines()") rescue nil
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('listGridlines') do |_ctx|
        require 'json'
        grids = TakeoffTool::GridlineSystem.list_gridlines
        safe = JSON.generate(grids).gsub('</') { '<\\/' }
        dialog.execute_script("receiveGridlines(#{safe})") rescue nil
      end

      dialog.add_action_callback('toggleGridline') do |_ctx, eid_str|
        TakeoffTool::GridlineSystem.toggle_gridline(eid_str.to_i)
        dialog.execute_script("refreshGridlines()") rescue nil
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('toggleAllGridlines') do |_ctx|
        TakeoffTool::GridlineSystem.toggle_all
        dialog.execute_script("refreshGridlines()") rescue nil
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('showAllGridlines') do |_ctx|
        model = Sketchup.active_model
        next unless model
        # Ensure the FF_Gridlines layer is visible too
        gl = model.layers['FF_Gridlines']
        gl.visible = true if gl
        model.active_entities.grep(Sketchup::Group).each do |g|
          next unless g.valid?
          next unless g.get_attribute('TakeoffGridline', 'label') || g.get_attribute('TakeoffMeasurement', 'type') == 'GRID'
          g.visible = true
        end
        dialog.execute_script("refreshGridlines()") rescue nil
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('hideAllGridlines') do |_ctx|
        model = Sketchup.active_model
        next unless model
        model.active_entities.grep(Sketchup::Group).each do |g|
          next unless g.valid?
          next unless g.get_attribute('TakeoffGridline', 'label') || g.get_attribute('TakeoffMeasurement', 'type') == 'GRID'
          g.visible = false
        end
        dialog.execute_script("refreshGridlines()") rescue nil
        Dashboard.send_overlay_vis_state
      end

    end
  end
end
