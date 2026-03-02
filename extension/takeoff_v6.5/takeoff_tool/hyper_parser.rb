module TakeoffTool
  module HyperParser
    @dialog = nil
    @orig_instance = {}   # eid => original material (for preview restore)
    @hp_mats = {}         # name => Sketchup::Material
    @preview_active = false

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

      @dialog.add_action_callback('commitParse') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = (data['eids'] || []).map(&:to_i)
          cat = data['category'].to_s.strip
          subcat = data['subcategory'].to_s.strip
          commit_parse(eids, cat, subcat)
        rescue => e
          puts "HyperParser: commitParse error: #{e.message}"
          send_commit_result(false, e.message)
        end
      end

      @dialog.add_action_callback('activateColorSampler') do |_ctx|
        activate_color_sampler
      end

      @dialog.add_action_callback('addCustomCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        next if name.empty?
        TakeoffTool.add_custom_category(name)
        puts "Takeoff: HyperParser addCustomCategory '#{name}'"
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
      sr = TakeoffTool.scan_results
      return [] unless sr
      sr.select do |r|
        e = TakeoffTool.find_entity(r[:entity_id])
        next false unless e && e.valid?
        next false unless e.visible?
        next false if e.respond_to?(:layer) && e.layer && !e.layer.visible?
        ancestors_visible?(e)
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
      m = Sketchup.active_model
      return unless m

      clear_preview

      m.start_operation('HP Preview', true)
      @preview_active = true

      bright = hp_mat(m, 'TO_HP_bright', [203, 166, 247], 0.9)
      dim    = hp_mat(m, 'TO_HP_dim', [69, 71, 90], 0.3)

      eid_set = {}
      eids.each { |id| eid_set[id] = true }

      # Paint all visible scan results: bright for selected, dim for others
      visible_scan_results.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id])
        next unless e && e.valid?
        eid = r[:entity_id]
        @orig_instance[eid] = e.material
        e.material = eid_set[eid] ? bright : dim
      end

      m.commit_operation
    end

    def self.clear_preview
      return unless @preview_active
      m = Sketchup.active_model
      return unless m

      m.start_operation('HP Clear', true)

      @orig_instance.each do |eid, orig_mat|
        e = TakeoffTool.find_entity(eid)
        if e && e.valid?
          begin; e.material = orig_mat; rescue; end
        end
      end
      @orig_instance.clear

      @hp_mats.each do |_, mt|
        begin; m.materials.remove(mt) if mt && mt.valid?; rescue; end
      end
      @hp_mats.clear

      @preview_active = false
      m.commit_operation
    end

    # ─── Commit ───

    def self.commit_parse(eids, category, subcategory)
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

        if !subcategory.empty?
          TakeoffTool.save_assignment(eid, 'subcategory', subcategory)
        end

        # Update scan result auto_category so dashboard stays consistent
        sr.each do |r|
          if r[:entity_id] == eid
            r[:parsed][:auto_category] = category
            r[:parsed][:auto_subcategory] = subcategory unless subcategory.empty?
            break
          end
        end

        count += 1
      end

      TakeoffTool.category_assignments = ca
      puts "HyperParser: Committed #{count} entities to '#{category}'"

      # Refresh dashboard if open
      if Dashboard.visible?
        Dashboard.send_data(sr, ca, TakeoffTool.cost_code_assignments)
      end

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

    # ─── Cleanup ───

    def self.cleanup
      clear_preview
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
      cats = TakeoffTool.build_context_categories.reject { |c| c == '_IGNORE' }
      js = JSON.generate(cats)
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

    def self.hp_mat(m, name, rgb, alpha)
      mt = @hp_mats[name]
      unless mt
        mt = m.materials.add(name)
        mt.color = Sketchup::Color.new(*rgb)
        mt.alpha = alpha
        @hp_mats[name] = mt
      end
      mt
    end
  end
end
