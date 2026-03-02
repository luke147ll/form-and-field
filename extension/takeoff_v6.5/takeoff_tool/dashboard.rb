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
          # Persist to model
          TakeoffTool.save_assignment(eid, 'category', cat)
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

      @dialog.add_action_callback('clearMeasurementHighlights') do |_ctx|
        Highlighter.clear_measurement_highlights
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
        ids_str.to_s.split(',').each do |id|
          e = TakeoffTool.find_entity(id.to_i)
          e.visible = false if e && e.valid?
        end
        m.commit_operation
      end

      @dialog.add_action_callback('showEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        Highlighter.show_entities_with_ancestors(ids)
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
          end
          TakeoffTool.category_assignments = ca
          send_data(sr, ca, cca)
        rescue => e
          puts "Takeoff bulkSetCategory error: #{e.message}"
        end
      end

      # Rename an entire category
      @dialog.add_action_callback('renameCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          old_name = data['oldName'].to_s
          new_name = data['newName'].to_s
          eids = data['eids'] || []
          puts "Takeoff: renameCategory '#{old_name}' -> '#{new_name}' (#{eids.length} items)"
          eids.each do |eid|
            eid_i = eid.to_i
            ca[eid_i] = new_name
            TakeoffTool.save_assignment(eid_i, 'category', new_name)
          end
          # Update auto_category in scan_results so re-send stays consistent
          sr.each do |r|
            if r[:parsed] && r[:parsed][:auto_category] == old_name
              r[:parsed][:auto_category] = new_name
            end
          end
          TakeoffTool.category_assignments = ca
        rescue => e
          puts "Takeoff renameCategory error: #{e.message}"
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

      # Isolate multiple categories at once
      @dialog.add_action_callback('isolateCategories') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cats = data['cats'] || []
          puts "Takeoff: isolateCategories #{cats.join(', ')}"
          Highlighter.isolate_categories(sr, ca, cats)
        rescue => e
          puts "Takeoff isolateCategories error: #{e.message}"
        end
      end

      # Highlight multiple categories at once
      @dialog.add_action_callback('highlightCategories') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cats = data['cats'] || []
          puts "Takeoff: highlightCategories #{cats.join(', ')}"
          Highlighter.highlight_categories(sr, ca, cats)
        rescue => e
          puts "Takeoff highlightCategories error: #{e.message}"
        end
      end

      # Hide multiple categories at once
      @dialog.add_action_callback('hideCategories') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cats = data['cats'] || []
          puts "Takeoff: hideCategories #{cats.join(', ')}"
          Highlighter.hide_categories(sr, ca, cats)
        rescue => e
          puts "Takeoff hideCategories error: #{e.message}"
        end
      end

      # Isolate specific entities by ID
      @dialog.add_action_callback('isolateEntities') do |_ctx, ids_str|
        ids = ids_str.to_s.split(',').map(&:to_i)
        puts "Takeoff: isolateEntities #{ids.length} items"
        Highlighter.isolate_entities(sr, ids)
      end


      @dialog.show
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

        mt = Parser.measurement_for(cat)
        # Check for user override stored in model attributes
        m_override = Sketchup.active_model.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
        mt = m_override if m_override && !m_override.empty?
        {
          entityId: r[:entity_id], tag: r[:tag],
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

      cats = ['Drywall','Wall Framing','Walls','Wall Finish','Wall Structure','Wall Sheathing',
        'Masonry / Veneer','Siding','Exterior Finish','Soffit','Stucco','Decorative Metal',
        'Glass/Glazing','Wood Paneling',
        'Metal Roofing','Shingle Roofing','Roofing','Roof Framing','Roof Sheathing',
        'Concrete','Flooring','Ceilings','Ceiling Framing','Structural Lumber','Structural Steel',
        'Insulation','Membrane',
        'Foundation Slabs','Foundation Walls','Foundation Footings',
        'Windows','Doors','Garage Doors','Shower Doors','Casework','Countertops','Plumbing',
        'Hardware','Trim','Fascia','Gutters','Flashing','Baseboard',
        'Crown Mold','Casing','Railing','Drip Edge',
        'Tile','Backsplash','Shower Walls','Sheathing',
        'Appliances','Bath Accessories','Outdoor Kitchen','Chimney',
        'HVAC','Snow Guards','Lighting Fixtures','Window Treatments','Outdoor Features',
        'Furniture','Railings','Stairs','Specialty Equipment',
        'Electrical Equipment','Electrical Fixtures','Rooms',
        'Generic Models','Uncategorized','_IGNORE']

      # Merge in any custom categories from assignments or auto-parsed
      all_cats = cats.dup
      ca.each_value { |c| all_cats << c unless all_cats.include?(c) }
      sr.each { |r| c = r[:parsed][:auto_category]; all_cats << c if c && !all_cats.include?(c) }
      cats = all_cats

      require 'json'
      js = JSON.generate({ rows: rows, categories: cats, costCodes: cc })
      # Double-escape backslashes, escape single quotes for JS string
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveData('#{esc}')")
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
