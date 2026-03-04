module TakeoffTool

  # ═══ MULTIVERSE — Model Comparison System ═══

  # Returns current multiverse view mode ('a', 'b', 'ab') or nil when inactive
  def self.active_mv_view
    return nil unless @multiverse_data && @multiverse_data['models'] && @multiverse_data['models'].length > 1
    @multiverse_data['active_view'] || 'a'
  end

  # Returns model B's ID string, or nil when inactive
  def self.model_b_id
    return nil unless @multiverse_data && @multiverse_data['models'] && @multiverse_data['models'].length > 1
    @multiverse_data['models'][1]['id']
  end

  # Scan results filtered to the active model view
  def self.filtered_scan_results
    view = active_mv_view
    return @scan_results unless view && view != 'ab'
    @scan_results.select do |r|
      e = @entity_registry[r[:entity_id]]
      ms = (e && e.valid?) ? (e.get_attribute('FormAndField', 'model_source') || 'model_a') : 'model_a'
      view == 'a' ? ms == 'model_a' : ms != 'model_a'
    end
  end

  # Master categories filtered to only those with entities in the current view
  def self.filtered_master_categories
    view = active_mv_view
    return master_categories unless view && view != 'ab'
    fsr = filtered_scan_results
    ca = @category_assignments || {}
    # Collect categories that have at least one entity in this view
    active_cats = {}
    fsr.each do |r|
      cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      active_cats[cat] = true
    end
    # Always keep custom categories, Uncategorized, and _IGNORE
    @master_categories.select do |c|
      active_cats[c] || c == 'Uncategorized' || c == '_IGNORE' || (@custom_categories || []).include?(c)
    end
  end

  # Master subcategories filtered to only those with entities in the current view
  def self.filtered_master_subcategories
    view = active_mv_view
    return master_subcategories unless view && view != 'ab'
    fsr = filtered_scan_results
    ca = @category_assignments || {}
    # Build subcategory hash from only filtered scan results
    result = {}
    fsr.each do |r|
      cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      sub = (find_entity(r[:entity_id])&.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || ''
      next if sub.empty?
      result[cat] ||= []
      result[cat] << sub unless result[cat].include?(sub)
    end
    # Sort each sub-array
    result.each { |_k, v| v.sort_by!(&:downcase) }
    result
  end

  # Tag all existing scanned entities as model_a
  def self.tag_existing_as_model_a(layer_a = nil)
    count = 0
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      existing = e.get_attribute('FormAndField', 'model_source')
      next if existing && !existing.empty?
      e.set_attribute('FormAndField', 'model_source', 'model_a')
      e.layer = layer_a if layer_a && e.respond_to?(:layer=)
      count += 1
    end
    puts "Multiverse: Tagged #{count} existing entities as model_a"
  end

  # Send loading overlay progress to the dashboard
  def self.mv_loading(status, percent)
    return unless Dashboard.visible?
    safe_status = status.to_s.gsub("\\", "\\\\").gsub("'", "\\\\'")
    Dashboard.instance_variable_get(:@dialog)&.execute_script(
      "updateMvLoading('#{safe_status}', #{percent})"
    ) rescue nil
  end

  def self.mv_loading_show(status = 'Initializing...')
    return unless Dashboard.visible?
    safe_status = status.to_s.gsub("\\", "\\\\").gsub("'", "\\\\'")
    Dashboard.instance_variable_get(:@dialog)&.execute_script(
      "showMvLoading('#{safe_status}')"
    ) rescue nil
  end

  def self.mv_loading_hide
    return unless Dashboard.visible?
    Dashboard.instance_variable_get(:@dialog)&.execute_script(
      "hideMvLoading()"
    ) rescue nil
  end

  # Import a comparison model (.skp or .ifc) as Model B
  def self.import_comparison_model
    model = Sketchup.active_model
    return UI.messagebox("No model open.") unless model

    path = UI.openpanel('Import Comparison Model', '', 'SketchUp Files|*.skp|IFC Files|*.ifc||')
    return unless path && File.exist?(path)

    basename = File.basename(path)
    mv_loading_show('Opening portal...')

    model.start_operation('Import Comparison Model', true)
    begin
      # Step 1: Tag all existing entities as model_a and assign to FF_Model_A layer
      mv_loading('Tagging current model as A...', 15)
      layer_a = model.layers['FF_Model_A'] || model.layers.add('FF_Model_A')
      layer_a.color = Sketchup::Color.new(166, 227, 161) # green
      tag_existing_as_model_a(layer_a)

      # Step 2: Create FF_Model_B layer/tag with color
      layer_b = model.layers['FF_Model_B'] || model.layers.add('FF_Model_B')
      layer_b.color = Sketchup::Color.new(137, 180, 250) # blue

      # Step 3: Load and insert the comparison model
      mv_loading("Loading #{basename}...", 35)
      defn = model.definitions.load(path)
      unless defn
        model.abort_operation
        mv_loading_hide
        UI.messagebox("Failed to load file: #{basename}")
        return
      end

      mv_loading('Placing Model B...', 50)
      inst = model.active_entities.add_instance(defn, ORIGIN)
      inst.layer = layer_b

      # Step 4: Explode to get individual entities
      exploded = inst.explode
      model_b_id = "model_b_#{Time.now.to_i}"

      # Step 5: Tag all exploded entities and assign to FF_Model_B layer
      mv_loading('Tagging Model B entities...', 60)
      b_count = 0
      tag_entities_recursive(exploded, model_b_id, layer_b) { b_count += 1 }

      model.commit_operation

      # Step 6: Tag new entities as model_b BEFORE scanning
      mv_loading('Classifying Model B...', 65)
      tag_new_as_model_b(model_b_id)

      # Step 7: Scan ONLY Model B entities — preserve Model A results untouched
      mv_loading('Scanning Model B entities...', 75)
      puts "Multiverse: Imported #{b_count} entities from #{basename}, scanning Model B only..."
      b_results, @entity_registry = Scanner.scan_model(
        model,
        model_source_filter: 'model_b',
        existing_results: nil,
        existing_reg: @entity_registry
      )
      # Append Model B scan results to existing Model A results
      @scan_results = (@scan_results || []) + b_results
      @scan_results.sort_by! { |r| [r[:tag] || 'zzz', r[:display_name] || ''] }

      mv_loading('Loading assignments...', 85)
      load_saved_assignments
      load_custom_categories
      load_master_categories
      merge_scan_categories_into_master
      prune_empty_categories
      load_master_subcategories
      load_manual_measurements

      # Step 8: Save multiverse data
      mv_loading('Comparing models...', 95)
      @multiverse_data = {
        'models' => [
          { 'id' => 'model_a', 'name' => 'Model A (Original)', 'source' => 'original' },
          { 'id' => model_b_id, 'name' => "Model B (#{basename})", 'source' => path }
        ],
        'active_view' => 'a'
      }
      save_multiverse_data

      # Step 9: Refresh dashboard
      mv_loading('Import complete!', 100)
      if Dashboard.visible?
        Dashboard.send_data(@scan_results, @category_assignments, @cost_code_assignments)
      end

      puts "Multiverse: Import complete — #{b_count} Model B entities added"

      # Delay hide so user sees the 100% state briefly
      UI.start_timer(1.0, false) { mv_loading_hide }

    rescue => e
      model.abort_operation
      mv_loading_hide
      puts "Multiverse: Import error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      UI.messagebox("Import error: #{e.message}")
    end
  end

  # Recursively tag entities and their nested children (deep traversal)
  # visited_defs prevents infinite loops on shared/circular definitions
  def self.tag_entities_recursive(entities, model_b_id, layer_b, visited_defs = nil, &counter)
    visited_defs ||= {}
    entities.each do |e|
      next unless e.valid?
      if e.respond_to?(:set_attribute)
        e.set_attribute('FormAndField', 'model_source', model_b_id)
        e.layer = layer_b if e.respond_to?(:layer=)
        counter.call if counter
      end
      # Recurse into groups and component definitions (deep)
      if e.is_a?(Sketchup::Group) && e.entities
        tag_entities_recursive(e.entities.to_a, model_b_id, layer_b, visited_defs, &counter)
      elsif e.is_a?(Sketchup::ComponentInstance) && e.definition
        defn = e.definition
        unless visited_defs[defn.object_id]
          visited_defs[defn.object_id] = true
          tag_entities_recursive(defn.entities.to_a, model_b_id, layer_b, visited_defs, &counter)
        end
      end
    end
  end

  # Tag entities that don't have a model_source yet as model_b.
  # Scans model definitions (not entity_registry) so it works before scanning.
  # Uses two passes: first by layer, then by checking if an instance lives
  # inside a definition that belongs to an already-tagged Model B parent.
  def self.tag_new_as_model_b(model_b_id)
    model = Sketchup.active_model
    return unless model
    count = 0

    # Pass 1: Tag untagged instances on FF_Model_B layer or in entity_registry
    (@entity_registry || {}).each do |eid, e|
      next unless e && e.valid?
      existing = e.get_attribute('FormAndField', 'model_source')
      next if existing && !existing.empty?
      if e.respond_to?(:layer) && e.layer && e.layer.name == 'FF_Model_B'
        e.set_attribute('FormAndField', 'model_source', model_b_id)
        count += 1
      end
    end

    # Pass 2: Find definitions that contain model_b-tagged instances,
    # then tag all entities inside those definitions (deep)
    model_b_defns = {}
    model.definitions.each do |defn|
      next if defn.image?
      defn.instances.each do |inst|
        next unless inst.valid?
        ms = inst.get_attribute('FormAndField', 'model_source')
        if ms && ms != 'model_a' && !ms.empty?
          # This definition has a Model B instance — tag all entities inside it
          model_b_defns[defn.object_id] = defn
        end
      end
    end

    # Recursively tag entities inside Model B definitions
    visited = {}
    model_b_defns.each_value do |defn|
      tag_untagged_in_definition(defn, model_b_id, visited) { count += 1 }
    end

    puts "Multiverse: Tagged #{count} new entities as model_b (#{model_b_id})"
  end

  # Tag all untagged entities inside a definition (and nested definitions) as model_b
  def self.tag_untagged_in_definition(defn, model_b_id, visited, &counter)
    return if visited[defn.object_id]
    visited[defn.object_id] = true
    defn.entities.each do |e|
      next unless e.valid?
      if e.respond_to?(:get_attribute)
        existing = e.get_attribute('FormAndField', 'model_source')
        if !existing || existing.empty?
          e.set_attribute('FormAndField', 'model_source', model_b_id) if e.respond_to?(:set_attribute)
          counter.call if counter
        end
      end
      if e.is_a?(Sketchup::ComponentInstance) && e.definition
        tag_untagged_in_definition(e.definition, model_b_id, visited, &counter)
      elsif e.is_a?(Sketchup::Group) && e.entities
        e.entities.each do |child|
          next unless child.valid? && child.respond_to?(:get_attribute)
          ex = child.get_attribute('FormAndField', 'model_source')
          if !ex || ex.empty?
            child.set_attribute('FormAndField', 'model_source', model_b_id) if child.respond_to?(:set_attribute)
            counter.call if counter
          end
          if child.is_a?(Sketchup::ComponentInstance) && child.definition
            tag_untagged_in_definition(child.definition, model_b_id, visited, &counter)
          end
        end
      end
    end
  end

  # Rescan only Model B entities, preserving Model A results
  def self.rescan_model_b
    model = Sketchup.active_model
    return unless model && active_mv_view

    Dashboard.scan_log_start
    Dashboard.scan_log_msg("Rescanning Model B entities only...")

    # Remove old Model B results from @scan_results
    @scan_results.reject! do |r|
      e = @entity_registry[r[:entity_id]]
      ms = (e && e.valid?) ? (e.get_attribute('FormAndField', 'model_source') || 'model_a') : 'model_a'
      ms != 'model_a'
    end
    # Remove old Model B entries from entity_registry
    b_eids = @entity_registry.select do |eid, e|
      e && e.valid? && (e.get_attribute('FormAndField', 'model_source') || 'model_a') != 'model_a'
    end.keys
    b_eids.each { |eid| @entity_registry.delete(eid) }

    # Scan only Model B entities, appending to existing registry
    b_results, @entity_registry = Scanner.scan_model(
      model,
      model_source_filter: 'model_b',
      existing_results: nil,
      existing_reg: @entity_registry
    ) do |msg|
      Dashboard.scan_log_msg(msg)
    end

    @scan_results = @scan_results + b_results
    @scan_results.sort_by! { |r| [r[:tag] || 'zzz', r[:display_name] || ''] }

    load_saved_assignments
    load_master_categories
    merge_scan_categories_into_master
    prune_empty_categories
    load_master_subcategories

    summary = "Model B rescan: #{b_results.length} entities"
    Dashboard.scan_log_end(summary)
    puts "Multiverse: #{summary}"

    if Dashboard.visible?
      Dashboard.send_data(@scan_results, @category_assignments, @cost_code_assignments)
    end
  end

  # Set multiverse view mode: "a", "b", or "ab"
  # Uses layer visibility + DisplayColorByLayer for comparison tinting.
  # No materials are painted — layer colors provide the A/B visual.
  def self.set_multiverse_view(mode)
    model = Sketchup.active_model
    return unless model

    mode = mode.to_s.downcase

    # Clear any active Highlighter colors first (own operation)
    Highlighter.clear_all

    # Update stored active view BEFORE visibility changes
    # so filtered_scan_results uses the correct view
    if @multiverse_data
      @multiverse_data['active_view'] = mode
      save_multiverse_data
    end

    layer_a = model.layers['FF_Model_A']
    layer_b = model.layers['FF_Model_B']

    model.start_operation('Multiverse View', true)
    begin
      # Reset ALL entity visibility to true — clears any isolate state
      # from the previous view. Layers will control which model is shown.
      @entity_registry.each_value { |e| e.visible = true if e && e.valid? }
      Highlighter.show_hierarchy(model.entities)

      case mode
      when 'a'
        layer_a.visible = true if layer_a
        layer_b.visible = false if layer_b
        model.rendering_options['DisplayColorByLayer'] = false

      when 'b'
        layer_a.visible = false if layer_a
        layer_b.visible = true if layer_b
        model.rendering_options['DisplayColorByLayer'] = false

      when 'ab'
        layer_a.visible = true if layer_a
        layer_b.visible = true if layer_b
        model.rendering_options['DisplayColorByLayer'] = true

      else
        puts "Multiverse: Unknown view mode '#{mode}'"
      end

      model.commit_operation

      # Refresh dashboard with filtered data for the new view
      if Dashboard.visible?
        Dashboard.send_data(filtered_scan_results, @category_assignments, @cost_code_assignments)
      end

    rescue => e
      model.abort_operation
      puts "Multiverse: set_view error: #{e.message}"
    end
  end

  # Show/hide all entities belonging to a specific model source.
  # Uses start_with? because Model B's model_source is "model_b_TIMESTAMP".
  def self.show_model_entities(source_prefix, visible)
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      ms = e.get_attribute('FormAndField', 'model_source')
      next unless ms
      e.visible = visible if ms.start_with?(source_prefix)
    end
  end

  # Remove the comparison model (Model B)
  def self.remove_comparison_model
    model = Sketchup.active_model
    return unless model

    result = UI.messagebox("Remove comparison model? This will delete all Model B entities.", MB_YESNO)
    return unless result == IDYES

    # Turn off color-by-layer before any changes
    model.rendering_options['DisplayColorByLayer'] = false

    model.start_operation('Remove Comparison Model', true)
    begin
      # Find and erase Model B entities
      erase_count = 0
      to_erase = []
      @entity_registry.each do |eid, e|
        next unless e && e.valid?
        ms = e.get_attribute('FormAndField', 'model_source')
        next unless ms && ms != 'model_a'
        to_erase << e
      end

      to_erase.each do |e|
        next unless e.valid?
        e.erase! rescue nil
        erase_count += 1
      end

      # Remove FF_Model_B layer
      default_layer = model.layers[0]
      layer_b = model.layers['FF_Model_B']
      if layer_b
        model.entities.each do |e|
          e.layer = default_layer if e.valid? && e.respond_to?(:layer) && e.layer == layer_b
        end
        model.layers.remove(layer_b, true)
      end

      # Move Model A entities back to default layer, remove FF_Model_A layer
      layer_a = model.layers['FF_Model_A']
      if layer_a
        model.entities.each do |e|
          e.layer = default_layer if e.valid? && e.respond_to?(:layer) && e.layer == layer_a
        end
        model.layers.remove(layer_a, true)
      end

      # Clear model_source from remaining entities
      @entity_registry.each do |eid, e|
        next unless e && e.valid?
        e.delete_attribute('FormAndField', 'model_source') rescue nil
      end

      model.commit_operation

      # Clear multiverse data
      @multiverse_data = nil
      model.delete_attribute('FormAndField', 'multiverse')

      # Re-filter scan results to remove B entries
      @scan_results.reject! do |r|
        e = @entity_registry[r[:entity_id]]
        !e || !e.valid?
      end

      # Clean entity registry
      @entity_registry.reject! { |eid, e| !e || !e.valid? }

      # Refresh dashboard
      if Dashboard.visible?
        Dashboard.send_data(@scan_results, @category_assignments, @cost_code_assignments)
      end

      puts "Multiverse: Removed #{erase_count} Model B entities"
      UI.messagebox("Comparison model removed. #{erase_count} entities deleted.")

    rescue => e
      model.abort_operation
      puts "Multiverse: Remove error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      UI.messagebox("Remove error: #{e.message}")
    end
  end

  # Save multiverse state to model attributes
  def self.save_multiverse_data
    model = Sketchup.active_model
    return unless model && @multiverse_data
    require 'json'
    model.set_attribute('FormAndField', 'multiverse', JSON.generate(@multiverse_data))
  end

  # Load multiverse state from model attributes
  def self.load_multiverse_data
    model = Sketchup.active_model
    return unless model
    json = model.get_attribute('FormAndField', 'multiverse')
    if json && !json.empty?
      require 'json'
      @multiverse_data = JSON.parse(json) rescue nil
    end
  end

  # Build comparison summary: group scan results by category x model_source
  def self.build_comparison_summary
    counts = {} # { category => { 'a' => count, 'b' => count } }

    (@scan_results || []).each do |r|
      cat = @category_assignments[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      next if cat == '_IGNORE'

      e = @entity_registry[r[:entity_id]]
      next unless e && e.valid?

      ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'
      is_a = (ms == 'model_a')

      counts[cat] ||= { 'a' => 0, 'b' => 0 }
      if is_a
        counts[cat]['a'] += 1
      else
        counts[cat]['b'] += 1
      end
    end

    summary = counts.map do |cat, c|
      diff = c['b'] - c['a']
      {
        'category' => cat,
        'countA' => c['a'],
        'countB' => c['b'],
        'diff' => diff
      }
    end

    summary.sort_by { |s| -s['diff'].abs }
  end

end
