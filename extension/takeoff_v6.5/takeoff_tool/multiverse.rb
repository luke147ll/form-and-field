module TakeoffTool

  # ═══ MULTIVERSE — Model Comparison System ═══

  # Tag all existing scanned entities as model_a
  def self.tag_existing_as_model_a
    count = 0
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      existing = e.get_attribute('FormAndField', 'model_source')
      next if existing && !existing.empty?
      e.set_attribute('FormAndField', 'model_source', 'model_a')
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
      # Step 1: Tag all existing entities as model_a
      mv_loading('Tagging current model as A...', 15)
      tag_existing_as_model_a

      # Step 2: Create FF_Model_B layer/tag
      layer_b = model.layers['FF_Model_B'] || model.layers.add('FF_Model_B')

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

      # Step 6: Re-scan the model to pick up new entities
      mv_loading('Scanning combined model...', 75)
      puts "Multiverse: Imported #{b_count} entities from #{basename}, rescanning..."
      @scan_results, @entity_registry = Scanner.scan_model(model)
      load_saved_assignments
      load_custom_categories
      load_master_categories
      merge_scan_categories_into_master
      prune_empty_categories
      load_master_subcategories
      load_manual_measurements

      # Step 7: Tag new scan results without model_source as model_b
      mv_loading('Classifying Model B...', 88)
      tag_new_as_model_b(model_b_id)

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

  # Recursively tag entities and their nested children
  def self.tag_entities_recursive(entities, model_b_id, layer_b, &counter)
    entities.each do |e|
      next unless e.valid?
      if e.respond_to?(:set_attribute)
        e.set_attribute('FormAndField', 'model_source', model_b_id)
        e.layer = layer_b if e.respond_to?(:layer=)
        counter.call if counter
      end
      # Recurse into groups/components
      if e.is_a?(Sketchup::Group) && e.entities
        tag_entities_recursive(e.entities.to_a, model_b_id, layer_b, &counter)
      elsif e.is_a?(Sketchup::ComponentInstance) && e.definition && e.definition.entities
        # Don't recurse into component definitions (shared), just tag the instance
      end
    end
  end

  # Tag entities from re-scan that don't have a model_source yet as model_b
  def self.tag_new_as_model_b(model_b_id)
    count = 0
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      existing = e.get_attribute('FormAndField', 'model_source')
      next if existing && !existing.empty?
      # Check if entity is on FF_Model_B layer
      if e.respond_to?(:layer) && e.layer && e.layer.name == 'FF_Model_B'
        e.set_attribute('FormAndField', 'model_source', model_b_id)
        count += 1
      end
    end
    puts "Multiverse: Tagged #{count} new entities as model_b (#{model_b_id})"
  end

  # Set multiverse view mode: "a", "b", or "ab"
  def self.set_multiverse_view(mode)
    model = Sketchup.active_model
    return unless model

    layer_b = model.layers['FF_Model_B']
    mode = mode.to_s.downcase

    model.start_operation('Multiverse View', true)
    begin
      case mode
      when 'a'
        # Show Model A, hide Model B
        layer_b.visible = false if layer_b
        show_model_entities('model_a', true)
        Highlighter.clear_all

      when 'b'
        # Hide Model A, show Model B
        layer_b.visible = true if layer_b
        show_model_entities('model_a', false)
        Highlighter.clear_all

      when 'ab'
        # Show both with highlight colors
        layer_b.visible = true if layer_b
        show_model_entities('model_a', true)
        apply_multiverse_highlights

      else
        puts "Multiverse: Unknown view mode '#{mode}'"
      end

      model.commit_operation

      # Update stored active view
      if @multiverse_data
        @multiverse_data['active_view'] = mode
        save_multiverse_data
      end

      # Refresh dashboard
      Dashboard.send_multiverse_data if Dashboard.visible?

    rescue => e
      model.abort_operation
      puts "Multiverse: set_view error: #{e.message}"
    end
  end

  # Show/hide all entities belonging to a specific model source
  def self.show_model_entities(source_prefix, visible)
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      ms = e.get_attribute('FormAndField', 'model_source')
      next unless ms
      if source_prefix == 'model_a'
        e.visible = visible if ms == 'model_a'
      end
    end
  end

  # Apply A=green / B=blue highlights in "ab" mode
  def self.apply_multiverse_highlights
    model = Sketchup.active_model
    return unless model

    mat_a = model.materials['FF_MV_ModelA']
    unless mat_a
      mat_a = model.materials.add('FF_MV_ModelA')
      mat_a.color = Sketchup::Color.new(166, 227, 161, 128) # green with alpha
      mat_a.alpha = 0.5
    end

    mat_b = model.materials['FF_MV_ModelB']
    unless mat_b
      mat_b = model.materials.add('FF_MV_ModelB')
      mat_b.color = Sketchup::Color.new(137, 180, 250, 128) # blue with alpha
      mat_b.alpha = 0.5
    end

    @entity_registry.each do |eid, e|
      next unless e && e.valid? && e.respond_to?(:material=)
      ms = e.get_attribute('FormAndField', 'model_source')
      next unless ms
      if ms == 'model_a'
        Highlighter.apply_highlight(e, eid, mat_a)
      else
        Highlighter.apply_highlight(e, eid, mat_b)
      end
    end
  end

  # Remove the comparison model (Model B)
  def self.remove_comparison_model
    model = Sketchup.active_model
    return unless model

    result = UI.messagebox("Remove comparison model? This will delete all Model B entities.", MB_YESNO)
    return unless result == IDYES

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
      layer_b = model.layers['FF_Model_B']
      if layer_b
        # Move any remaining entities off this layer first
        default_layer = model.layers[0]
        model.entities.each do |e|
          e.layer = default_layer if e.valid? && e.respond_to?(:layer) && e.layer == layer_b
        end
        model.layers.remove(layer_b, true)
      end

      # Remove multiverse highlight materials
      ['FF_MV_ModelA', 'FF_MV_ModelB'].each do |mname|
        mat = model.materials[mname]
        model.materials.remove(mat) if mat
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
