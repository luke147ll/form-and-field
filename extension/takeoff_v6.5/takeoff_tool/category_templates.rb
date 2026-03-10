module TakeoffTool
  module CategoryTemplates
    TEMPLATES_DIR = File.join(PLUGIN_DIR, 'data', 'templates')
    @dialog = nil
    @pending_definition_map = nil  # Set during template apply, consumed after scan

    def self.ensure_dir
      Dir.mkdir(TEMPLATES_DIR) unless File.directory?(TEMPLATES_DIR)
    end

    def self.list
      ensure_dir
      Dir.glob(File.join(TEMPLATES_DIR, '*.json')).map do |f|
        File.basename(f, '.json')
      end.sort_by(&:downcase)
    end

    def self.save_template(name)
      return false if name.nil? || name.strip.empty?
      name = name.strip.gsub(/[^a-zA-Z0-9_\-\s]/, '').strip
      return false if name.empty?

      ensure_dir

      # Ensure in-memory data is loaded from model (survives code reloads)
      containers = TakeoffTool.master_containers || []
      if containers.empty?
        TakeoffTool.load_master_containers
        containers = TakeoffTool.master_containers || []
      end
      rules = LearningSystem.load_rules || []

      # Ensure scan results are loaded — needed for definition_map
      sr = TakeoffTool.scan_results || []
      if sr.empty?
        TakeoffTool.load_saved_assignments
        sr = TakeoffTool.scan_results || []
      end

      # Build definition_map: definition_name → {category, subcategory, cost_code}
      # Captures the EFFECTIVE category for ALL entities — both user-assigned
      # and scanner-auto-categorized. This is the complete picture of how
      # the organized model looks.
      definition_map = {}
      ca = TakeoffTool.category_assignments || {}
      cc = TakeoffTool.cost_code_assignments || {}
      sr.each do |r|
        defn_name = r[:definition_name].to_s
        next if defn_name.empty?
        # Effective category: user assignment wins, then scanner auto_category
        cat = ca[r[:entity_id]]
        cat = r[:parsed][:auto_category] if cat.nil? || cat.empty?
        next unless cat && !cat.empty? && cat != 'Uncategorized' && cat != '_IGNORE'
        # Only store one mapping per definition (all instances share it)
        # But user assignments override auto-categorized entries
        if definition_map.key?(defn_name)
          # Keep existing if it was a user assignment; override if current is user assignment
          next unless ca[r[:entity_id]] && !ca[r[:entity_id]].empty?
        end
        # Look up subcategory from model attributes
        entity = TakeoffTool.entity_registry[r[:entity_id]]
        sub = entity ? (entity.get_attribute('TakeoffAssignments', 'subcategory') || '') : ''
        definition_map[defn_name] = {
          'category' => cat,
          'subcategory' => sub.to_s,
          'cost_code' => (cc[r[:entity_id]] || '').to_s
        }
      end

      require 'json'
      data = {
        'template_name' => name,
        'created' => Time.now.strftime('%Y-%m-%d %H:%M'),
        'containers' => containers,
        'rules' => rules,
        'definition_map' => definition_map
      }
      path = File.join(TEMPLATES_DIR, "#{name}.json")
      File.write(path, JSON.pretty_generate(data))
      puts "Takeoff: Saved template '#{name}' (#{containers.length} containers, #{definition_map.length} definitions, #{rules.length} rules)"
      true
    rescue => e
      puts "Takeoff: save_template error: #{e.message}"
      false
    end

    # Update an existing template — merges current model state into it.
    # Keeps all existing definition_map entries, adds new definitions found
    # in the current scan, and updates any definitions the user recategorized.
    # Containers and rules are fully replaced with current model state.
    def self.update_template(name)
      return false if name.nil? || name.strip.empty?
      ensure_dir
      path = File.join(TEMPLATES_DIR, "#{name.strip}.json")
      return false unless File.exist?(path)

      require 'json'
      old_data = JSON.parse(File.read(path))
      old_defn_map = old_data['definition_map'] || {}

      # Build current state (same logic as save_template)
      containers = TakeoffTool.master_containers || []
      if containers.empty?
        TakeoffTool.load_master_containers
        containers = TakeoffTool.master_containers || []
      end
      rules = LearningSystem.load_rules || []

      sr = TakeoffTool.scan_results || []
      if sr.empty?
        TakeoffTool.load_saved_assignments
        sr = TakeoffTool.scan_results || []
      end

      ca = TakeoffTool.category_assignments || {}
      cc = TakeoffTool.cost_code_assignments || {}

      # Start with the old definition_map — preserves entries for definitions
      # that may not exist in the current model revision
      merged_map = old_defn_map.dup
      added = 0
      updated = 0

      sr.each do |r|
        defn_name = r[:definition_name].to_s
        next if defn_name.empty?

        # Effective category
        cat = ca[r[:entity_id]]
        cat = r[:parsed][:auto_category] if cat.nil? || cat.empty?
        next unless cat && !cat.empty? && cat != 'Uncategorized' && cat != '_IGNORE'

        # Only store one mapping per definition; user assignments win
        if merged_map.key?(defn_name)
          # Only override if this is a user assignment (recategorized)
          next unless ca[r[:entity_id]] && !ca[r[:entity_id]].empty?
          old_cat = merged_map[defn_name]['category']
          next if old_cat == cat  # no change
          updated += 1
        else
          added += 1
        end

        entity = TakeoffTool.entity_registry[r[:entity_id]]
        sub = entity ? (entity.get_attribute('TakeoffAssignments', 'subcategory') || '') : ''
        merged_map[defn_name] = {
          'category' => cat,
          'subcategory' => sub.to_s,
          'cost_code' => (cc[r[:entity_id]] || '').to_s
        }
      end

      data = {
        'template_name' => name.strip,
        'created' => old_data['created'] || Time.now.strftime('%Y-%m-%d %H:%M'),
        'updated' => Time.now.strftime('%Y-%m-%d %H:%M'),
        'containers' => containers,
        'rules' => rules,
        'definition_map' => merged_map
      }
      File.write(path, JSON.pretty_generate(data))
      puts "Takeoff: Updated template '#{name}' — #{added} new defs, #{updated} changed, #{merged_map.length} total (was #{old_defn_map.length})"
      true
    rescue => e
      puts "Takeoff: update_template error: #{e.message}"
      false
    end

    def self.apply_template(name)
      return false if name.nil? || name.strip.empty?
      ensure_dir
      path = File.join(TEMPLATES_DIR, "#{name.strip}.json")
      return false unless File.exist?(path)

      require 'json'
      data = JSON.parse(File.read(path))
      containers = data['containers'] || []
      return false if containers.empty?

      m = Sketchup.active_model
      return false unless m

      m.start_operation('Apply Category Template', true)
      begin
        # Apply containers
        TakeoffTool.instance_variable_set(:@master_containers, containers)
        TakeoffTool.save_master_containers
        TakeoffTool.invalidate_container_lookup
        TakeoffTool.build_container_lookup

        # Sync master_categories from template containers
        cats = TakeoffTool.master_categories || []
        containers.each do |cont|
          (cont['categories'] || []).each do |c|
            cat_name = c['name']
            cats << cat_name unless cats.include?(cat_name)
          end
        end
        cats << 'Uncategorized' unless cats.include?('Uncategorized')
        cats << '_IGNORE' unless cats.include?('_IGNORE')
        TakeoffTool.instance_variable_set(:@master_categories, cats)
        TakeoffTool.sort_master_categories!
        TakeoffTool.save_master_categories

        # Sync cost codes
        containers.each do |cont|
          (cont['categories'] || []).each do |c|
            cat_name = c['name']
            code = c['code']
            next unless code && !code.empty?
            m.set_attribute('TakeoffCostCodes', cat_name, code)
          end
        end

        # Replace learned rules (not merge — template is source of truth)
        tpl_rules = data['rules'] || []
        if tpl_rules.length > 0
          LearningSystem.instance_variable_set(:@rules, tpl_rules)
          LearningSystem.save_rules
          puts "Takeoff: Replaced learned rules with #{tpl_rules.length} template rules"
        end

        # Store definition_map for post-scan application
        defn_map = data['definition_map'] || {}
        @pending_definition_map = defn_map unless defn_map.empty?
        puts "Takeoff: Queued #{defn_map.length} definition mappings for post-scan" unless defn_map.empty?

        m.commit_operation
        TakeoffTool.broadcast_category_update
        puts "Takeoff: Applied template '#{name}' (#{containers.length} containers)"
        true
      rescue => e
        m.abort_operation
        puts "Takeoff: apply_template error: #{e.message}"
        false
      end
    end

    # Called after scan completes — applies definition_map as category assignments
    # and detects NEW entities not in the template (additions/changes in the updated model)
    def self.apply_definition_map
      return 0 unless @pending_definition_map && !@pending_definition_map.empty?
      defn_map = @pending_definition_map
      @pending_definition_map = nil
      @new_entities = []

      sr = TakeoffTool.scan_results || []
      ca = TakeoffTool.category_assignments || {}
      cc = TakeoffTool.cost_code_assignments || {}
      m = Sketchup.active_model

      applied = 0
      sr.each do |r|
        defn_name = r[:definition_name].to_s
        next if defn_name.empty?
        mapping = defn_map[defn_name]

        unless mapping
          # This entity's definition is NOT in the template → it's new/changed
          @new_entities << {
            entity_id: r[:entity_id],
            display_name: r[:display_name],
            definition_name: defn_name,
            tag: r[:tag],
            ifc_type: r[:ifc_type],
            scanner_category: r[:parsed][:auto_category] || 'Uncategorized'
          }
          next
        end

        eid = r[:entity_id]
        next if ca[eid] && ca[eid] != 'Uncategorized'

        cat = mapping['category']
        next unless cat && !cat.empty?

        ca[eid] = cat
        cc[eid] = mapping['cost_code'] if mapping['cost_code'] && !mapping['cost_code'].empty?

        if m && mapping['subcategory'] && !mapping['subcategory'].empty?
          entity = TakeoffTool.entity_registry[eid]
          if entity && entity.valid?
            entity.set_attribute('TakeoffAssignments', 'subcategory', mapping['subcategory'])
          end
        end
        applied += 1
      end

      if applied > 0
        TakeoffTool.instance_variable_set(:@category_assignments, ca)
        TakeoffTool.instance_variable_set(:@cost_code_assignments, cc)
        # Sync all assigned categories into master list so dropdowns stay current
        TakeoffTool.merge_scan_categories_into_master
      end

      new_count = @new_entities.length
      puts "Takeoff: Definition map — #{applied} matched, #{new_count} new entities detected"

      # Log new entity summary by scanner category
      if new_count > 0
        by_cat = {}
        @new_entities.each do |ne|
          cat = ne[:scanner_category]
          by_cat[cat] ||= 0
          by_cat[cat] += 1
        end
        by_cat.sort_by { |_k, v| -v }.each do |cat, count|
          puts "  NEW: #{count}x #{cat}"
        end
      end

      applied
    end

    def self.pending_definition_map?
      @pending_definition_map && !@pending_definition_map.empty?
    end

    # Returns the list of new entities detected during the last template apply
    def self.new_entities
      @new_entities || []
    end

    def self.new_entity_count
      (@new_entities || []).length
    end

    def self.delete_template(name)
      return false if name.nil? || name.strip.empty?
      path = File.join(TEMPLATES_DIR, "#{name.strip}.json")
      return false unless File.exist?(path)
      File.delete(path)
      puts "Takeoff: Deleted template '#{name}'"
      true
    rescue => e
      puts "Takeoff: delete_template error: #{e.message}"
      false
    end

    def self.read_template(name)
      return nil if name.nil? || name.strip.empty?
      path = File.join(TEMPLATES_DIR, "#{name.strip}.json")
      return nil unless File.exist?(path)
      require 'json'
      JSON.parse(File.read(path))
    rescue => e
      puts "Takeoff: read_template error: #{e.message}"
      nil
    end

    def self.show_dialog
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field — Category Templates",
        preferences_key: "TakeoffCategoryTemplates",
        width: 560, height: 520,
        left: 200, top: 150,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.add_action_callback('getTemplates') do |_ctx|
        send_template_list
      end

      @dialog.add_action_callback('getCurrentContainers') do |_ctx|
        send_current_containers
      end

      @dialog.add_action_callback('saveTemplate') do |_ctx, name|
        name = name.to_s.strip
        if name.empty?
          @dialog.execute_script("showMsg('Enter a template name', 'error')") rescue nil
          next
        end
        if save_template(name)
          @dialog.execute_script("showMsg('Template saved!', 'success')") rescue nil
          send_template_list
        else
          @dialog.execute_script("showMsg('Failed to save template', 'error')") rescue nil
        end
      end

      @dialog.add_action_callback('applyTemplate') do |_ctx, name|
        name = name.to_s.strip
        if apply_template(name)
          @dialog.execute_script("showMsg('Applied!', 'success')") rescue nil
          send_current_containers
        else
          @dialog.execute_script("showMsg('Failed to apply template', 'error')") rescue nil
        end
      end

      @dialog.add_action_callback('deleteTemplate') do |_ctx, name|
        name = name.to_s.strip
        if delete_template(name)
          @dialog.execute_script("showMsg('Deleted!', 'success')") rescue nil
          send_template_list
        else
          @dialog.execute_script("showMsg('Failed to delete template', 'error')") rescue nil
        end
      end

      @dialog.add_action_callback('updateTemplate') do |_ctx, name|
        name = name.to_s.strip
        if update_template(name)
          @dialog.execute_script("showMsg('Template updated!', 'success')") rescue nil
          send_template_list
        else
          @dialog.execute_script("showMsg('Failed to update template', 'error')") rescue nil
        end
      end

      @dialog.add_action_callback('previewTemplate') do |_ctx, name|
        data = read_template(name.to_s.strip)
        if data
          require 'json'
          safe = JSON.generate(data).gsub('</') { '<\\/' }
          @dialog.execute_script("receivePreview(#{safe})") rescue nil
        end
      end

      @dialog.add_action_callback('setDefault') do |_ctx, name|
        name = name.to_s.strip
        Sketchup.write_default('FormAndField', 'default_template', name)
        @dialog.execute_script("showMsg('Default set!', 'success')") rescue nil
        send_template_list
      end

      @dialog.add_action_callback('clearDefault') do |_ctx|
        Sketchup.write_default('FormAndField', 'default_template', '')
        @dialog.execute_script("showMsg('Default cleared', 'success')") rescue nil
        send_template_list
      end

      html_path = File.join(PLUGIN_DIR, 'ui', 'category_templates.html')
      @dialog.set_file(html_path)
      @dialog.show

      UI.start_timer(0.5, false) do
        send_template_list
        send_current_containers
      end
    end

    def self.send_template_list
      return unless @dialog && @dialog.visible?
      require 'json'
      templates = list.map do |name|
        data = read_template(name)
        container_count = data ? (data['containers'] || []).length : 0
        cat_count = data ? (data['containers'] || []).sum { |c| (c['categories'] || []).length } : 0
        rule_count = data ? (data['rules'] || []).length : 0
        defn_count = data ? (data['definition_map'] || {}).length : 0
        {
          name: name,
          created: data ? data['created'] : '',
          updated: data ? (data['updated'] || '') : '',
          containers: container_count,
          categories: cat_count,
          rules: rule_count,
          definitions: defn_count
        }
      end
      default_name = Sketchup.read_default('FormAndField', 'default_template', '') || ''
      payload = { templates: templates, default_template: default_name }
      safe = JSON.generate(payload).gsub('</') { '<\\/' }
      @dialog.execute_script("receiveTemplates(#{safe})") rescue nil
    end

    def self.send_current_containers
      return unless @dialog && @dialog.visible?
      require 'json'
      containers = TakeoffTool.master_containers || []
      if containers.empty?
        TakeoffTool.load_master_containers
        containers = TakeoffTool.master_containers || []
      end
      cat_count = containers.sum { |c| (c['categories'] || []).length }
      rule_count = (LearningSystem.load_rules || []).length
      defn_count = (TakeoffTool.category_assignments || {}).count { |_k, v| v && v != 'Uncategorized' }
      payload = { containers: containers, category_count: cat_count, rule_count: rule_count, definition_count: defn_count }
      safe = JSON.generate(payload).gsub('</') { '<\\/' }
      @dialog.execute_script("receiveCurrentContainers(#{safe})") rescue nil
    end

    def self.auto_apply_default
      default_name = Sketchup.read_default('FormAndField', 'default_template', '') || ''
      return false if default_name.empty?
      path = File.join(TEMPLATES_DIR, "#{default_name}.json")
      return false unless File.exist?(path)
      puts "Takeoff: Auto-applying default template '#{default_name}'"
      apply_template(default_name)
    end
  end
end
