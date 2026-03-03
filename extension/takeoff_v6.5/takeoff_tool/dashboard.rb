module TakeoffTool
  module Dashboard
    @dialog = nil

    def self.show(sr, ca, cca)
      if @dialog && @dialog.visible?; send_data(sr, ca, cca); return; end

      @dialog = UI::HtmlDialog.new(dialog_title:"Form and Field \u2014 Takeoff Report", preferences_key:"TakeoffDash",
        width:1280, height:780, left:80, top:80, resizable:true, style:UI::HtmlDialog::STYLE_DIALOG)
      @dialog.set_file(File.join(PLUGIN_DIR,'ui','dashboard.html'))

      # All callbacks receive a single JSON string argument and parse it in Ruby.
      # This avoids all multi-arg and encoding issues with skp: protocol.

      @dialog.add_action_callback('requestData') do |_ctx|
        send_data(sr, ca, cca)
      end

      @dialog.add_action_callback('setCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['val'].to_s
          puts "Takeoff: setCategory eid=#{eid} cat=#{cat}"
          ca[eid] = cat
          TakeoffTool.category_assignments = ca
          RecatLog.log_change(eid, cat)
          # Persist to model — clear subcategory on category change
          TakeoffTool.save_assignment(eid, 'category', cat)
          TakeoffTool.save_assignment(eid, 'subcategory', '')
          sr.each { |r| if r[:entity_id] == eid; r[:parsed][:auto_subcategory] = ''; break; end }
          send_data(sr, ca, cca)
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
          cca[eid] = code
          TakeoffTool.cost_code_assignments = cca
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
          sr.each do |r|
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
          sr.each do |r|
            ecat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
            if ecat == cat
              r[:parsed][:measurement_type] = mt
            end
          end
          # Resend data so dashboard shows updated measurement types
          send_data(sr, ca, cca)
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
          send_data(sr, ca, cca)
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
        Highlighter.highlight_all(sr, ca)
      end

      @dialog.add_action_callback('highlightCategory') do |_ctx, cat_str|
        Highlighter.clear_all
        Highlighter.highlight_category(sr, ca, cat_str.to_s)
      end

      @dialog.add_action_callback('highlightSingle') do |_ctx, eid_str|
        Highlighter.highlight_single(eid_str.to_s)
      end

      @dialog.add_action_callback('highlightEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.highlight_entities(ids)
      end

      @dialog.add_action_callback('clearHighlights') do |_ctx|
        Highlighter.clear_all
      end

      @dialog.add_action_callback('isolateCategory') do |_ctx, cat_str|
        Highlighter.isolate_category(sr, ca, cat_str.to_s)
      end

      @dialog.add_action_callback('isolateTag') do |_ctx, tag_str|
        Highlighter.isolate_tag(tag_str.to_s)
      end

      @dialog.add_action_callback('showAll') do |_ctx|
        Highlighter.show_all
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
            if mtype == 'LF' || mtype == 'ELEV' || mtype == 'BENCHMARK'
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
            if mtype == 'LF' || mtype == 'ELEV' || mtype == 'BENCHMARK'
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
        Exporter.export_csv(sr, ca, cca)
      end

      @dialog.add_action_callback('exportHTML') do |_ctx|
        Exporter.export_html(sr, ca, cca)
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
          eids.each do |eid|
            eid_i = eid.to_i
            ca[eid_i] = cat
            RecatLog.log_change(eid_i, cat)
            TakeoffTool.save_assignment(eid_i, 'category', cat)
            TakeoffTool.save_assignment(eid_i, 'subcategory', '')
            sr.each { |r| if r[:entity_id] == eid_i; r[:parsed][:auto_subcategory] = ''; break; end }
          end
          TakeoffTool.category_assignments = ca
          send_data(sr, ca, cca)
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
          TakeoffTool.add_category(name)
          send_data(sr, ca, cca)
          puts "Takeoff: addEmptyCategory '#{name}'"
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
            sr.each do |r|
              if r[:entity_id] == eid_i
                r[:parsed][:size_nominal] = val
                break
              end
            end
          end
          send_data(sr, ca, cca)
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
            cca[eid_i] = code
            TakeoffTool.save_assignment(eid_i, 'cost_code', code)
          end
          TakeoffTool.cost_code_assignments = cca
          send_data(sr, ca, cca)
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
          send_data(sr, ca, cca)
          send_measurement_data
        rescue => e
          puts "Takeoff deleteMeasurement error: #{e.message}"
        end
      end

      @dialog.add_action_callback('requestMeasurements') do |_ctx|
        send_measurement_data
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

      # Isolate specific entities by ID
      @dialog.add_action_callback('isolateEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        puts "Takeoff: isolateEntities #{ids.length} items"
        Highlighter.isolate_entities(sr, ids)
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
          next if name.empty? || ids.empty?
          TakeoffTool.create_assembly(name, ids, notes)
          puts "Takeoff: Created assembly '#{name}' with #{ids.length} entities"
          send_assemblies
        rescue => e
          puts "Takeoff createAssembly error: #{e.message}"
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

      @dialog.show
    end

    def self.send_assemblies
      return unless @dialog && @dialog.visible?
      require 'json'
      assemblies = TakeoffTool.load_assemblies
      js = JSON.generate(assemblies)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveAssemblies('#{esc}')")
    end

    def self.scroll_to_entity(eid)
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("scrollToEntity(#{eid})")
    end

    def self.send_data(sr, ca, cca)
      return unless @dialog
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
        auto_cc = has_assigned ? assigned : (sc.length == 1 ? sc[0] : '')
        has_overlap = sc.length > 1 && !has_assigned

        mt_default = Parser.measurement_for(cat)
        mt = mt_default
        # Check for user override stored in model attributes
        m_override = Sketchup.active_model.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
        mt = m_override if m_override && !m_override.empty?
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
          revitId: r[:parsed][:revit_id], ifcType: r[:ifc_type]
        }
      end

      cats = TakeoffTool.master_categories

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
      msub = TakeoffTool.master_subcategories
      js = JSON.generate({ rows: rows, categories: cats, costCodes: cc, masterSubcategories: msub, categoryMT: cat_mt })
      # Double-escape backslashes, escape single quotes for JS string
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveData('#{esc}')")

      send_measurement_data
      send_assemblies
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

    def self.scan_log_end(summary)
      return unless @dialog && @dialog.visible?
      esc = summary.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("scanEnd('#{esc}')")
    end

    def self.close
      @dialog.close if @dialog
      @dialog = nil
    end
  end
end
