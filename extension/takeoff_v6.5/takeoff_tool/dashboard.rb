module TakeoffTool
  module Dashboard
    @dialog = nil
    @data_dirty = false   # Set true when data changes; checked on close
    @meas_cache = nil        # cached measurement payload
    @meas_cache_dirty = true # flag to force recompute

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

    def self.dialog
      @dialog
    end

    def self.show(sr, ca, cca)
      unless TakeoffTool::LicenseManager.licensed?
        TakeoffTool::LicenseManager.show_activation_dialog
        return
      end
      if @dialog && @dialog.visible?; send_live_data; return; end

      @dialog = UI::HtmlDialog.new(dialog_title:"Form and Field \u2014 Takeoff Report", preferences_key:"TakeoffDash_v3",
        width:1280, height:780, left:80, top:80, resizable:true, style:UI::HtmlDialog::STYLE_DIALOG)
      @dialog.set_file(File.join(PLUGIN_DIR,'ui','dashboard.html'))

      # Core data callback — stays here since it bootstraps everything
      @dialog.add_action_callback('requestData') do |_ctx|
        begin
          puts "[FF Dashboard] requestData: #{TakeoffTool.scan_results.length} results, mv=#{TakeoffTool.active_mv_view || 'none'}"
          send_live_data
          invalidate_measurement_cache
          send_measurement_data
        rescue => e
          puts "Dashboard: requestData error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        end
      end

      # On-close handler
      @dialog.set_on_closed {
        @dialog = nil
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

      # Module callback registration
      DashCategories.register_callbacks(@dialog) if defined?(DashCategories)
      DashEdits.register_callbacks(@dialog) if defined?(DashEdits)
      DashNavigation.register_callbacks(@dialog) if defined?(DashNavigation)
      DashContainers.register_callbacks(@dialog) if defined?(DashContainers)
      DashActions.register_callbacks(@dialog) if defined?(DashActions)
      DashVisibility.register_callbacks(@dialog) if defined?(DashVisibility)
      DashColor.register_callbacks(@dialog) if defined?(DashColor)
      DashMeasurement.register_callbacks(@dialog) if defined?(DashMeasurement)
      DashAssembly.register_callbacks(@dialog) if defined?(DashAssembly)
      DashOverlay.register_callbacks(@dialog) if defined?(DashOverlay)
      DashMultiverse.register_callbacks(@dialog) if defined?(DashMultiverse)
      DashScanner.register_callbacks(@dialog) if defined?(DashScanner)
      DashNotes.register_callbacks(@dialog) if defined?(DashNotes)

      @dialog.show
    end

    # ── Scanner Mode Send Methods ──

    def self.send_scanner_banner(summary)
      return unless @dialog
      require 'json'
      js = JSON.generate(summary)
      b64 = [js].pack('m0')
      @dialog.execute_script("if(typeof receiveScannerBanner==='function')receiveScannerBanner(JSON.parse(atob('#{b64}')))") rescue nil
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
      b64 = [js].pack('m0')
      @dialog.execute_script("if(typeof receiveNewEntitiesBanner==='function')receiveNewEntitiesBanner(JSON.parse(atob('#{b64}')))") rescue nil
    end

    def self.send_scanner_groups
      return unless @dialog
      require 'json'
      groups = InteractiveScanner.serialize_groups
      cats = TakeoffTool.master_categories
      msub = TakeoffTool.master_subcategories
      payload = { groups: groups, categories: cats, subcategories: msub }
      js = JSON.generate(payload)
      b64 = [js].pack('m0')
      @dialog.execute_script("if(typeof receiveScannerGroups==='function')receiveScannerGroups(JSON.parse(atob('#{b64}')))") rescue nil
    end

    def self.send_assemblies
      return unless @dialog && @dialog.visible?
      require 'json'
      assemblies = TakeoffTool.load_assemblies

      # Build entity→category lookup from scan results
      mv_view = TakeoffTool.active_mv_view
      sr = (mv_view && mv_view != 'ab') ? TakeoffTool.filtered_scan_results : (TakeoffTool.scan_results || [])
      ca = TakeoffTool.category_assignments || {}

      eid_cat = {}
      sr.each do |r|
        eid_cat[r[:entity_id].to_i] = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      end

      # Build enhanced payload with parts data
      payload = {}
      assemblies.each do |asm_id, asm|
        parts = asm['parts'] || []

        # Collect entity IDs from non-virtual parts
        entity_ids = parts.reject { |p| p['is_virtual'] }.map { |p| p['entity_id'] }.compact.map(&:to_i)

        # Multiverse: skip assemblies with no entities in current view
        if mv_view && mv_view != 'ab'
          view_eids = {}
          sr.each { |r| view_eids[r[:entity_id].to_i] = true }
          next unless entity_ids.any? { |eid| view_eids[eid] } || parts.any? { |p| p['is_virtual'] }
        end

        # Build category breakdown from parts
        breakdown = {}
        parts.each do |p|
          cat = p['category'] || 'Uncategorized'
          breakdown[cat] ||= 0
          breakdown[cat] += (p['quantity'] || 1)
        end
        total = parts.map { |p| p['quantity'] || 1 }.sum.to_f
        breakdown_arr = breakdown.map { |cat, count|
          { 'category' => cat, 'count' => count, 'percent' => (total > 0 ? (count / total * 100).round(1) : 0) }
        }.sort_by { |b| -b['count'] }

        # Build summary: qty totals per category
        summary = {}
        parts.each do |p|
          cat = p['category'] || 'Uncategorized'
          summary[cat] ||= { 'qty' => 0 }
          summary[cat]['qty'] += (p['quantity'] || 1)
        end

        # Parts payload for JS
        parts_payload = parts.map do |p|
          eid = p['entity_id']
          e = eid ? TakeoffTool.find_entity(eid.to_i) : nil
          sku = e && e.valid? ? (e.get_attribute('TakeoffAssignments', 'sku') || '') : ''
          {
            'part_num'         => p['part_number'],
            'entity_id'        => eid,
            'name'             => p['name'],
            'category'         => p['category'],
            'qty'              => p['quantity'] || 1,
            'unit'             => p['unit'] || 'EA',
            'notes'            => p['notes'] || '',
            'is_virtual'       => p['is_virtual'] || false,
            'stale'            => p['stale'] || false,
            'sku'              => sku
          }
        end

        beam_inv = build_beam_inventory_for_eids(entity_ids)

        tags_visible = (TakeoffTool.asm_tags_visible || {})[asm_id] || false

        payload[asm_id] = {
          'name'        => asm['name'],
          'zone'        => asm['zone'] || '',
          'entity_ids'  => entity_ids,
          'count'       => entity_ids.length,
          'created'     => asm['created'],
          'notes'       => asm['notes'] || '',
          'parts'       => parts_payload,
          'tags_visible' => tags_visible,
          'part_count'  => parts.length,
          'breakdown'   => breakdown_arr,
          'summary'     => summary,
          'beamInventory' => beam_inv
        }
      end

      js = JSON.generate(payload)
      puts "[FF send_asm] payload size: #{js.length} chars, #{payload.length} assemblies"
      # Base64 encode to eliminate all escaping issues (quotes, backslashes in part names)
      b64 = [js].pack('m0')
      @dialog.execute_script("receiveAssemblies(JSON.parse(atob('#{b64}')))")
    end

    def self.send_parts_data
      return unless @dialog && @dialog.visible?
      require 'json'
      parts = TakeoffTool.load_parts rescue {}
      return if parts.empty?
      js = JSON.generate(parts)
      b64 = [js].pack('m0')
      @dialog.execute_script("receiveParts(JSON.parse(atob('#{b64}')))") rescue nil
    end

    def self.send_comparison_results
      return unless @dialog
      require 'json'
      data = TakeoffTool.serialize_comparison_results
      return unless data
      js = JSON.generate(data)
      b64 = [js].pack('m0')
      @dialog.execute_script("receiveComparisonResults(JSON.parse(atob('#{b64}')))") rescue nil
    end

    def self.send_diff_results
      return unless @dialog
      require 'json'
      diff = TakeoffTool.diff_data
      total = diff ? diff.length : 0
      payload = { 'totalEntities' => total, 'diffActive' => TakeoffTool.diff_active? }
      js = JSON.generate(payload)
      b64 = [js].pack('m0')
      @dialog.execute_script("receiveDiffResults(JSON.parse(atob('#{b64}')))") rescue nil
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

    def self.send_vis_state
      return unless @dialog && @dialog.visible?
      reg = TakeoffTool.entity_registry || {}

      # Check actual entity visibility — authoritative, no stale tracking state
      hidden = {}
      reg.each do |eid, e|
        next unless e && e.valid?
        hidden[eid] = true unless e.visible?
      end

      require 'json'
      b64 = [JSON.generate(hidden)].pack('m0')
      @dialog.execute_script("receiveVisState(JSON.parse(atob('#{b64}')))")
    rescue => e
      puts "[FF send_vis_state] error: #{e.message}"
    end

    def self.send_data(sr, ca, cca)
      return unless @dialog
      heartbeat_start('Updating panel...')
      begin
      # Multiverse: filter to active model's entities
      mv_view = TakeoffTool.active_mv_view
      if mv_view && mv_view != 'ab'
        sr = TakeoffTool.filtered_scan_results
      end
      custom_colors = load_custom_colors_for_view
      cc = []; ccm = {}
      begin
        d = TakeoffTool.effective_cost_codes
        cc = d['codes'] || []
        ccm = d['category_to_cost_code'] || {}
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
          committedFrom: (TakeoffTool.find_entity(r[:entity_id])&.get_attribute('FormAndField', 'committed_from') rescue nil),
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
      locked_cats = begin
        require 'json'
        raw = Sketchup.active_model&.get_attribute('FormAndField', 'ff_locked_categories')
        raw ? JSON.parse(raw) : []
      rescue
        []
      end
      js = JSON.generate({ rows: rows, categories: cats, allCategories: all_cats, costCodes: cc, catCostCodeMap: ccm, masterSubcategories: msub, allMasterSubcategories: all_msub, categoryMT: cat_mt, customColors: custom_colors, colorSettings: color_settings, containers: containers, overcountWarnings: oc_warnings, lockedCategories: locked_cats })
      # Double-escape backslashes, escape single quotes for JS string
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveData('#{esc}')")

      send_assemblies
      send_parts_data
      send_multiverse_data
      send_cad_sheets
      send_overlay_vis_state
      heartbeat_stop

      rescue => e
        puts "[FF Dashboard] send_data error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        heartbeat_stop
      end
    end

    def self.invalidate_measurement_cache
      @meas_cache_dirty = true
    end

    def self.heartbeat_start(msg = 'working...')
      return unless @dialog && @dialog.visible?
      safe_msg = msg.to_s.gsub("'", "\\\\'")
      @dialog.execute_script("if(typeof heartbeatOn==='function')heartbeatOn('#{safe_msg}')") rescue nil
    end

    def self.heartbeat_stop
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("if(typeof heartbeatOff==='function')heartbeatOff()") rescue nil
    end

    def self.build_beam_inventory_for_eids(eid_list)
      sr = TakeoffTool.scan_results || []
      reg = TakeoffTool.instance_variable_get(:@entity_registry) || {}
      eid_set = Set.new(eid_list.map(&:to_i))
      beam_items = []

      sr.each do |r|
        next unless eid_set.include?(r[:entity_id].to_i)
        next unless (r[:linear_ft] || 0) > 0
        eid = r[:entity_id]

        # Cross-section from definition bounding box (local space, rotation-independent)
        sec_str = nil
        ent_for_beam = reg[eid]
        if ent_for_beam && ent_for_beam.valid? && ent_for_beam.respond_to?(:definition)
          dbb = ent_for_beam.definition.bounds
          ddims = [dbb.width, dbb.height, dbb.depth].sort
          sec_str = "#{ddims[0].round(2)}x#{ddims[1].round(2)}"
        end
        # Fallback: scan result BB (world-space, may be inflated for diagonal beams)
        unless sec_str
          dims = [r[:bb_width_in] || 0, r[:bb_height_in] || 0, r[:bb_depth_in] || 0].sort
          sec_str = "#{dims[0].round(2)}x#{dims[1].round(2)}"
        end

        beam_items << {
          defn: r[:display_name] || r[:definition_name] || 'Unknown',
          lf: (r[:linear_ft] || 0).to_f,
          section: sec_str,
          eid: r[:entity_id]
        }
      end

      return [] if beam_items.empty?

      inv = {}
      beam_items.each do |bi|
        inv_key = "#{bi[:defn]}|#{bi[:section]}"
        inv[inv_key] ||= { defn: bi[:defn], section: bi[:section], items: [] }
        inv[inv_key][:items] << { lf: bi[:lf].round(2), eid: bi[:eid] }
      end

      result = []
      inv.sort_by { |_dn, d| -d[:items].sum { |i| i[:lf] } }.each do |_dn, d|
        all_eids = d[:items].map { |i| i[:eid] }
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
        result << {
          'defn' => d[:defn],
          'section' => d[:section],
          'count' => d[:items].length,
          'totalLF' => d[:items].sum { |i| i[:lf] }.round(1),
          'eids' => all_eids,
          'rows' => rows
        }
      end
      result
    end

    def self.send_measurement_data
      return unless @dialog && @dialog.visible?
      require 'json'
      m = Sketchup.active_model
      return unless m

      # Fast path: reuse cached payload if nothing measurement-relevant changed
      if !@meas_cache_dirty && @meas_cache
        @dialog.execute_script("receiveMeasurements(JSON.parse(atob('#{@meas_cache}')))") rescue nil
        send_benchmark_data
        send_section_cuts
        return
      end

      measurements = []
      # Collect measurement groups (Groups and ComponentInstances with TakeoffMeasurement attrs)
      m.entities.each do |grp|
        next unless grp.valid?
        next unless grp.is_a?(Sketchup::Group) || grp.is_a?(Sketchup::ComponentInstance)
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        next if mtype == 'GRID'  # Gridlines are managed in CAD overlay tab, not measurements
        next if grp.get_attribute('TakeoffMeasurement', 'part_link')  # Child groups shown as parts, not cards

        cat = grp.get_attribute('TakeoffMeasurement', 'category') || 'Custom'
        visible = grp.get_attribute('TakeoffMeasurement', 'highlights_visible')
        visible = false if visible.nil?
        note = grp.get_attribute('TakeoffMeasurement', 'note') || ''
        rgba_json = grp.get_attribute('TakeoffMeasurement', 'color_rgba')
        color = begin; JSON.parse(rgba_json); rescue; nil; end

        part_name = grp.get_attribute('TakeoffMeasurement', 'part_name') || ''
        cost_code = grp.get_attribute('TakeoffMeasurement', 'cost_code') || ''

        # Also check category-level cost code assignment
        if cost_code.empty?
          ccm = (TakeoffTool.effective_cost_codes['category_to_cost_code'] rescue {}) || {}
          cc_arr = ccm[cat]
          cost_code = cc_arr.first if cc_arr && cc_arr.length == 1
        end

        is_imported = !!grp.get_attribute('TakeoffMeasurement', 'imported')
        import_source = grp.get_attribute('TakeoffMeasurement', 'import_source') || ''

        entry = {
          eid: grp.entityID,
          type: mtype,
          category: cat,
          visible: visible,
          note: note,
          color: color,
          partName: part_name,
          costCode: cost_code || ''
        }
        if is_imported
          entry[:imported] = true
          entry[:importSource] = import_source
        end

        committed_by = grp.get_attribute('TakeoffMeasurement', 'committed_by')
        entry[:committedBy] = committed_by if committed_by

        vs_target = grp.get_attribute('TakeoffMeasurement', 'vs_target')
        vs_local = grp.get_attribute('TakeoffMeasurement', 'vs_local')
        entry[:vsTarget] = vs_target.to_i if vs_target
        entry[:vsLocal] = vs_local.to_i if vs_local

        if mtype == 'SF'
          # Derive SF from physical geometry faces; fall back to stored attr for legacy groups
          geo_faces = grp.entities.grep(Sketchup::Face)
          if geo_faces.any?
            entry[:value] = (geo_faces.sum { |f| f.area } / 144.0).round(2)
            entry[:faceCount] = geo_faces.length
          else
            entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
            entry[:faceCount] = grp.get_attribute('TakeoffMeasurement', 'face_count') || 0
          end
          entry[:unit] = 'SF'
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'label') || ''
          entry[:sfColor] = color  # per-group RGBA from color_rgba attr
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
        elsif mtype == 'VOL'
          # Derive volume from marker sub-groups; fall back to stored attr
          markers = grp.entities.grep(Sketchup::Group).select { |g|
            g.valid? && g.get_attribute('VOL_Marker', 'volume_cy')
          }
          if markers.any?
            entry[:value] = markers.sum { |g| (g.get_attribute('VOL_Marker', 'volume_cy') || 0).to_f }.round(4)
            entry[:objectCount] = markers.length
          else
            entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_cy') || 0
            entry[:objectCount] = grp.get_attribute('TakeoffMeasurement', 'object_count') || 0
          end
          entry[:unit] = 'CY'
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'label') || ''
          entry[:sfColor] = color
        elsif mtype == 'COUNT'
          markers = grp.entities.grep(Sketchup::Group).select { |g|
            g.valid? && g.get_attribute('COUNT_Marker', 'placed')
          }
          entry[:value] = markers.length
          entry[:markerCount] = markers.length
          entry[:unit] = 'EA'
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'label') || ''
          entry[:sfColor] = color
        elsif mtype == 'WALL'
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_lf') || 0
          entry[:unit] = 'LF'
          entry[:segmentCount] = grp.get_attribute('TakeoffMeasurement', 'segment_count') || 0
          entry[:totalStuds] = grp.get_attribute('TakeoffMeasurement', 'total_studs') || 0
          entry[:ocSpacing] = grp.get_attribute('TakeoffMeasurement', 'oc_spacing') || 16
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'label') || ''
          entry[:sfColor] = color
          begin
            require 'json'
            details_json = grp.get_attribute('TakeoffMeasurement', 'wall_details_json')
            entry[:wallDetails] = details_json ? JSON.parse(details_json) : []
            cfg_json = grp.get_attribute('TakeoffMeasurement', 'wall_config')
            entry[:wallConfig] = cfg_json ? JSON.parse(cfg_json) : {}
          rescue
            entry[:wallDetails] = []
            entry[:wallConfig] = {}
          end
        elsif mtype == 'CARD'
          entry[:value] = 0
          entry[:unit] = ''
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'label') || ''
        elsif mtype == 'BENCHMARK'
          next  # Don't show benchmark point in measurement panel
        else
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0
          entry[:unit] = 'LF'
          entry[:segments] = grp.get_attribute('TakeoffMeasurement', 'segment_count') || 1
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'label') || ''
          entry[:sfColor] = color  # per-group RGBA from color_rgba attr
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
      # Per-model totals for multiverse comparison
      scan_totals_a = mv_active ? {} : nil
      scan_totals_b = mv_active ? {} : nil
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

        # Track per-model totals for multiverse comparison
        if scan_totals_a
          e_ref = reg[eid]
          ms = (e_ref && e_ref.valid?) ? (e_ref.get_attribute('FormAndField', 'model_source') || 'model_a') : 'model_a'
          target = ms == 'model_a' ? scan_totals_a : scan_totals_b
          target[cat] ||= { lf: 0.0, sf: 0.0, vol: 0.0, count: 0 }
          target[cat][:count] += 1
          target[cat][:lf]  += (r[:linear_ft] || 0).to_f
          target[cat][:sf]  += (r[:area_sf] || 0).to_f
          target[cat][:vol] += (r[:volume_ft3] || 0).to_f
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
          if dunit == 'LF' && st
            cat_eids = sr.select { |r|
              rcat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
              rcat == dcat && (r[:linear_ft] || 0) > 0
            }.map { |r| r[:entity_id] }
            beam_inv = build_beam_inventory_for_eids(cat_eids)
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

        elsif src == 'measurement'
          # Derived from a specific measurement group (by sourceEid)
          # If cfg has pbSourceEid, resolve value from that linked group directly
          # (linked cards are excluded from measurements array due to part_link filter)
          cfg = v['cfg'] || {}
          pb_src_eid = (cfg['pbSourceEid'] || 0).to_i
          src_eid = (v['sourceEid'] || 0).to_i
          base = 0.0
          if pb_src_eid > 0
            # Resolve from linked source group directly
            linked_grp = TakeoffTool.find_entity(pb_src_eid)
            if linked_grp && linked_grp.valid?
              lt = linked_grp.get_attribute('TakeoffMeasurement', 'type')
              if lt == 'SF'
                geo_faces = linked_grp.entities.grep(Sketchup::Face)
                base = geo_faces.any? ? (geo_faces.sum { |f| f.area } / 144.0) : 0.0
              elsif lt == 'LF' || lt.nil?
                base = (linked_grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0).to_f
              elsif lt == 'BOX'
                base = (linked_grp.get_attribute('TakeoffMeasurement', 'volume_cf') || 0).to_f
              elsif lt == 'WALL'
                base = (linked_grp.get_attribute('TakeoffMeasurement', 'total_lf') || 0).to_f
              elsif lt == 'VOL'
                markers = linked_grp.entities.grep(Sketchup::Group).select { |g|
                  g.valid? && g.get_attribute('VOL_Marker', 'volume_cy')
                }
                base = markers.any? ? markers.sum { |g| (g.get_attribute('VOL_Marker', 'volume_cy') || 0).to_f } : 0.0
              elsif lt == 'COUNT'
                markers = linked_grp.entities.grep(Sketchup::Group).select { |g|
                  g.valid? && g.get_attribute('COUNT_Marker', 'placed')
                }
                base = markers.length.to_f
              end
            end
          else
            measurements.each do |mm|
              if mm[:eid] == src_eid
                base = (mm[:value] || 0).to_f
                break
              end
            end
          end
          new_val = (base * mult).round(2)
          if v['computedValue'] != new_val
            v['computedValue'] = new_val
            dirty = true
          end

        elsif src == 'tool_sf' || src == 'tool_lf' || src == 'linked'
          # Read value from linked child/adopted measurement group
          src_eid = (v['sourceEid'] || 0).to_i
          base = 0.0
          vis = false
          grp_type = nil
          if src_eid > 0
            grp = TakeoffTool.find_entity(src_eid)
            if grp && grp.valid?
              vis = grp.get_attribute('TakeoffMeasurement', 'highlights_visible') != false
              grp_type = grp.get_attribute('TakeoffMeasurement', 'type')
              if grp_type == 'SF' || src == 'tool_sf'
                geo_faces = grp.entities.grep(Sketchup::Face)
                base = geo_faces.any? ? (geo_faces.sum { |f| f.area } / 144.0).round(2) : 0.0
              elsif grp_type == 'LF' || src == 'tool_lf'
                base = (grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0).to_f
              elsif grp_type == 'BOX'
                base = (grp.get_attribute('TakeoffMeasurement', 'volume_cf') || 0).to_f
              end
            end
          end
          v['visible'] = vis
          v['grpType'] = grp_type
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

      payload = { measurements: measurements, scanTotals: scan_totals, derivedParts: derived }
      if scan_totals_a
        payload[:scanTotalsA] = scan_totals_a
        payload[:scanTotalsB] = scan_totals_b
      end
      js = JSON.generate(payload)
      b64 = [js].pack('m0')
      @meas_cache = b64
      @meas_cache_dirty = false
      @dialog.execute_script("receiveMeasurements(JSON.parse(atob('#{b64}')))") rescue nil
      send_benchmark_data
      send_section_cuts
    end

    def self.send_cad_sheets
      return unless @dialog && @dialog.visible?
      require 'json'
      sheets = CadOverlay.list_sheets
      js = JSON.generate(sheets)
      b64 = [js].pack('m0')
      @dialog.execute_script("receiveCadSheets(JSON.parse(atob('#{b64}')))") rescue nil
    end

    def self.send_overlay_vis_state
      return unless @dialog && @dialog.visible?
      m = Sketchup.active_model
      return unless m

      # Measurements: check if any non-GRID measurement group is visible
      meas_vis = false
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype && mtype != 'GRID' && mtype != 'CARD'
        if grp.visible?
          meas_vis = true
          break
        end
      end

      # CAD: check FF_CAD_* layers
      cad_vis = false
      m.layers.each do |l|
        if l.name.start_with?('FF_CAD_') && l.visible?
          cad_vis = true
          break
        end
      end

      # Gridlines: layer must be visible AND at least one entity must be visible
      grid_vis = false
      gl = m.layers['FF_Gridlines']
      layer_ok = !gl || gl.visible?  # true if layer doesn't exist or is visible
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        if grp.get_attribute('TakeoffGridline', 'label') || grp.get_attribute('TakeoffMeasurement', 'type') == 'GRID'
          if grp.visible? && layer_ok
            grid_vis = true
            break
          end
        end
      end

      js = "{\"meas\":#{meas_vis},\"cad\":#{cad_vis},\"grid\":#{grid_vis}}"
      @dialog.execute_script("receiveOverlayVis(#{js})") rescue nil
    end

    def self.send_multiverse_data
      return unless @dialog && @dialog.visible?
      require 'json'
      mv = TakeoffTool.multiverse_data
      commit_log = TakeoffTool.build_commit_log rescue []
      if mv && mv['models'] && mv['models'].length > 1
        summary = TakeoffTool.build_comparison_summary
        payload = {
          models: mv['models'],
          activeView: mv['active_view'] || 'a',
          comparison: summary,
          needsScan: !!mv['needs_scan'],
          commitLog: commit_log
        }
      else
        payload = { models: [], activeView: 'a', comparison: [], needsScan: false, commitLog: commit_log }
      end
      js = JSON.generate(payload)
      b64 = [js].pack('m0')
      @dialog.execute_script("receiveMultiverseData(JSON.parse(atob('#{b64}')))") rescue nil
    end

    def self.send_benchmark_data
      return unless @dialog && @dialog.visible?
      require 'json'
      bmk = TakeoffTool.get_elevation_benchmark
      js = bmk ? JSON.generate(bmk) : 'null'
      b64 = [js].pack('m0')
      @dialog.execute_script("receiveBenchmark(JSON.parse(atob('#{b64}')))") rescue nil
    end

    def self.send_section_cuts
      return unless @dialog && @dialog.visible?
      begin
        require 'json'
        payload = SectionCuts.build_payload
        js = JSON.generate(payload)
        b64 = [js].pack('m0')
        @dialog.execute_script("receiveSectionCuts(JSON.parse(atob('#{b64}')))") rescue nil
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

  # Subscribe to event bus — refresh dashboard when categories change
  subscribe(EVENT_CATEGORIES_CHANGED) do |_payload|
    if Dashboard.visible?
      Dashboard.send_data(scan_results, category_assignments, cost_code_assignments)
    end
  end

  subscribe(EVENT_VISIBILITY_CHANGED) do |_payload|
    Dashboard.send_vis_state
    IdentifyDialog.send_vis_state rescue nil
  end
end
