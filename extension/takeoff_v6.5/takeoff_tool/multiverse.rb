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
  # Fast import: load + place only. Tagging + scanning deferred to "Rescan B".
  def self.import_comparison_model
    model = Sketchup.active_model
    return UI.messagebox("No model open.") unless model

    path = UI.openpanel('Import Comparison Model', '', 'SketchUp Files|*.skp|IFC Files|*.ifc||')
    return unless path && File.exist?(path)

    basename = File.basename(path)
    t_start = Time.now
    puts "[FF Import] Starting: #{basename} (#{(File.size(path) / 1024.0 / 1024.0).round(1)} MB)"
    mv_loading_show('Opening portal...')

    model.start_operation('Import Comparison Model', true)
    begin
      # Step 1: Tag existing entities as model_a + assign FF_Model_A layer
      t1 = Time.now
      mv_loading('Tagging current model as A...', 15)
      layer_a = model.layers['FF_Model_A'] || model.layers.add('FF_Model_A')
      layer_a.color = Sketchup::Color.new(166, 227, 161) # green
      tag_existing_as_model_a(layer_a)
      puts "[FF Import] Tag A: #{(Time.now - t1).round(1)}s"

      # Step 2: Create FF_Model_B layer
      layer_b = model.layers['FF_Model_B'] || model.layers.add('FF_Model_B')
      layer_b.color = Sketchup::Color.new(137, 180, 250) # blue

      # Step 3: Load the file as a definition
      t2 = Time.now
      mv_loading("Loading #{basename}...", 40)
      defn = model.definitions.load(path)
      unless defn
        model.abort_operation
        mv_loading_hide
        UI.messagebox("Failed to load file: #{basename}")
        return
      end
      puts "[FF Import] Load: #{(Time.now - t2).round(1)}s — #{defn.name}"

      # Step 4: Place as a single component — NO EXPLODE
      mv_loading('Placing Model B...', 70)
      inst = model.active_entities.add_instance(defn, ORIGIN)
      inst.layer = layer_b
      inst.name = 'FF_ModelB_Import'
      inst.set_attribute('FormAndField', 'model_source', 'model_b')
      inst.set_attribute('FormAndField', 'model_b_import', true)

      model_b_id = "model_b_#{Time.now.to_i}"

      model.commit_operation
      invalidate_entity_cache

      # Step 5: Save multiverse data (lightweight)
      mv_loading('Saving state...', 90)
      @multiverse_data = {
        'models' => [
          { 'id' => 'model_a', 'name' => 'Model A (Original)', 'source' => 'original' },
          { 'id' => model_b_id, 'name' => "Model B (#{basename})", 'source' => path }
        ],
        'active_view' => 'a',
        'needs_scan' => true
      }
      save_multiverse_data

      # Step 6: Refresh dashboard — no scan yet, just show multiverse controls
      mv_loading('Import complete — click Rescan B to classify', 100)

      if Dashboard.visible?
        Dashboard.send_live_data
        Dashboard.send_multiverse_data
      end

      total = (Time.now - t_start).round(1)
      puts "[FF Import] COMPLETE in #{total}s (scan deferred)"
      Sketchup.status_text = "Model B imported in #{total}s — click Rescan B to classify"

      UI.start_timer(1.5, false) { mv_loading_hide }

    rescue => e
      model.abort_operation
      mv_loading_hide
      puts "[FF Import] ERROR: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      UI.messagebox("Import error: #{e.message}")
    end
  end

  # Import wrappers — organizational containers that must be recursed into
  # even when they appear "shared" between Model A and B
  IMPORT_WRAPPER_RE = /Ifc(Project|Site|Building(Storey)?|Space)|\.rvt|\.ifc|FF_ModelB/i

  # Tag all Model B entities by walking DOWN from known roots.
  # After explode, top-level Model B entities are in active_entities with
  # model_source already set. This finds them and recurses into descendants.
  def self.tag_model_b_entities(model, model_b_id)
    layer_b = model.layers['FF_Model_B'] || model.layers.add('FF_Model_B')
    count = 0

    # Step 1: Find top-level entities already tagged as Model B (from explode)
    roots = model.active_entities.select do |e|
      (e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)) &&
      e.get_attribute('FormAndField', 'model_source') == model_b_id
    end

    # Step 2: Walk down from each root and tag ALL descendants
    visited = {}
    roots.each do |root|
      tag_descendants(root, model_b_id, layer_b, visited) { count += 1 }
    end

    puts "[FF Tag] Tagged #{count} Model B descendants from #{roots.length} roots"
    count
  end

  # Recursively tag descendants inside a component/group.
  # - Import wrappers (IFC/Revit containers): always recurse, tag children
  # - Shared definitions (used by both Model A and B): skip — scanner handles
  #   these via instance-level model_source check
  # - Model B-only definitions: recurse and tag children
  def self.tag_descendants(entity, model_b_id, layer_b, visited, &counter)
    defn = entity.respond_to?(:definition) ? entity.definition : nil
    defn ||= entity if entity.is_a?(Sketchup::Group)
    return unless defn
    return if visited[defn.object_id]
    visited[defn.object_id] = true

    # Import wrappers: always recurse — they're organizational, not geometry
    if defn.name =~ IMPORT_WRAPPER_RE
      puts "[FF Tag] Import wrapper '#{defn.name}' — force recursing"
      defn.entities.each do |child|
        next unless child.valid?
        if child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
          child.set_attribute('FormAndField', 'model_source', model_b_id)
          child.layer = layer_b
          counter.call if counter
          tag_descendants(child, model_b_id, layer_b, visited, &counter)
        end
      end
      return
    end

    # Check if this definition is shared with Model A
    shared = defn.instances.any? do |inst|
      next false unless inst.valid?
      ms = inst.get_attribute('FormAndField', 'model_source')
      ms.nil? || ms == 'model_a'
    end

    if shared
      # Don't enter — the INSTANCE is already tagged, so the scanner will
      # find it via model.definitions and the instance-level model_source check.
      puts "[FF Tag] Shared definition '#{defn.name}' — not entering (#{defn.instances.length} instances)"
      return
    end

    # Not shared — safe to tag children
    defn.entities.each do |child|
      next unless child.valid?
      if child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child.set_attribute('FormAndField', 'model_source', model_b_id)
        child.layer = layer_b
        counter.call if counter
        tag_descendants(child, model_b_id, layer_b, visited, &counter)
      end
    end
  end

  # Rescan only Model B entities, preserving Model A results.
  # Also handles first-time scan after import: explodes the Model B
  # component, tags entities, then scans.
  def self.rescan_model_b
    model = Sketchup.active_model
    return unless model

    # Allow rescan even if active_mv_view is nil — might be first scan after import
    unless active_mv_view || (@multiverse_data && @multiverse_data['models'] && @multiverse_data['models'].length > 1)
      puts "Multiverse: No Model B to scan"
      return
    end

    t_start = Time.now
    Dashboard.scan_log_start
    Dashboard.scan_log_msg("Preparing Model B scan...")

    # Invalidate smart diff cache — model is changing
    SmartDiff.invalidate_cache rescue nil

    # ── Step 0: If Model B is still a single import component, explode + tag it now ──
    import_inst = find_model_b_import(model)
    if import_inst
      t_explode = Time.now
      Dashboard.scan_log_msg("Exploding Model B import component...")
      layer_b = model.layers['FF_Model_B'] || model.layers.add('FF_Model_B')
      layer_b.color = Sketchup::Color.new(137, 180, 250)

      model_b_id = nil
      if @multiverse_data && @multiverse_data['models'] && @multiverse_data['models'].length > 1
        model_b_id = @multiverse_data['models'][1]['id']
      end
      model_b_id ||= "model_b_#{Time.now.to_i}"

      model.start_operation('Prepare Model B', true)
      exploded = import_inst.explode
      # Tag the top-level exploded entities
      top_count = 0
      exploded.each do |e|
        next unless e.valid?
        if e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          e.set_attribute('FormAndField', 'model_source', model_b_id)
          e.layer = layer_b
          top_count += 1
        end
      end
      model.commit_operation
      invalidate_entity_cache

      # Walk down from tagged roots to tag all descendants
      desc_count = tag_model_b_entities(model, model_b_id)

      b_count = top_count + desc_count
      puts "[FF Rescan] Explode + tag: #{(Time.now - t_explode).round(1)}s (#{top_count} top-level, #{desc_count} descendants)"
      Dashboard.scan_log_msg("Tagged #{b_count} Model B entities")

      # Clear the needs_scan flag
      if @multiverse_data
        @multiverse_data.delete('needs_scan')
        save_multiverse_data
      end
    else
      Dashboard.scan_log_msg("Rescanning Model B entities...")
    end

    # (debug logging removed — was iterating all definitions)

    # ── Step 1: Remove old Model B results ──
    @scan_results.reject! do |r|
      e = @entity_registry[r[:entity_id]]
      ms = (e && e.valid?) ? (e.get_attribute('FormAndField', 'model_source') || 'model_a') : 'model_a'
      ms != 'model_a'
    end
    b_eids = @entity_registry.select do |eid, e|
      e && e.valid? && (e.get_attribute('FormAndField', 'model_source') || 'model_a') != 'model_a'
    end.keys
    b_eids.each { |eid| @entity_registry.delete(eid) }

    # ── Step 2: Scan Model B entities ──
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

    # ── Step 3: Load pre-existing assignments from Model B entities ──
    # If Model B was pre-categorized in a separate FF session, its entities
    # will have TakeoffAssignments attributes baked into the .skp file.
    # Must run BEFORE geometry matching so matched entities are skipped.
    b_precat = 0
    b_presub = 0
    b_precc = 0
    b_results.each do |r|
      e = @entity_registry[r[:entity_id]]
      next unless e && e.valid?
      begin
        cat = e.get_attribute('TakeoffAssignments', 'category')
        if cat && !cat.to_s.empty?
          unless @category_assignments[r[:entity_id]]
            @category_assignments[r[:entity_id]] = cat
            b_precat += 1
          end
        end
        sub = e.get_attribute('TakeoffAssignments', 'subcategory')
        if sub && !sub.to_s.empty?
          b_presub += 1
        end
        cc = e.get_attribute('TakeoffAssignments', 'cost_code')
        if cc && !cc.to_s.empty?
          unless @cost_code_assignments[r[:entity_id]]
            @cost_code_assignments[r[:entity_id]] = cc
            b_precc += 1
          end
        end
        sz = e.get_attribute('TakeoffAssignments', 'size')
        if sz && !sz.to_s.empty?
          r[:parsed][:size_nominal] = sz
        end
      rescue => err
        puts "Multiverse: pre-cat load error eid=#{r[:entity_id]}: #{err.message}"
      end
    end
    if b_precat > 0
      puts "Multiverse: Imported #{b_precat} pre-existing category assignments from Model B"
      Dashboard.scan_log_msg("Found #{b_precat} pre-categorized entities in Model B")
    end

    # ── Apply pending template definition map to Model B entities ──
    if defined?(CategoryTemplates) && CategoryTemplates.pending_definition_map?
      Dashboard.scan_log_msg("Applying template definition map to Model B...")
      tpl_applied = CategoryTemplates.apply_definition_map
      tpl_new = CategoryTemplates.new_entity_count
      if tpl_applied > 0
        Dashboard.scan_log_msg("Template: #{tpl_applied} matched, #{tpl_new} new")
        puts "Multiverse: Template definition map — #{tpl_applied} matched, #{tpl_new} new"
      end
    end

    # ── Geometry matching (Model A reference → Model B reclassification) ──
    # Skips entities that already have pre-existing assignments
    if @category_assignments && @category_assignments.any?
      Dashboard.scan_log_msg("Matching Model B geometry against Model A reference...")
      puts "Multiverse: Building geometry reference from #{@category_assignments.keys.length} assignments"
      GeometryMatcher.build_reference_library(@scan_results, @category_assignments, @entity_registry)
      @pending_geometry_matches = GeometryMatcher.match_model_b(
        b_results, @scan_results, @category_assignments, @entity_registry
      )
      if @pending_geometry_matches
        puts "Multiverse: Geometry match results — total=#{@pending_geometry_matches[:total_matched]} auto=#{@pending_geometry_matches[:auto_count]} probable=#{@pending_geometry_matches[:probable_count]} low=#{@pending_geometry_matches[:low_count]} no_match=#{@pending_geometry_matches[:no_match_count]} skipped=#{@pending_geometry_matches[:skipped_count]}"
        if @pending_geometry_matches[:auto_count] > 0
          Dashboard.scan_log_msg("Geometry: #{@pending_geometry_matches[:auto_count]} auto, #{@pending_geometry_matches[:probable_count]} probable")
        end
      end
    else
      puts "Multiverse: Skipping geometry matching — no category assignments"
    end

    # Load any remaining saved assignments (Model A re-check + fallback)
    load_saved_assignments
    load_master_categories
    merge_scan_categories_into_master
    prune_empty_categories
    load_master_subcategories
    load_master_containers

    save_scan_to_model rescue nil

    total = (Time.now - t_start).round(1)
    pre_info = b_precat > 0 ? " (#{b_precat} pre-categorized)" : ""
    summary = "Model B scan: #{b_results.length} entities#{pre_info} in #{total}s"
    Dashboard.scan_log_end(summary)
    puts "Multiverse: #{summary}"

    if Dashboard.visible?
      Dashboard.send_data(@scan_results, @category_assignments, @cost_code_assignments)
      Dashboard.send_multiverse_data
    end

    # ── Show new entities banner if template detected new entities ──
    if defined?(CategoryTemplates) && CategoryTemplates.new_entity_count > 0
      new_ents = CategoryTemplates.new_entities
      by_cat = {}
      new_ents.each do |ne|
        cat = ne[:scanner_category] || 'Uncategorized'
        by_cat[cat] ||= []
        by_cat[cat] << ne[:display_name]
      end
      UI.start_timer(1.0, false) do
        Dashboard.send_new_entities_banner(new_ents.length, by_cat)
      end
    end

    # ── Show alignment review if geometry matches found ──
    if @pending_geometry_matches && @pending_geometry_matches[:total_matched] > 0
      GeometryMatcher.show_alignment_review(@pending_geometry_matches)
    end
  end

  # Find the unexploded Model B import component, or nil if already exploded
  def self.find_model_b_import(model)
    model.active_entities.each do |e|
      next unless e.valid? && e.is_a?(Sketchup::ComponentInstance)
      return e if e.get_attribute('FormAndField', 'model_b_import')
      return e if e.name == 'FF_ModelB_Import'
    end
    nil
  end

  # Set multiverse view mode: "a", "b", or "ab"
  # Uses layer visibility + DisplayColorByLayer for comparison tinting.
  # No materials are painted — layer colors provide the A/B visual.
  def self.set_multiverse_view(mode)
    model = Sketchup.active_model
    return unless model

    mode = mode.to_s.downcase

    # Clean up any active analysis mode — restore original materials and visibility
    if SmartDiff.active?
      SmartDiff.exit
    elsif ColorController.active_mode != :none
      ColorController.deactivate
    end

    # Clear any active Highlighter state (isolate tracking, not entity iteration)
    Highlighter.clear_isolate_state

    # Update stored active view BEFORE visibility changes
    # so filtered_scan_results uses the correct view
    if @multiverse_data
      @multiverse_data['active_view'] = mode
      save_multiverse_data
    end

    layer_a = model.layers['FF_Model_A']
    layer_b = model.layers['FF_Model_B']

    # Pure layer switching — no entity iteration needed.
    # All Model A entities are on FF_Model_A, all Model B on FF_Model_B.
    # Reset all entity-level visibility before switching views.
    # Split mode eye toggles set entity.visible = false directly;
    # without this reset those entities stay hidden in single-model views.
    model.start_operation('Switch View', true)
    show_model_entities('model_a', true)
    show_model_entities('model_b', true)

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

    # Confirmation handled by JS portal overlay

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
      invalidate_entity_cache

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
      Dashboard.portal_complete("#{erase_count} entities removed")

    rescue => e
      model.abort_operation
      puts "Multiverse: Remove error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      Dashboard.portal_error("Remove error: #{e.message}")
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

  # ═══ MODEL COMPARISON — Quantity Delta + Visual Diff ═══

  # Get world-space axis-aligned bounding box for an entity
  def self.get_world_bounds(ent)
    return nil unless ent && ent.valid?

    # Get the entity's local bounding box
    local_bb = if ent.respond_to?(:definition)
      ent.definition.bounds
    elsif ent.respond_to?(:bounds)
      ent.bounds
    else
      return nil
    end

    # Get the accumulated world transform
    world_t = get_accumulated_transform(ent)

    # Transform all 8 corners of the bounding box to world space
    corners = []
    min_pt = local_bb.min
    max_pt = local_bb.max

    [min_pt.x, max_pt.x].each do |x|
      [min_pt.y, max_pt.y].each do |y|
        [min_pt.z, max_pt.z].each do |z|
          corners << (world_t * Geom::Point3d.new(x, y, z))
        end
      end
    end

    wx = corners.map(&:x)
    wy = corners.map(&:y)
    wz = corners.map(&:z)

    wmin = [wx.min, wy.min, wz.min]
    wmax = [wx.max, wy.max, wz.max]

    {
      min: wmin, max: wmax,
      center: [(wmin[0]+wmax[0])/2.0, (wmin[1]+wmax[1])/2.0, (wmin[2]+wmax[2])/2.0],
      volume: (wmax[0]-wmin[0]) * (wmax[1]-wmin[1]) * (wmax[2]-wmin[2])
    }
  end

  # Walk up the parent chain to accumulate transforms into world space
  def self.get_accumulated_transform(ent)
    transform = ent.respond_to?(:transformation) ? ent.transformation : Geom::Transformation.new
    current = ent
    while current.parent.is_a?(Sketchup::ComponentDefinition)
      defn = current.parent
      inst = defn.instances.first
      break unless inst
      transform = inst.transformation * transform
      current = inst
    end
    transform
  end

  # Move an entity from inside a Model B component to model.active_entities (world level).
  # Returns the new entity (with a new entityID), or nil on failure.
  # The original entity is erased from its parent.
  def self.move_entity_to_active(ent, model)
    return nil unless ent && ent.valid?
    return nil unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

    begin
      layer_a = model.layers['FF_Model_A'] || model.layers.add('FF_Model_A')

      # Check if entity is already at the top level (no move needed).
      # After explode, entities land in active_entities — their parent is the Model.
      if ent.parent.is_a?(Sketchup::Model)
        puts "[FF Move] eid #{ent.entityID} already at top level, re-tagging only"
        ent.layer = layer_a
        ent.visible = true
        layer_a.visible = true
        # Fix internal geometry layers so they're visible when FF_Model_B is hidden
        fix_internal_layers(ent, layer_a)
        return ent
      end

      # Compute world-space transform
      local_origin = ent.transformation.origin.to_a.map { |v| v.to_f.round(1) }
      world_transform = get_accumulated_transform(ent)
      world_origin = world_transform.origin.to_a.map { |v| v.to_f.round(1) }
      defn_name = ent.respond_to?(:definition) ? ent.definition.name : 'Group'
      puts "[FF Move] eid #{ent.entityID} (#{defn_name}) local=#{local_origin} world=#{world_origin} parent=#{ent.parent.class}"

      if ent.is_a?(Sketchup::ComponentInstance)
        new_inst = model.active_entities.add_instance(ent.definition, world_transform)
      elsif ent.is_a?(Sketchup::Group)
        temp = ent.to_component
        new_inst = model.active_entities.add_instance(temp.definition, world_transform)
      end

      return nil unless new_inst

      # Copy all attributes from original
      if ent.attribute_dictionaries
        ent.attribute_dictionaries.each do |dict|
          dict.each_pair do |key, val|
            new_inst.set_attribute(dict.name, key, val) rescue nil
          end
        end
      end

      # Set instance layer + fix internal geometry layers.
      # Without this, faces/edges inside the definition stay on FF_Model_B,
      # making the entity invisible when FF_Model_B layer is hidden (view A).
      new_inst.layer = layer_a
      new_inst.visible = true
      layer_a.visible = true
      fix_internal_layers(new_inst, layer_a)

      new_pos = new_inst.transformation.origin.to_a.map { |v| v.to_f.round(1) }
      puts "[FF Move] → new eid #{new_inst.entityID} pos=#{new_pos} layer=#{new_inst.layer.name} vis=#{new_inst.visible?}"

      # Erase original from inside Model B component
      begin
        if ent.parent.is_a?(Sketchup::ComponentDefinition)
          ent.parent.entities.erase_entities(ent)
        else
          ent.erase!
        end
      rescue => err
        puts "[FF Move] erase failed: #{err.message}"
        begin; ent.visible = false; rescue; end
      end

      new_inst
    rescue => e
      puts "[FF Move] FAILED eid #{ent&.entityID}: #{e.message}"
      puts e.backtrace.first(3).join("\n")
      nil
    end
  end

  # Recursively change internal geometry from FF_Model_B to the target layer.
  # If the definition is shared with other instances, makes this one unique first.
  def self.fix_internal_layers(inst, target_layer)
    defn = inst.respond_to?(:definition) ? inst.definition : nil
    return unless defn

    # If definition is shared with other instances, make unique to avoid
    # changing layers on non-committed Model B entities.
    if defn.respond_to?(:instances) && defn.instances.length > 1
      inst.make_unique
      defn = inst.definition
    end

    count = relayer_recursive(defn.entities, target_layer, 'FF_Model_B')
    puts "[FF Move] Fixed #{count} internal entities from FF_Model_B → #{target_layer.name}" if count > 0
  rescue => e
    puts "[FF Move] fix_internal_layers error: #{e.message}"
  end

  # Walk a definition's entities, changing any on old_layer_name to target_layer.
  # Returns count of entities changed.
  def self.relayer_recursive(entities, target_layer, old_layer_name, visited = nil)
    visited ||= {}
    count = 0
    entities.each do |e|
      next unless e.valid?
      if e.respond_to?(:layer) && e.layer && e.layer.name == old_layer_name
        e.layer = target_layer
        count += 1
      end
      if e.is_a?(Sketchup::ComponentInstance) && e.definition
        d = e.definition
        unless visited[d.object_id]
          visited[d.object_id] = true
          # Make nested definition unique too if shared
          if d.instances.length > 1
            e.make_unique
            d = e.definition
          end
          count += relayer_recursive(d.entities, target_layer, old_layer_name, visited)
        end
      elsif e.is_a?(Sketchup::Group) && e.respond_to?(:entities)
        count += relayer_recursive(e.entities, target_layer, old_layer_name, visited)
      end
    end
    count
  end

  # Do two axis-aligned bounding boxes overlap on all three axes?
  def self.bb_overlap?(a, b)
    a[:min][0] < b[:max][0] && a[:max][0] > b[:min][0] &&
    a[:min][1] < b[:max][1] && a[:max][1] > b[:min][1] &&
    a[:min][2] < b[:max][2] && a[:max][2] > b[:min][2]
  end

  # Are two entities geometrically similar enough to be the same element?
  # Checks volume ratio and dimension proportions.
  def self.geometry_similar?(a, b)
    av = a[:solid_vol]; bv = b[:solid_vol]

    # Volume ratio: reject if one is more than 3x the other
    if av > 0 && bv > 0
      vol_ratio = av > bv ? av / bv : bv / av
      return false if vol_ratio > 3.0
    end

    # Dimension similarity: compare sorted BB dimensions
    # Each dimension must be within 2x of the other (allows for design changes)
    ad = a[:dims]; bd = b[:dims]
    if ad && bd && ad.length == 3 && bd.length == 3
      3.times do |i|
        next if ad[i] < 1.0 && bd[i] < 1.0  # skip near-zero dims
        larger = [ad[i], bd[i]].max
        smaller = [ad[i], bd[i]].min
        return false if smaller > 0 && larger / smaller > 2.0
      end
    end

    true
  end

  # How much do two BBs overlap? Returns 0.0–1.0 using IoU (Intersection over Union).
  # Naturally penalizes size mismatches: a small entity inside a large one scores low.
  def self.bb_overlap_ratio(a, b)
    x_inter = [0, [a[:max][0], b[:max][0]].min - [a[:min][0], b[:min][0]].max].max
    y_inter = [0, [a[:max][1], b[:max][1]].min - [a[:min][1], b[:min][1]].max].max
    z_inter = [0, [a[:max][2], b[:max][2]].min - [a[:min][2], b[:min][2]].max].max

    inter_vol = x_inter * y_inter * z_inter
    union_vol = a[:volume] + b[:volume] - inter_vol
    return 0.0 if union_vol <= 0
    inter_vol / union_vol
  end

  # ═══ SMART A+B DIFF — Spatial Classification ═══

  SMART_DIFF_CELL_SIZE = 24.0  # inches

  # Classify all entities into 4 states: matched, changed, new_b, removed_a
  # Returns Hash: { entity_id => :matched | :changed | :new_b | :removed_a }
  def self.classify_ab_entities
    sr = @scan_results || []
    ca = @category_assignments || {}
    reg = @entity_registry || {}

    # Step 1: Separate A and B entities with world bounds
    # Only include currently visible entities — hide categories to exclude from analysis
    a_items = []
    b_items = []

    sr.each do |r|
      e = reg[r[:entity_id]]
      next unless e && e.valid? && e.visible?
      ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'
      wb = get_world_bounds(e)
      next unless wb && wb[:volume] && wb[:volume] > 0

      cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      # Geometry data for matching: actual volume + sorted BB dimensions
      solid_vol = r[:volume_ft3] || 0.0
      dims = [r[:bb_width_in] || 0, r[:bb_height_in] || 0, r[:bb_depth_in] || 0].sort
      name = r[:parsed][:definition_name] || (e.respond_to?(:definition) ? e.definition.name : e.name) rescue '?'
      item = { eid: r[:entity_id], bounds: wb, category: cat,
               solid_vol: solid_vol, dims: dims, name: name }

      if ms == 'model_a'
        a_items << item
      else
        b_items << item
      end
    end

    puts "[FF SmartDiff] A=#{a_items.length} B=#{b_items.length}"

    # Diagnostic: log transform origin for first 5 A and 5 B entities
    [[:A, a_items], [:B, b_items]].each do |label, items|
      items.first(5).each do |item|
        e = reg[item[:eid]]
        next unless e && e.valid?
        wt = get_accumulated_transform(e)
        puts "[FF SD] #{label} '#{item[:name]}' cat=#{item[:category]} transform origin: #{wt.origin.to_a.map{|v|v.round(1)}} bounds min=#{item[:bounds][:min].map{|v|v.round(1)}} max=#{item[:bounds][:max].map{|v|v.round(1)}}"
      end
    end

    # Step 2: Build spatial hash grid from A entities
    grid = Hash.new { |h, k| h[k] = [] }
    a_items.each do |item|
      cells = cells_for_bounds(item[:bounds])
      cells.each { |cell| grid[cell] << item }
    end

    # Step 3: For each B entity, find best A overlap
    b_best_overlap = {}  # b_eid => { overlap_ratio:, a_eid: }
    a_has_overlap = {}   # a_eid => true (any B overlaps it)

    b_items.each do |b_item|
      cells = cells_for_bounds(b_item[:bounds])
      checked = {}
      best_ratio = 0.0
      best_a_eid = nil

      cells.each do |cell|
        (grid[cell] || []).each do |a_item|
          next if checked[a_item[:eid]]
          checked[a_item[:eid]] = true

          # Category gate — wall overlapping steel is not a match
          next unless a_item[:category] == b_item[:category]

          # Geometry gate — reject if volumes or dimensions are too different
          next unless geometry_similar?(a_item, b_item)

          next unless bb_overlap?(a_item[:bounds], b_item[:bounds])
          ratio = bb_overlap_ratio(a_item[:bounds], b_item[:bounds])

          if ratio > best_ratio
            best_ratio = ratio
            best_a_eid = a_item[:eid]
          end
        end
      end

      if best_ratio > 0.1
        b_best_overlap[b_item[:eid]] = { overlap_ratio: best_ratio, a_eid: best_a_eid }
        a_has_overlap[best_a_eid] = true if best_a_eid
      end
    end

    # Step 4: Reverse check — which A entities have B overlap
    b_grid = Hash.new { |h, k| h[k] = [] }
    b_items.each do |item|
      cells = cells_for_bounds(item[:bounds])
      cells.each { |cell| b_grid[cell] << item }
    end

    a_items.each do |a_item|
      next if a_has_overlap[a_item[:eid]]
      cells = cells_for_bounds(a_item[:bounds])
      cells.each do |cell|
        (b_grid[cell] || []).each do |b_item|
          # Category gate — only same-category overlaps count
          next unless b_item[:category] == a_item[:category]
          next unless geometry_similar?(a_item, b_item)
          if bb_overlap?(a_item[:bounds], b_item[:bounds])
            ratio = bb_overlap_ratio(a_item[:bounds], b_item[:bounds])
            if ratio > 0.1
              a_has_overlap[a_item[:eid]] = true
              break
            end
          end
        end
        break if a_has_overlap[a_item[:eid]]
      end
    end

    # Step 5: Classify
    result = {}

    a_items.each do |item|
      if a_has_overlap[item[:eid]]
        best = 0.0
        b_best_overlap.each_value do |info|
          best = info[:overlap_ratio] if info[:a_eid] == item[:eid] && info[:overlap_ratio] > best
        end
        result[item[:eid]] = best > 0.3 ? :matched : :changed
      else
        result[item[:eid]] = :removed_a
      end
    end

    b_items.each do |item|
      info = b_best_overlap[item[:eid]]
      if info
        result[item[:eid]] = info[:overlap_ratio] > 0.3 ? :matched : :changed
      else
        result[item[:eid]] = :new_b
      end
    end

    counts = { matched: 0, changed: 0, new_b: 0, removed_a: 0 }
    result.each_value { |v| counts[v] += 1 }
    puts "[FF SmartDiff] matched=#{counts[:matched]} changed=#{counts[:changed]} new_b=#{counts[:new_b]} removed_a=#{counts[:removed_a]}"

    # Diagnostic: log first 20 matched B entities with their A match details
    item_by_eid = {}
    (a_items + b_items).each { |it| item_by_eid[it[:eid]] = it }
    match_log_count = 0
    b_best_overlap.each do |b_eid, info|
      break if match_log_count >= 20
      next unless result[b_eid] == :matched
      b_it = item_by_eid[b_eid]
      a_it = item_by_eid[info[:a_eid]]
      next unless b_it && a_it
      puts "[FF SD Match] B:'#{b_it[:name]}' cat=#{b_it[:category]} overlaps A:'#{a_it[:name]}' cat=#{a_it[:category]} ratio=#{info[:overlap_ratio].round(3)}"
      puts "[FF SD Match]   B bounds: min=#{b_it[:bounds][:min].map{|v|v.round(1)}} max=#{b_it[:bounds][:max].map{|v|v.round(1)}}"
      puts "[FF SD Match]   A bounds: min=#{a_it[:bounds][:min].map{|v|v.round(1)}} max=#{a_it[:bounds][:max].map{|v|v.round(1)}}"
      match_log_count += 1
    end

    # Diagnostic: per-category classification breakdown
    cat_stats = Hash.new { |h, k| h[k] = { matched: 0, changed: 0, new_b: 0, removed_a: 0 } }
    (a_items + b_items).each do |item|
      state = result[item[:eid]]
      cat_stats[item[:category]][state] += 1 if state
    end
    cat_stats.sort_by { |cat, _| cat }.each do |cat, st|
      puts "[FF SD Cat] #{cat}: #{st[:matched]} matched, #{st[:changed]} changed, #{st[:new_b]} new_b, #{st[:removed_a]} removed_a"
    end

    # Store category for each classified entity (for category filtering)
    @ab_categories = {}
    (a_items + b_items).each { |item| @ab_categories[item[:eid]] = item[:category] }

    @ab_classification = result
    @ab_counts = counts
    result
  end

  # Grid cell keys for a world bounding box
  def self.cells_for_bounds(wb)
    cs = SMART_DIFF_CELL_SIZE
    cells = []
    x0 = (wb[:min][0] / cs).floor
    x1 = (wb[:max][0] / cs).floor
    y0 = (wb[:min][1] / cs).floor
    y1 = (wb[:max][1] / cs).floor
    z0 = (wb[:min][2] / cs).floor
    z1 = (wb[:max][2] / cs).floor

    (x0..x1).each do |x|
      (y0..y1).each do |y|
        (z0..z1).each do |z|
          cells << "#{x}_#{y}_#{z}"
        end
      end
    end
    cells
  end

  def self.ab_classification
    @ab_classification
  end

  def self.ab_counts
    @ab_counts
  end

  def self.ab_categories
    @ab_categories
  end

  # ═══ PART 1 — QUANTITY DELTA ═══

  # Extract the primary quantity from a scan result based on measurement type.
  def self.primary_quantity(r, mt)
    case mt
    when 'ea', 'ea_bf', 'ea_sf' then 1.0
    when 'lf'          then (r[:linear_ft] || 0.0).to_f
    when 'sf', 'sf_cy', 'sf_sheets' then (r[:area_sf] || 0.0).to_f
    when 'cy'          then (r[:volume_ft3] || 0.0).to_f / 27.0
    when 'volume'      then (r[:volume_ft3] || 0.0).to_f
    when 'bf'          then (r[:volume_bf] || 0.0).to_f
    else 1.0
    end
  end

  # Display label for a measurement type
  def self.unit_label(mt)
    case mt
    when 'ea', 'ea_bf', 'ea_sf' then 'EA'
    when 'lf'          then 'LF'
    when 'sf'          then 'SF'
    when 'sf_cy'       then 'CY'
    when 'sf_sheets'   then 'SF'
    when 'cy'          then 'CY'
    when 'volume'      then 'CF'
    when 'bf'          then 'BF'
    else 'EA'
    end
  end

  # Compute quantity deltas for ALL categories across Model A and Model B.
  # Synchronous — typically <50ms. Stores results in @comparison_results.
  def self.compute_quantity_delta
    sr = @scan_results || []
    ca = @category_assignments || {}
    reg = @entity_registry || {}

    accum = Hash.new { |h, k| h[k] = { a_qty: 0.0, a_count: 0, b_qty: 0.0, b_count: 0, mt: nil } }

    sr.each do |r|
      e = reg[r[:entity_id]]
      next unless e && e.valid?
      cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      next if cat == '_IGNORE'
      ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'

      mt = r[:parsed][:measurement_type] || Parser.measurement_for(cat)
      mt_ovr = Sketchup.active_model.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
      mt = mt_ovr if mt_ovr && !mt_ovr.empty?
      accum[cat][:mt] ||= mt

      qty = primary_quantity(r, mt)
      if ms == 'model_a'
        accum[cat][:a_qty] += qty; accum[cat][:a_count] += 1
      else
        accum[cat][:b_qty] += qty; accum[cat][:b_count] += 1
      end
    end

    @comparison_results = accum.map do |cat, d|
      delta = d[:b_qty] - d[:a_qty]
      pct = d[:a_qty] > 0 ? (delta / d[:a_qty] * 100.0) : (d[:b_qty] > 0 ? 999.9 : 0.0)
      {
        category: cat, unit: unit_label(d[:mt]),
        qty_a: d[:a_qty].round(2), qty_b: d[:b_qty].round(2),
        delta: delta.round(2),
        pct_change: pct.finite? ? pct.round(1) : (delta > 0 ? 999.9 : -999.9),
        count_a: d[:a_count], count_b: d[:b_count]
      }
    end.sort_by { |r| -r[:pct_change].abs }

    puts "[FF Compare] Quantity delta: #{@comparison_results.length} categories computed"
    @comparison_results
  end

  # ═══ PART 2 — SEMI-TRANSPARENT OVERLAY DIFF ═══

  DIFF_BATCH_SIZE = 50       # entities per async batch
  DIFF_COLOR_A    = [166, 227, 161]  # green  #a6e3a1
  DIFF_COLOR_B    = [137, 180, 250]  # blue   #89b4fa
  DIFF_ALPHA      = 100              # out of 255 (~39% opacity)

  # Start async overlay diff. Collects entities by model_source, creates
  # 2 materials, then applies in batches of 50 via UI.start_timer(0.01).
  def self.compute_visual_diff
    sr = @scan_results || []
    ca = @category_assignments || {}
    reg = @entity_registry || {}

    # Clean up any existing diff state first
    remove_diff_highlights if @diff_active
    ColorController.diff_orig_mats = nil

    puts "[FF Diff] Starting overlay diff..."

    # Collect entities by model source — no spatial analysis needed
    work_queue = []
    sr.each do |r|
      e = reg[r[:entity_id]]
      next unless e && e.valid?
      cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      next if cat == '_IGNORE'
      ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'
      work_queue << { eid: r[:entity_id], model: (ms == 'model_a') ? :a : :b }
    end

    puts "[FF Diff] Work queue: #{work_queue.length} entities"

    create_diff_materials
    ColorController.diff_orig_mats ||= {}

    model = Sketchup.active_model
    model.rendering_options['DisplayColorByLayer'] = false if model
    model.start_operation('Apply Diff', true) if model

    @diff_state = { queue: work_queue, idx: 0, applied: 0, t_start: Time.now }
    diff_process_batch
  end

  # Async batch processor: applies materials to DIFF_BATCH_SIZE entities per tick.
  def self.diff_process_batch
    state = @diff_state
    return unless state

    reg = @entity_registry || {}
    queue = state[:queue]
    batch_end = [state[:idx] + DIFF_BATCH_SIZE, queue.length].min

    (state[:idx]...batch_end).each do |i|
      item = queue[i]
      e = reg[item[:eid]]
      next unless e && e.valid?
      mat = @diff_materials[item[:model]]
      next unless mat
      dom = ColorController.diff_orig_mats
      dom[item[:eid]] = e.material unless dom.key?(item[:eid])
      e.material = mat
      state[:applied] += 1
    end

    state[:idx] = batch_end

    if state[:idx] >= queue.length
      finalize_diff(state)
    else
      pct = (state[:idx].to_f / queue.length * 100).round(0)
      Dashboard.update_portal_progress(pct, "Applying diff #{state[:idx]}/#{queue.length}...")
      UI.start_timer(0.01, false) { diff_process_batch }
    end
  end

  # Called when all batches complete.
  def self.finalize_diff(state)
    model = Sketchup.active_model
    model.commit_operation if model

    ColorController.diff_data = state[:queue]  # Array of {eid:, model:}
    @diff_data = state[:queue]
    @diff_state = nil
    @diff_active = true
    elapsed = Time.now - state[:t_start]

    model.active_view.invalidate if model
    puts "[FF Diff] Complete: #{state[:applied]} entities in #{elapsed.round(2)}s"

    Dashboard.send_diff_results
    Dashboard.portal_complete("Diff applied — #{state[:applied]} entities")
  end

  # Create 2 semi-transparent diff materials via ColorController.
  def self.create_diff_materials
    model = Sketchup.active_model
    return unless model
    @diff_materials = {}
    { a: DIFF_COLOR_A, b: DIFF_COLOR_B }.each do |key, rgb|
      name = "FF_DIFF_#{key.to_s.upcase}"
      mat = ColorController.get_or_create_material(model, name, rgb, DIFF_ALPHA / 255.0)
      @diff_materials[key] = mat
    end
  end

  # Re-apply diff materials from stored state (for toggle ON after OFF).
  def self.apply_diff_highlights
    data = @diff_data || ColorController.diff_data
    return unless data && data.any?
    model = Sketchup.active_model
    return unless model
    reg = @entity_registry || {}

    create_diff_materials unless @diff_materials
    model.rendering_options['DisplayColorByLayer'] = false
    model.start_operation('Apply Diff', true)

    dom = ColorController.diff_orig_mats || {}
    ColorController.diff_orig_mats = dom
    applied = 0
    data.each do |item|
      e = reg[item[:eid]]
      next unless e && e.valid?
      mat = @diff_materials[item[:model]]
      next unless mat
      dom[item[:eid]] = e.material unless dom.key?(item[:eid])
      e.material = mat
      applied += 1
    end

    model.commit_operation
    @diff_active = true
    model.active_view.invalidate
    puts "[FF Diff] Applied materials to #{applied} entities"
  end

  # Remove diff materials, restoring original appearance.
  def self.remove_diff_highlights
    model = Sketchup.active_model
    return unless model
    reg = @entity_registry || {}

    dom = ColorController.diff_orig_mats
    if dom && dom.any?
      model.start_operation('Remove Diff', true)
      dom.each do |eid, orig_mat|
        e = reg[eid]
        next unless e && e.valid?
        e.material = orig_mat
      end
      model.commit_operation
    end

    ColorController.diff_orig_mats = nil
    @diff_active = false

    if active_mv_view == 'ab'
      model.rendering_options['DisplayColorByLayer'] = true
    end
    model.active_view.invalidate
    puts "[FF Diff] Removed diff highlights"
  end

  # Toggle diff on/off without recomputing. Returns new active state.
  def self.toggle_diff
    if @diff_active
      remove_diff_highlights
    elsif (@diff_data || ColorController.diff_data) && (@diff_data || ColorController.diff_data).any?
      create_diff_materials unless @diff_materials
      apply_diff_highlights
    end
    @diff_active
  end

  # ═══ CHANGE REPORT ═══

  # Open a standalone HtmlDialog with the change report, injecting data.
  def self.show_change_report
    return unless @comparison_results

    models = @multiverse_data && @multiverse_data['models']
    model_a_name = models && models[0] ? models[0]['name'] : 'Model A'
    model_b_name = models && models[1] ? models[1]['name'] : 'Model B'

    report_data = {
      'modelA' => model_a_name, 'modelB' => model_b_name,
      'timestamp' => Time.now.strftime('%Y-%m-%d %H:%M'),
      'rows' => serialize_comparison_results
    }

    require 'json'
    json_str = JSON.generate(report_data)

    dlg = UI::HtmlDialog.new(
      dialog_title: "Form and Field — Change Report",
      preferences_key: "FFChangeReport",
      width: 800, height: 900, resizable: true
    )
    html_path = File.join(PLUGIN_DIR, 'ui', 'multiverse_change_report.html')
    dlg.set_file(html_path)

    # Inject data after short delay (set_file is async).
    # The HTML also polls for window.REPORT_DATA as fallback.
    UI.start_timer(0.3, false) do
      if dlg.visible?
        esc = json_str.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
        dlg.execute_script("window.REPORT_DATA = JSON.parse('#{esc}')")
      end
    end

    dlg.show
  end

  # Clear all comparison state: remove diff highlights, reset data
  def self.clear_compare_highlights
    remove_diff_highlights if @diff_active
    @diff_data = nil
    ColorController.diff_data = nil
    @diff_materials = nil
    @diff_state = nil
    @comparison_results = nil
    @compare_results = nil
    @compare_orig_mats = nil

    if active_mv_view == 'ab'
      model = Sketchup.active_model
      model.rendering_options['DisplayColorByLayer'] = true if model
    end

    Highlighter.show_all
  end

  # Serialize quantity delta results for JSON transport to dashboard
  def self.serialize_comparison_results
    return nil unless @comparison_results
    @comparison_results.map do |r|
      {
        'category'  => r[:category],
        'unit'      => r[:unit],
        'qtyA'      => r[:qty_a],
        'qtyB'      => r[:qty_b],
        'delta'     => r[:delta],
        'pctChange' => r[:pct_change],
        'countA'    => r[:count_a],
        'countB'    => r[:count_b]
      }
    end
  end

  def self.diff_data;      @diff_data;      end
  def self.diff_active?;   !!@diff_active;  end
  def self.diff_computed?;  @diff_data && @diff_data.any?; end

  # ═══ ACCEPT COMPARE — Stash matching + Flag discrepancies ═══

  # Accept comparison: stash matching B entities, move discrepancies into Model A
  def self.accept_compare
    return { 'error' => 'No compare results' } unless @compare_results
    model = Sketchup.active_model
    return { 'error' => 'No model' } unless model
    reg = @entity_registry || {}
    ca = @category_assignments || {}
    require 'json'

    r = @compare_results
    cat_a = r[:catA]
    matching = r[:matched].select { |m| m[:status] == 'matching' }
    modified = r[:matched].select { |m| m[:status] == 'modified' }
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M')

    puts "[FF Compare] Accept: #{matching.length} matching, #{modified.length} modified, #{r[:onlyB].length} only-B"

    # Clear preview highlights (restores original materials).
    # This re-enables DisplayColorByLayer — we'll turn it off after.
    clear_compare_highlights

    vault_data = JSON.parse(model.get_attribute('FormAndField', 'vault', '[]')) rescue []

    model.start_operation('Accept Comparison', true)
    stashed = 0
    flagged = 0

    # ── STEP 1: Stash matching B entities — erase from model ──
    total_ops = matching.length + modified.length + r[:onlyB].length
    done_ops = 0
    stashed_eids = []
    erase_failed = 0
    matching.each do |pair|
      eid = pair[:b_eid]
      e = reg[eid]
      next unless e && e.valid?

      vault_data << {
        'eid' => eid,
        'a_eid' => pair[:a_eid],
        'name' => (e.respond_to?(:definition) ? e.definition.name : e.typename),
        'category' => (ca[eid] || cat_a),
        'stashed_at' => timestamp,
        'position' => [e.bounds.center.x.to_f, e.bounds.center.y.to_f, e.bounds.center.z.to_f],
        'model_source' => e.get_attribute('FormAndField', 'model_source'),
        'reason' => 'matching'
      }

      # Erase: handle both top-level and nested entities
      erased = false
      begin
        parent = e.parent
        if parent.is_a?(Sketchup::ComponentDefinition)
          parent.entities.erase_entities(e)
          erased = true
        else
          e.erase!
          erased = true
        end
      rescue => err
        puts "[FF Compare] Erase failed for #{eid}: #{err.message}"
        # Fallback: hide it
        begin
          e.visible = false
          e.set_attribute('FormAndField', 'vaulted', true)
          erased = true
        rescue
        end
        erase_failed += 1
      end

      if erased
        stashed_eids << eid
        reg.delete(eid)
        stashed += 1
      end
      done_ops += 1
      if done_ops % 5 == 0 || done_ops == total_ops
        pct = total_ops > 0 ? ((done_ops.to_f / total_ops) * 100).round(0) : 0
        Dashboard.update_portal_progress(pct, "#{done_ops}/#{total_ops}")
      end
    end

    puts "[FF Compare] Erased #{stashed} matching entities (#{erase_failed} used hide fallback)"

    model.set_attribute('FormAndField', 'vault', JSON.generate(vault_data))
    @scan_results.reject! { |s| stashed_eids.include?(s[:entity_id]) }

    # ── STEP 2: Move discrepancies out of Model B component into Model A ──
    disc_eids = []
    modified.each { |m| disc_eids << m[:b_eid] }
    r[:onlyB].each { |eid| disc_eids << eid }

    # Create the persistent red discrepancy material
    mat_disc_name = 'FF_Discrepancy'
    mat_disc = model.materials[mat_disc_name] || model.materials.add(mat_disc_name)
    mat_disc.color = Sketchup::Color.new(243, 139, 168)
    mat_disc.alpha = 0.85

    new_disc_eids = []

    disc_eids.each do |eid|
      e = reg[eid]
      next unless e && e.valid?

      # Physically move entity from Model B component to active_entities
      new_ent = move_entity_to_active(e, model)
      if new_ent
        new_eid = new_ent.entityID

        # Tag the NEW entity as Model A
        new_ent.set_attribute('FormAndField', 'model_source', 'model_a')

        # Metadata stamps
        new_ent.set_attribute('FormAndField', 'discrepancy_date', timestamp)
        new_ent.set_attribute('FormAndField', 'discrepancy_source', 'model_b')

        # Paint the instance red
        new_ent.material = mat_disc

        # Also paint faces inside so red shows through reversed normals / IFC geometry
        if new_ent.respond_to?(:definition) && new_ent.definition
          new_ent.definition.entities.grep(Sketchup::Face).each do |face|
            face.material = mat_disc
            face.back_material = mat_disc
          end
        elsif new_ent.is_a?(Sketchup::Group)
          new_ent.entities.grep(Sketchup::Face).each do |face|
            face.material = mat_disc
            face.back_material = mat_disc
          end
        end

        # Update registry: remove old, add new
        reg.delete(eid)
        reg[new_eid] = new_ent

        # Update category assignments
        ca.delete(eid)
        ca[new_eid] = cat_a
        save_assignment(new_eid, 'category', cat_a)
        save_assignment(new_eid, 'subcategory', 'Discrepancy')

        # Update scan_results: swap entity_id
        @scan_results.each do |s|
          if s[:entity_id] == eid
            s[:entity_id] = new_eid
            s[:parsed][:auto_subcategory] = 'Discrepancy'
          end
        end

        new_disc_eids << new_eid
        flagged += 1
      else
        puts "[FF Compare] move_entity_to_active failed for eid #{eid}, falling back to re-tag"
        e.set_attribute('FormAndField', 'model_source', 'model_a')
        e.layer = model.layers['FF_Model_A'] if model.layers['FF_Model_A']
        ca[eid] = cat_a
        save_assignment(eid, 'category', cat_a)
        save_assignment(eid, 'subcategory', 'Discrepancy')
        e.set_attribute('FormAndField', 'discrepancy_date', timestamp)
        e.set_attribute('FormAndField', 'discrepancy_source', 'model_b')
        e.material = mat_disc
        new_disc_eids << eid
        flagged += 1
      end
      done_ops += 1
      if done_ops % 5 == 0 || done_ops == total_ops
        pct = total_ops > 0 ? ((done_ops.to_f / total_ops) * 100).round(0) : 0
        Dashboard.update_portal_progress(pct, "#{done_ops}/#{total_ops}")
      end
    end

    # Turn OFF DisplayColorByLayer so red materials are visible.
    model.rendering_options['DisplayColorByLayer'] = false

    model.commit_operation
    invalidate_entity_cache

    # ── STEP 3: Update master subcategories ──
    @master_subcategories ||= {}
    @master_subcategories[cat_a] ||= []
    unless @master_subcategories[cat_a].include?('Discrepancy')
      @master_subcategories[cat_a] << 'Discrepancy'
    end
    save_master_subcategories

    @category_assignments = ca
    @compare_results = nil

    # ── STEP 4: Switch to Model A view — hide remaining Model B ──
    # Discrepancies were moved to FF_Model_A layer in step 2,
    # so hiding Model B only hides uncompared B entities.
    layer_b = model.layers['FF_Model_B']
    layer_b.visible = false if layer_b

    layer_a_vis = model.layers['FF_Model_A']
    layer_a_vis.visible = true if layer_a_vis

    # Keep DisplayColorByLayer OFF so red materials show
    model.rendering_options['DisplayColorByLayer'] = false

    # Update multiverse state to view 'a'
    if @multiverse_data
      @multiverse_data['active_view'] = 'a'
      save_multiverse_data
    end

    # Force viewport redraw
    model.active_view.invalidate

    # Persist updated scan data to entity attributes
    save_scan_to_model rescue nil

    puts "[FF Compare] Done: stashed #{stashed}, flagged #{flagged} in #{cat_a} > Discrepancy"

    { 'stashed' => stashed, 'flagged' => flagged, 'category' => cat_a }
  end

  # ═══ COMMIT TO MAIN — Move B entities into Model A (clean, no flags) ═══

  # Commit all entities of a category from Model B into Model A
  # No red paint, no Discrepancy subcategory — clean addition
  def self.commit_to_main(category)
    model = Sketchup.active_model
    return { 'error' => 'No model' } unless model
    reg = @entity_registry || {}
    ca = @category_assignments || {}
    sr = @scan_results || []

    layer_a = model.layers['FF_Model_A']
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M')

    # Find all Model B entities in this category
    b_eids = []
    sr.each do |r|
      e = reg[r[:entity_id]]
      next unless e && e.valid?
      ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'
      next if ms == 'model_a'
      cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      b_eids << r[:entity_id] if cat == category
    end

    return { 'error' => 'No Model B entities in this category' } if b_eids.empty?

    puts "[FF Commit] Committing #{b_eids.length} entities from '#{category}' to Model A"

    model.start_operation('Commit to Main', true)
    committed = 0
    total = b_eids.length

    b_eids.each do |eid|
      e = reg[eid]
      next unless e && e.valid?

      # Physically move entity from Model B component to active_entities
      new_ent = move_entity_to_active(e, model)
      if new_ent
        new_eid = new_ent.entityID

        # Tag the NEW entity
        new_ent.set_attribute('FormAndField', 'model_source', 'model_a')
        new_ent.set_attribute('FormAndField', 'committed_from', 'model_b')
        new_ent.set_attribute('FormAndField', 'committed_date', timestamp)

        # Update registry: remove old, add new
        reg.delete(eid)
        reg[new_eid] = new_ent

        # Update category assignments
        old_cat = ca.delete(eid)
        ca[new_eid] = old_cat || category

        # Update scan_results: swap entity_id
        @scan_results.each do |s|
          s[:entity_id] = new_eid if s[:entity_id] == eid
        end

        committed += 1
      else
        puts "[FF Commit] move_entity_to_active failed for eid #{eid}, falling back to re-tag"
        e.set_attribute('FormAndField', 'model_source', 'model_a')
        e.layer = layer_a if layer_a
        ca[eid] = category unless ca[eid]
        e.set_attribute('FormAndField', 'committed_from', 'model_b')
        e.set_attribute('FormAndField', 'committed_date', timestamp)
        committed += 1
      end

      # Update portal progress
      pct = ((committed.to_f / total) * 100).round(0)
      Dashboard.update_portal_progress(pct, "#{committed}/#{total}") if committed % 5 == 0 || committed == total
    end

    model.commit_operation
    invalidate_entity_cache

    # Ensure category exists in master list
    @master_categories ||= []
    unless @master_categories.include?(category)
      @master_categories << category
      save_master_categories rescue nil
    end

    @category_assignments = ca

    # Switch to Model A view
    layer_b = model.layers['FF_Model_B']
    layer_b.visible = false if layer_b
    layer_a.visible = true if layer_a
    model.rendering_options['DisplayColorByLayer'] = false

    if @multiverse_data
      @multiverse_data['active_view'] = 'a'
      save_multiverse_data
    end

    model.active_view.invalidate

    # Persist updated scan data to entity attributes
    save_scan_to_model rescue nil

    puts "[FF Commit] Done: committed #{committed} entities into '#{category}'"
    { 'committed' => committed, 'category' => category }
  end

  # Commit from compare results: stash matching + commit discrepancies (only-B + modified)
  # Unlike accept_compare, this does NOT paint red or create Discrepancy subcategory
  def self.commit_compare_entities
    return { 'error' => 'No compare results' } unless @compare_results
    model = Sketchup.active_model
    return { 'error' => 'No model' } unless model
    reg = @entity_registry || {}
    ca = @category_assignments || {}
    require 'json'

    r = @compare_results
    cat_a = r[:catA]
    matching = r[:matched].select { |m| m[:status] == 'matching' }
    modified = r[:matched].select { |m| m[:status] == 'modified' }
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M')

    puts "[FF Commit] Compare commit: #{matching.length} matching (stash), #{modified.length} modified + #{r[:onlyB].length} only-B (commit)"

    # Clear preview highlights first
    clear_compare_highlights

    vault_data = JSON.parse(model.get_attribute('FormAndField', 'vault', '[]')) rescue []

    model.start_operation('Commit Compare', true)
    stashed = 0
    committed = 0

    # ── STEP 1: Stash matching B entities (same as accept) ──
    total_ops = matching.length + modified.length + r[:onlyB].length
    done_ops = 0
    stashed_eids = []
    matching.each do |pair|
      eid = pair[:b_eid]
      e = reg[eid]
      next unless e && e.valid?

      vault_data << {
        'eid' => eid,
        'a_eid' => pair[:a_eid],
        'name' => (e.respond_to?(:definition) ? e.definition.name : e.typename),
        'category' => (ca[eid] || cat_a),
        'stashed_at' => timestamp,
        'position' => [e.bounds.center.x.to_f, e.bounds.center.y.to_f, e.bounds.center.z.to_f],
        'model_source' => e.get_attribute('FormAndField', 'model_source'),
        'reason' => 'matching'
      }

      begin
        parent = e.parent
        if parent.is_a?(Sketchup::ComponentDefinition)
          parent.entities.erase_entities(e)
        else
          e.erase!
        end
      rescue => err
        puts "[FF Commit] Erase failed for #{eid}: #{err.message}"
        begin; e.visible = false; e.set_attribute('FormAndField', 'vaulted', true); rescue; end
      end

      stashed_eids << eid
      reg.delete(eid)
      stashed += 1
      done_ops += 1
      if done_ops % 5 == 0 || done_ops == total_ops
        pct = total_ops > 0 ? ((done_ops.to_f / total_ops) * 100).round(0) : 0
        Dashboard.update_portal_progress(pct, "#{done_ops}/#{total_ops}")
      end
    end

    model.set_attribute('FormAndField', 'vault', JSON.generate(vault_data))
    @scan_results.reject! { |s| stashed_eids.include?(s[:entity_id]) }

    # ── STEP 2: Commit discrepancies (only-B + modified) — move out of Model B component ──
    old_commit_eids = []
    modified.each { |m| old_commit_eids << m[:b_eid] }
    r[:onlyB].each { |eid| old_commit_eids << eid }

    new_commit_eids = []

    old_commit_eids.each do |eid|
      e = reg[eid]
      next unless e && e.valid?

      is_modified = modified.any? { |m| m[:b_eid] == eid }
      subcat = is_modified ? 'Modified from B' : 'Committed from B'

      # Physically move entity from Model B component to active_entities
      new_ent = move_entity_to_active(e, model)
      if new_ent
        new_eid = new_ent.entityID

        # Tag the NEW entity
        new_ent.set_attribute('FormAndField', 'model_source', 'model_a')
        new_ent.set_attribute('FormAndField', 'committed_from', 'model_b')
        new_ent.set_attribute('FormAndField', 'committed_date', timestamp)
        new_ent.set_attribute('FormAndField', 'commit_type', is_modified ? 'modified' : 'new')

        # Update registry
        reg.delete(eid)
        reg[new_eid] = new_ent

        # Update category assignments
        ca.delete(eid)
        ca[new_eid] = cat_a
        save_assignment(new_eid, 'category', cat_a)
        save_assignment(new_eid, 'subcategory', subcat)

        # Update scan_results: swap entity_id
        @scan_results.each do |s|
          if s[:entity_id] == eid
            s[:entity_id] = new_eid
            s[:parsed][:auto_subcategory] = subcat
          end
        end

        new_commit_eids << new_eid
        committed += 1
      else
        puts "[FF Commit] move_entity_to_active failed for eid #{eid}, falling back to re-tag"
        layer_a = model.layers['FF_Model_A']
        e.set_attribute('FormAndField', 'model_source', 'model_a')
        e.layer = layer_a if layer_a
        ca[eid] = cat_a
        save_assignment(eid, 'category', cat_a)
        save_assignment(eid, 'subcategory', subcat)
        e.set_attribute('FormAndField', 'committed_from', 'model_b')
        e.set_attribute('FormAndField', 'committed_date', timestamp)
        e.set_attribute('FormAndField', 'commit_type', is_modified ? 'modified' : 'new')
        new_commit_eids << eid
        committed += 1
      end
      done_ops += 1
      if done_ops % 5 == 0 || done_ops == total_ops
        pct = total_ops > 0 ? ((done_ops.to_f / total_ops) * 100).round(0) : 0
        Dashboard.update_portal_progress(pct, "#{done_ops}/#{total_ops}")
      end
    end

    model.commit_operation
    invalidate_entity_cache

    # ── STEP 3: Update master subcategories ──
    @master_subcategories ||= {}
    @master_subcategories[cat_a] ||= []
    ['Committed from B', 'Modified from B'].each do |sub|
      unless @master_subcategories[cat_a].include?(sub)
        @master_subcategories[cat_a] << sub
      end
    end
    save_master_subcategories

    @category_assignments = ca
    @compare_results = nil

    # ── STEP 4: Switch to Model A view ──
    layer_b = model.layers['FF_Model_B']
    layer_b.visible = false if layer_b
    layer_a_vis = model.layers['FF_Model_A']
    layer_a_vis.visible = true if layer_a_vis
    model.rendering_options['DisplayColorByLayer'] = false

    if @multiverse_data
      @multiverse_data['active_view'] = 'a'
      save_multiverse_data
    end

    model.active_view.invalidate

    # Persist updated scan data to entity attributes
    save_scan_to_model rescue nil

    puts "[FF Commit] Done: stashed #{stashed}, committed #{committed} into '#{cat_a}'"
    { 'stashed' => stashed, 'committed' => committed, 'category' => cat_a }
  end

  # ═══ VAULT — Recall stashed entities ═══

  # Restore all entities from vault (re-import from definitions at original positions)
  def self.recall_from_vault
    model = Sketchup.active_model
    return { error: 'No model' } unless model
    require 'json'

    vault_data = JSON.parse(model.get_attribute('FormAndField', 'vault', '[]')) rescue []
    return { error: 'Vault empty' } if vault_data.empty?

    model.start_operation('Recall Vault', true)
    recalled = 0

    vault_data.each do |record|
      defn = model.definitions[record['name']]
      next unless defn

      pos = record['position'] || [0, 0, 0]
      pt = Geom::Point3d.new(pos[0], pos[1], pos[2])
      tr = Geom::Transformation.new(pt)
      inst = model.active_entities.add_instance(defn, tr)

      ms = record['model_source']
      if ms
        inst.set_attribute('FormAndField', 'model_source', ms)
        layer_b = model.layers['FF_Model_B']
        inst.layer = layer_b if layer_b && ms != 'model_a'
      end

      @entity_registry[inst.entityID] = inst
      recalled += 1
    end

    model.set_attribute('FormAndField', 'vault', '[]')
    model.commit_operation
    invalidate_entity_cache

    rescan_model_b if recalled > 0

    { recalled: recalled }
  end

  # Return vault contents for UI display
  def self.vault_summary
    model = Sketchup.active_model
    return [] unless model
    require 'json'
    JSON.parse(model.get_attribute('FormAndField', 'vault', '[]')) rescue []
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
