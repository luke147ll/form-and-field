require 'set'

module TakeoffTool
  module HyperParser
    @dialog = nil
    @preview_active = false
    @sample_state = nil
    @hp_selected_eids = []
    @hp_pre_hidden = nil  # eids hidden before HP touched visibility

    SAMPLE_BATCH_SIZE = 50

    # ─── Color Sampler Tool ───
    # One-shot pick tool: user clicks an entity, we grab its material color
    # and send it back to the dialog so the matching group auto-checks.
    class ColorSamplerTool
      def initialize(callback)
        @callback = callback
      end

      def activate
        Sketchup.status_text = "Hyper Parse: Click an entity to sample its color"
      end

      def deactivate(view)
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        entity = ph.best_picked
        return unless entity

        mat = nil
        if entity.respond_to?(:material) && entity.material
          mat = entity.material
        elsif entity.respond_to?(:definition)
          face = entity.definition.entities.grep(Sketchup::Face).first
          mat = face.material if face
        end

        if mat && mat.color
          c = mat.color
          hex = "#%02x%02x%02x" % [c.red, c.green, c.blue]
          name = mat.display_name
          @callback.call(hex, name)
        end

        # Deactivate after one pick
        Sketchup.active_model.select_tool(nil)
      end

      def onCancel(reason, view)
        Sketchup.active_model.select_tool(nil)
      end
    end

    # ─── Show / Close ───

    # Primary entry point — all launch points (menu, toolbar, dashboard) call this
    def self.show_dialog
      show
    end

    def self.show
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Hyper Parse",
        preferences_key: "HyperParseDash",
        width: 550, height: 650,
        left: 120, top: 100,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(PLUGIN_DIR, 'ui', 'hyper_parse.html'))

      @dialog.add_action_callback('requestCategories') do |_ctx|
        send_categories
      end

      @dialog.add_action_callback('parseByName') do |_ctx|
        parse_by_name
      end

      @dialog.add_action_callback('searchByName') do |_ctx, query_str|
        search_by_name(query_str.to_s.strip)
      end

      @dialog.add_action_callback('parseByColor') do |_ctx|
        parse_by_color
      end

      @dialog.add_action_callback('highlightGroup') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = (data['eids'] || []).map(&:to_i)
          highlight_group(eids)
        rescue => e
          puts "HyperParser: highlightGroup error: #{e.message}"
        end
      end

      @dialog.add_action_callback('clearPreview') do |_ctx|
        clear_preview
      end

      @dialog.add_action_callback('toggleEntityHighlight') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          add = data['add']
          if add
            highlight_single(eid)
            @hp_selected_eids << eid unless @hp_selected_eids.include?(eid)
          else
            unhighlight_single(eid)
            @hp_selected_eids.delete(eid)
          end
        rescue => e
          puts "HyperParser: toggleEntityHighlight error: #{e.message}"
        end
      end

      @dialog.add_action_callback('clearHpSelection') do |_ctx|
        clear_preview
        @hp_selected_eids = []
      end

      @dialog.add_action_callback('hpHideGroup') do |_ctx, json_str|
        begin
          capture_pre_hidden
          require 'json'
          eids = (JSON.parse(json_str.to_s)['eids'] || []).map(&:to_i)
          m = Sketchup.active_model; next unless m
          m.start_operation('HP Hide', true)
          eids.each do |eid|
            e = TakeoffTool.find_entity(eid)
            e.visible = false if e && e.valid?
          end
          m.commit_operation
        rescue => e
          puts "HyperParser: hpHideGroup error: #{e.message}"
        end
      end

      @dialog.add_action_callback('hpShowGroup') do |_ctx, json_str|
        begin
          require 'json'
          eids = (JSON.parse(json_str.to_s)['eids'] || []).map(&:to_i)
          m = Sketchup.active_model; next unless m
          m.start_operation('HP Show', true)
          visible = []
          eids.each do |eid|
            e = TakeoffTool.find_entity(eid)
            if e && e.valid?
              e.visible = true
              visible << e
            end
          end
          Highlighter.ensure_ancestors_visible(visible, m) if visible.any?
          m.commit_operation
        rescue => e
          puts "HyperParser: hpShowGroup error: #{e.message}"
        end
      end

      @dialog.add_action_callback('hpIsolateGroup') do |_ctx, json_str|
        begin
          capture_pre_hidden
          require 'json'
          iso_eids = (JSON.parse(json_str.to_s)['eids'] || []).map(&:to_i)
          iso_set = iso_eids.to_set
          pre = @hp_pre_hidden || Set.new
          sr = TakeoffTool.filtered_scan_results
          m = Sketchup.active_model; next unless m
          m.start_operation('HP Isolate', true)
          visible = []
          sr.each do |r|
            e = TakeoffTool.find_entity(r[:entity_id])
            next unless e && e.valid?
            next if pre.include?(r[:entity_id])  # don't touch pre-hidden
            if iso_set.include?(r[:entity_id])
              e.visible = true
              visible << e
            else
              e.visible = false
            end
          end
          Highlighter.ensure_ancestors_visible(visible, m) if visible.any?
          m.commit_operation
        rescue => e
          puts "HyperParser: hpIsolateGroup error: #{e.message}"
        end
      end

      @dialog.add_action_callback('hpShowAll') do |_ctx|
        begin
          pre = @hp_pre_hidden || Set.new
          sr = TakeoffTool.filtered_scan_results
          m = Sketchup.active_model; next unless m
          m.start_operation('HP Show All', true)
          visible = []
          sr.each do |r|
            e = TakeoffTool.find_entity(r[:entity_id])
            next unless e && e.valid?
            next if pre.include?(r[:entity_id])  # leave pre-hidden alone
            unless e.visible?
              e.visible = true
              visible << e
            end
          end
          Highlighter.ensure_ancestors_visible(visible, m) if visible.any?
          m.commit_operation
        rescue => e
          puts "HyperParser: hpShowAll error: #{e.message}"
        end
      end

      @dialog.add_action_callback('commitParse') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = (data['eids'] || []).map(&:to_i)
          cat = data['category'].to_s.strip
          subcat = data['subcategory'].to_s.strip
          rule_kw = data['ruleKeyword'].to_s.strip
          commit_parse(eids, cat, subcat, rule_kw)
        rescue => e
          puts "HyperParser: commitParse error: #{e.message}"
          send_commit_result(false, e.message)
        end
      end

      @dialog.add_action_callback('activateColorSampler') do |_ctx|
        activate_color_sampler
      end

      @dialog.add_action_callback('activateObjectSampler') do |_ctx|
        activate_object_sampler
      end

      @dialog.add_action_callback('findSimilar') do |_ctx, json_str|
        begin
          require 'json'
          filter_props = JSON.parse(json_str.to_s)
          find_similar_batched(filter_props)
        rescue => e
          puts "HyperParser: findSimilar error: #{e.message}"
        end
      end

      @dialog.add_action_callback('findSimilarCount') do |_ctx, json_str|
        begin
          require 'json'
          filter_props = JSON.parse(json_str.to_s)
          count = parse_by_sample(filter_props).length
          send_similar_count(count)
        rescue => e
          puts "HyperParser: findSimilarCount error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deactivateObjectSampler') do |_ctx|
        deactivate_object_sampler
      end

      @dialog.add_action_callback('commitSingle') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['category'].to_s.strip
          subcat = data['subcategory'].to_s.strip
          commit_parse([eid], cat, subcat)
        rescue => e
          puts "HyperParser: commitSingle error: #{e.message}"
          send_commit_result(false, e.message)
        end
      end

      @dialog.add_action_callback('addCustomCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        next if name.empty?
        TakeoffTool.add_custom_category(name)
        puts "Takeoff: HyperParser addCustomCategory '#{name}'"
      end

      @dialog.add_action_callback('addSubcategoryForCat') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          name = data['name'].to_s.strip
          TakeoffTool.add_subcategory(cat, name)
        rescue => e
          puts "HyperParser: addSubcategoryForCat error: #{e.message}"
        end
      end

      @dialog.set_on_closed { cleanup }
      @dialog.show
    end

    def self.close
      @dialog.close if @dialog && @dialog.visible?
    end

    # ─── Visibility Helpers ───

    def self.ancestors_visible?(entity)
      current = entity
      while current
        if current.respond_to?(:visible?) && !current.visible?
          return false
        end
        if current.respond_to?(:layer) && current.layer && !current.layer.visible?
          return false
        end

        parent = current.respond_to?(:parent) ? current.parent : nil
        break unless parent

        if parent.is_a?(Sketchup::ComponentDefinition)
          inst = parent.instances.first
          break unless inst
          current = inst
        elsif parent.is_a?(Sketchup::Model)
          break
        else
          current = parent
        end
      end
      true
    end

    def self.visible_scan_results
      sr = TakeoffTool.filtered_scan_results
      return [] unless sr
      sr.select do |r|
        e = TakeoffTool.find_entity(r[:entity_id])
        next false unless e && e.valid?
        next false unless e.visible?
        next false if e.respond_to?(:layer) && e.layer && !e.layer.visible?
        ancestors_visible?(e)
      end
    end

    # Snapshot which eids are already hidden before HP starts changing visibility.
    # Called once on first visibility action; preserved until cleanup.
    def self.capture_pre_hidden
      return if @hp_pre_hidden
      sr = TakeoffTool.filtered_scan_results
      return unless sr
      @hp_pre_hidden = Set.new
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id])
        next unless e && e.valid?
        @hp_pre_hidden.add(r[:entity_id]) unless e.visible?
      end
    end

    # ─── Parse Methods ───

    def self.parse_by_name
      results = visible_scan_results
      groups = {}
      results.each do |r|
        label = r[:display_name] || r[:definition_name] || 'Unknown'
        groups[label] ||= []
        groups[label] << r[:entity_id]
      end

      sorted = groups.map { |label, eids| { label: label, count: eids.length, eids: eids } }
                     .sort_by { |g| -g[:count] }

      send_parse_results('name', results.length, sorted)
    end

    def self.search_by_name(query)
      return send_parse_results('search', 0, []) if query.empty?
      results = visible_scan_results
      q = query.downcase
      groups = {}
      results.each do |r|
        label = r[:display_name] || r[:definition_name] || ''
        next unless label.downcase.include?(q)
        groups[label] ||= []
        groups[label] << r[:entity_id]
      end
      sorted = groups.map { |label, eids| { label: label, count: eids.length, eids: eids } }
                     .sort_by { |g| -g[:count] }
      send_parse_results('search', results.length, sorted)
    end

    def self.parse_by_color
      results = visible_scan_results
      groups = {}
      results.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id])
        next unless e && e.valid?

        mat = nil
        # Instance material first
        if e.respond_to?(:material) && e.material
          mat = e.material
        elsif e.respond_to?(:definition)
          # Fall back to first face material in definition
          face = e.definition.entities.grep(Sketchup::Face).first
          mat = face.material if face
        end

        if mat && mat.color
          c = mat.color
          hex = "#%02x%02x%02x" % [c.red, c.green, c.blue]
          label = mat.display_name
          key = "#{label}|#{hex}"
        else
          hex = nil
          label = "(No Material)"
          key = "_none"
        end

        groups[key] ||= { label: label, color: hex, eids: [] }
        groups[key][:eids] << r[:entity_id]
      end

      sorted = groups.values
                     .map { |g| { label: g[:label], color: g[:color], count: g[:eids].length, eids: g[:eids] } }
                     .sort_by { |g| -g[:count] }

      send_parse_results('color', results.length, sorted)
    end

    # ─── Highlight / Preview ───

    def self.highlight_group(eids)
      clear_preview
      ColorController.focus_entities(eids)
      @preview_active = true
    end

    def self.clear_preview
      return unless @preview_active
      ColorController.clear_focus
      @preview_active = false
    end

    def self.highlight_single(eid)
      ColorController.focus_entities([eid])
      @preview_active = true
    end

    def self.unhighlight_single(eid)
      m = Sketchup.active_model
      return unless m
      m.start_operation('HP Rem HL', true)
      ColorController.restore(eid)
      m.commit_operation
      @hp_selected_eids.delete(eid)
      @preview_active = @hp_selected_eids.any?
    end

    # ─── Commit ───

    def self.commit_parse(eids, category, subcategory, rule_keyword = '')
      return send_commit_result(false, "No category selected") if category.empty?
      return send_commit_result(false, "No entities selected") if eids.empty?

      clear_preview

      ca = TakeoffTool.category_assignments
      sr = TakeoffTool.scan_results
      count = 0

      eids.each do |eid|
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?

        ca[eid] = category
        TakeoffTool.save_assignment(eid, 'category', category)
        RecatLog.log_change(eid, category, subcategory.empty? ? nil : subcategory)

        TakeoffTool.save_assignment(eid, 'subcategory', subcategory)

        # Update scan result auto_category so dashboard stays consistent
        sr.each do |r|
          if r[:entity_id] == eid
            r[:parsed][:auto_category] = category
            r[:parsed][:auto_subcategory] = subcategory
            break
          end
        end

        count += 1
      end

      TakeoffTool.category_assignments = ca
      puts "HyperParser: Committed #{count} entities to '#{category}'"

      # Ensure category is in master list (keeps dropdowns in sync)
      TakeoffTool.add_category(category)
      if !subcategory.empty?
        TakeoffTool.add_subcategory(category, subcategory) rescue nil
      end

      # Learning system: capture from first entity with optional explicit keyword
      if eids.length > 0
        begin
          LearningSystem.capture(eids.first, 'Uncategorized', category,
            new_subcategory: subcategory.empty? ? nil : subcategory,
            rule_keyword: rule_keyword.empty? ? nil : rule_keyword)
        rescue => le
          puts "HyperParser learning capture error: #{le.message}"
        end
      end

      # Refresh all open dialogs (dashboard, HP, identify)
      TakeoffTool.broadcast_category_update

      send_commit_result(true, "#{count} entities → #{category}")
    end

    # ─── Color Sampler ───

    def self.activate_color_sampler
      callback = Proc.new do |hex, name|
        if @dialog && @dialog.visible?
          require 'json'
          js = JSON.generate({ hex: hex, name: name })
          esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
          @dialog.execute_script("receiveColorSample('#{esc}')")
        end
      end
      Sketchup.active_model.select_tool(ColorSamplerTool.new(callback))
    end

    # ─── Grab Selected (one-shot, no observer) ───

    def self.activate_object_sampler
      sel = Sketchup.active_model&.selection
      if sel && sel.length == 1
        entity = sel.first
        if entity && entity.valid?
          props = extract_entity_properties(entity)
          eid = entity.respond_to?(:entityID) ? entity.entityID : 0
          send_sampled_properties(eid, props)
          return
        end
      end
      # Nothing selected or multiple — tell JS
      send_no_selection
    end

    def self.deactivate_object_sampler
      # No-op — no observer or tool to deactivate
    end

    def self.extract_entity_properties(entity)
      props = []
      return props unless entity && entity.valid?

      eid = entity.respond_to?(:entityID) ? entity.entityID : nil

      # Definition name
      if entity.respond_to?(:definition)
        props << { key: 'Definition', value: entity.definition.name }
      end

      # Scan result parsed metadata
      if eid
        sr = TakeoffTool.filtered_scan_results
        if sr
          match = sr.find { |r| r[:entity_id] == eid }
          if match
            dn = match[:display_name] || match[:definition_name]
            props << { key: 'Display Name', value: dn } if dn && !dn.to_s.empty?
            p = match[:parsed] || {}
            props << { key: 'Element Type', value: p[:element_type] } if p[:element_type] && !p[:element_type].to_s.empty?
            props << { key: 'Function', value: p[:function] } if p[:function] && !p[:function].to_s.empty?
            props << { key: 'Tag', value: p[:tag] } if p[:tag] && !p[:tag].to_s.empty?
            props << { key: 'Size', value: p[:size] } if p[:size] && !p[:size].to_s.empty?
          end
        end
      end

      # Material — use original if entity is currently highlighted by ColorController
      mat = nil
      if entity.respond_to?(:material) && entity.material
        mat = entity.material
        if mat.respond_to?(:name) && mat.name.start_with?('FF_') && eid
          orig = ColorController.original_material(eid) rescue nil
          mat = orig unless orig.nil? && mat.nil?
        end
      elsif entity.respond_to?(:definition)
        face = entity.definition.entities.grep(Sketchup::Face).first
        mat = face.material if face
      end
      if mat
        props << { key: 'Material', value: mat.display_name }
        if mat.color
          c = mat.color
          hex = "#%02x%02x%02x" % [c.red, c.green, c.blue]
          props << { key: 'Color', value: hex, type: 'color' }
        end
      end

      # Layer
      if entity.respond_to?(:layer) && entity.layer
        props << { key: 'Layer', value: entity.layer.name }
      end

      # Model source (multiverse)
      if eid && TakeoffTool.active_mv_view
        ms_raw = (entity.get_attribute('FormAndField', 'model_source') rescue nil) || 'model_a'
        props << { key: 'Model Source', value: ms_raw == 'model_a' ? 'Model A' : 'Model B' }
      end

      # Entity type
      etype = entity.is_a?(Sketchup::ComponentInstance) ? 'Component' :
              entity.is_a?(Sketchup::Group) ? 'Group' : entity.class.name.split('::').last
      props << { key: 'Entity Type', value: etype }

      # Bounding box dimensions
      if entity.respond_to?(:bounds)
        bb = entity.bounds
        dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort.reverse
        props << { key: 'Width', value: "%.2f" % dims[0] }
        props << { key: 'Height', value: "%.2f" % dims[1] }
        props << { key: 'Depth', value: "%.2f" % dims[2] }
      end

      props
    end

    def self.parse_by_sample(filter_props)
      results = visible_scan_results
      matching_eids = []

      results.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id])
        next unless e && e.valid?

        entity_props = extract_entity_properties(e)
        prop_hash = {}
        entity_props.each { |pr| prop_hash[pr[:key]] = pr[:value] }

        match = true
        filter_props.each do |key, value|
          if prop_hash[key] != value
            match = false
            break
          end
        end

        matching_eids << r[:entity_id] if match
      end

      matching_eids
    end

    # ─── Batched Find Similar ───

    def self.find_similar_batched(filter_props)
      results = visible_scan_results
      @sample_state = {
        results: results,
        filter: filter_props,
        idx: 0,
        matching_eids: [],
        total: results.length,
        cat_counts: {}
      }
      send_search_progress(0, results.length, 0, {})
      process_sample_batch
    end

    def self.process_sample_batch
      state = @sample_state
      return unless state

      batch_end = [state[:idx] + SAMPLE_BATCH_SIZE, state[:results].length].min

      (state[:idx]...batch_end).each do |i|
        r = state[:results][i]
        e = TakeoffTool.find_entity(r[:entity_id])
        next unless e && e.valid?

        entity_props = extract_entity_properties(e)
        prop_hash = {}
        entity_props.each { |pr| prop_hash[pr[:key]] = pr[:value] }

        match = true
        state[:filter].each do |key, value|
          if prop_hash[key] != value
            match = false
            break
          end
        end

        if match
          state[:matching_eids] << r[:entity_id]
          cat = TakeoffTool.category_assignments[r[:entity_id]] ||
                (r[:parsed] && r[:parsed][:auto_category]) || 'Uncategorized'
          state[:cat_counts][cat] = (state[:cat_counts][cat] || 0) + 1
        end
      end

      state[:idx] = batch_end

      if state[:idx] >= state[:results].length
        send_sample_matches(state[:matching_eids])
        @sample_state = nil
      else
        send_search_progress(state[:idx], state[:total], state[:matching_eids].length, state[:cat_counts])
        UI.start_timer(0.01, false) { process_sample_batch }
      end
    end

    # ─── Cleanup ───

    def self.cleanup
      clear_preview
      # Restore only entities that HP itself hid — leave pre-hidden alone
      begin
        pre = @hp_pre_hidden || Set.new
        sr = TakeoffTool.filtered_scan_results
        m = Sketchup.active_model
        if m && sr && sr.any?
          m.start_operation('HP Cleanup', true)
          visible = []
          sr.each do |r|
            next if pre.include?(r[:entity_id])
            e = TakeoffTool.find_entity(r[:entity_id])
            if e && e.valid? && !e.visible?
              e.visible = true
              visible << e
            end
          end
          Highlighter.ensure_ancestors_visible(visible, m) if visible.any?
          m.commit_operation
        end
      rescue => e
        puts "HyperParser cleanup restore error: #{e.message}"
      end
      @hp_pre_hidden = nil
      @hp_selected_eids = []
      @sample_state = nil
      @dialog = nil
    end

    private

    # ─── JS Communication Helpers ───

    def self.send_parse_results(method, total_visible, groups)
      return unless @dialog && @dialog.visible?
      require 'json'
      payload = { method: method, total_visible: total_visible, groups: groups }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveParseResults('#{esc}')")
    end

    def self.send_categories
      return unless @dialog && @dialog.visible?
      require 'json'
      cats = TakeoffTool.master_categories.reject { |c| c == '_IGNORE' }
      containers = TakeoffTool.master_containers || []
      payload = { categories: cats, subcategories: TakeoffTool.master_subcategories, containers: containers }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveCategories('#{esc}')")
    end

    def self.send_commit_result(success, message)
      return unless @dialog && @dialog.visible?
      require 'json'
      js = JSON.generate({ success: success, message: message })
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveCommitResult('#{esc}')")
    end

    def self.send_sampled_properties(eid, props)
      return unless @dialog && @dialog.visible?
      require 'json'
      # Include current category assignment
      cat = TakeoffTool.category_assignments[eid]
      unless cat
        sr = TakeoffTool.filtered_scan_results
        match = sr&.find { |r| r[:entity_id] == eid }
        cat = match[:parsed][:auto_category] if match && match[:parsed]
      end
      cat ||= 'Uncategorized'
      sub = nil
      e = TakeoffTool.find_entity(eid)
      sub = (e.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) if e
      payload = { entity_id: eid, properties: props, category: cat, subcategory: sub || '' }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveSampledProperties('#{esc}')")
    end

    def self.send_no_selection
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("receiveNoSelection()")
    end

    def self.send_sample_matches(eids)
      return unless @dialog && @dialog.visible?
      require 'json'
      payload = { count: eids.length, eids: eids }
      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveSampleMatches('#{esc}')")
    end

    def self.send_similar_count(count)
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("receiveSimilarCount(#{count})")
    end

    def self.send_search_progress(processed, total, matches, cat_counts)
      return unless @dialog && @dialog.visible?
      require 'json'
      payload = { processed: processed, total: total, matches: matches, cat_counts: cat_counts }
      js = JSON.generate(payload)
      @dialog.execute_script("updateSearchProgress(#{js})")
    end

    # hp_mat removed — delegated to ColorController
  end
end
