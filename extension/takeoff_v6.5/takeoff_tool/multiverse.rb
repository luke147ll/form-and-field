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

    # ── DEBUG: Diagnose what got tagged ──
    tagged_b = 0
    untagged = 0
    model.definitions.each do |defn|
      defn.instances.each do |inst|
        ms = inst.get_attribute('FormAndField', 'model_source')
        if ms && ms != 'model_a'
          tagged_b += 1
        else
          untagged += 1
        end
      end
    end
    puts "[FF DEBUG] After tagging: #{tagged_b} Model B instances, #{untagged} untagged/Model A"
    puts "[FF DEBUG] Total definitions: #{model.definitions.length}"

    # Check Revit wrapper contents
    model.definitions.each do |defn|
      next unless defn.name =~ /Cole|rvt/i
      puts "[FF DEBUG] Revit wrapper '#{defn.name}': #{defn.entities.length} entities, #{defn.instances.length} instances"
      defn.entities.each do |e|
        if e.is_a?(Sketchup::ComponentInstance)
          ms = e.get_attribute('FormAndField', 'model_source')
          puts "[FF DEBUG]   Child: '#{e.definition.name}' model_source=#{ms.inspect} layer=#{e.layer.name}"
        end
      end
    end
    # ── END DEBUG ──

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

    # ── Step 3: Load categories + save ──
    load_saved_assignments
    load_master_categories
    merge_scan_categories_into_master
    prune_empty_categories
    load_master_subcategories

    save_scan_to_model rescue nil

    total = (Time.now - t_start).round(1)
    summary = "Model B scan: #{b_results.length} entities in #{total}s"
    Dashboard.scan_log_end(summary)
    puts "Multiverse: #{summary}"

    if Dashboard.visible?
      Dashboard.send_data(@scan_results, @category_assignments, @cost_code_assignments)
      Dashboard.send_multiverse_data
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

  # ═══ CATEGORY COMPARE — Bounding Box Intersection ═══

  COMPARE_OVERLAP_THRESHOLD = 0.50   # 50% BB overlap = likely same entity
  COMPARE_VOLUME_TOLERANCE  = 0.20   # 20% volume difference = same size
  COMPARE_CLUSTER_SPATIAL_TOL = 0.5  # inches gap tolerance for proximity clustering
  COMPARE_CLUSTER_VOL_TOL     = 0.05 # 5% volume tolerance for cluster mode

  # Union-Find for connected component grouping (clustering)
  class UnionFind
    def initialize(n)
      @parent = (0...n).to_a
      @rank = Array.new(n, 0)
    end
    def find(x)
      @parent[x] = @parent[@parent[x]] while @parent[x] != x
      @parent[x]
    end
    def union(a, b)
      ra, rb = find(a), find(b)
      return if ra == rb
      ra, rb = rb, ra if @rank[ra] < @rank[rb]
      @parent[rb] = ra
      @rank[ra] += 1 if @rank[ra] == @rank[rb]
    end
    def components
      groups = Hash.new { |h, k| h[k] = [] }
      @parent.each_index { |i| groups[find(i)] << i }
      groups.values
    end
  end

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

  # How much do two BBs overlap? Returns 0.0–1.0 relative to the smaller volume
  def self.bb_overlap_ratio(a, b)
    x_inter = [0, [a[:max][0], b[:max][0]].min - [a[:min][0], b[:min][0]].max].max
    y_inter = [0, [a[:max][1], b[:max][1]].min - [a[:min][1], b[:min][1]].max].max
    z_inter = [0, [a[:max][2], b[:max][2]].min - [a[:min][2], b[:min][2]].max].max

    inter_vol = x_inter * y_inter * z_inter
    smaller = [a[:volume], b[:volume]].min
    return 0.0 if smaller <= 0
    inter_vol / smaller
  end

  # Are two BBs either overlapping or within tolerance on all 3 axes?
  def self.bb_adjacent?(a, b, tolerance)
    3.times.all? do |i|
      gap = [0, [a[:min][i], b[:min][i]].max - [a[:max][i], b[:max][i]].min].max
      gap <= tolerance
    end
  end

  # Spatial hash grid for O(N) adjacency queries (N > 100 only)
  def self.build_spatial_hash(items)
    return nil if items.length <= 100
    cell_size = 1.0
    items.each do |it|
      b = it[:bounds]
      3.times { |i| d = b[:max][i] - b[:min][i]; cell_size = d if d > cell_size }
    end
    cell_size = [cell_size, 1.0].max
    grid = Hash.new { |h, k| h[k] = [] }
    items.each_with_index do |it, idx|
      b = it[:bounds]
      x0, x1 = (b[:min][0] / cell_size).floor, (b[:max][0] / cell_size).floor
      y0, y1 = (b[:min][1] / cell_size).floor, (b[:max][1] / cell_size).floor
      z0, z1 = (b[:min][2] / cell_size).floor, (b[:max][2] / cell_size).floor
      (x0..x1).each { |cx| (y0..y1).each { |cy| (z0..z1).each { |cz| grid[[cx, cy, cz]] << idx } } }
    end
    grid
  end

  # Cluster items by spatial proximity using union-find connected components.
  # Returns array of cluster hashes: {members, combined_bb, total_real_volume, member_eids}
  def self.cluster_entities_by_proximity(items, tolerance = COMPARE_CLUSTER_SPATIAL_TOL)
    return [] if items.empty?
    n = items.length
    return [build_cluster(items, [0])] if n == 1

    uf = UnionFind.new(n)
    grid = build_spatial_hash(items)

    if grid
      checked = {}
      grid.each_value do |indices|
        indices.each do |i|
          indices.each do |j|
            next if i >= j
            key = (i << 20) | j
            next if checked[key]
            checked[key] = true
            uf.union(i, j) if bb_adjacent?(items[i][:bounds], items[j][:bounds], tolerance)
          end
        end
      end
    else
      (0...n).each do |i|
        ((i + 1)...n).each do |j|
          uf.union(i, j) if bb_adjacent?(items[i][:bounds], items[j][:bounds], tolerance)
        end
      end
    end

    uf.components.map { |indices| build_cluster(items, indices) }
  end

  # Build a cluster hash from a set of item indices
  def self.build_cluster(items, indices)
    members = indices.map { |i| items[i] }
    c_min = [Float::INFINITY] * 3
    c_max = [-Float::INFINITY] * 3
    total_vol = 0.0
    members.each do |m|
      b = m[:bounds]
      3.times do |ax|
        c_min[ax] = b[:min][ax] if b[:min][ax] < c_min[ax]
        c_max[ax] = b[:max][ax] if b[:max][ax] > c_max[ax]
      end
      total_vol += (m[:r][:volume_ft3] || 0.0)
    end
    bb_vol = (c_max[0] - c_min[0]) * (c_max[1] - c_min[1]) * (c_max[2] - c_min[2])
    {
      members: members,
      combined_bb: {
        min: c_min, max: c_max,
        center: [(c_min[0] + c_max[0]) / 2.0, (c_min[1] + c_max[1]) / 2.0, (c_min[2] + c_max[2]) / 2.0],
        volume: [bb_vol, 0.001].max
      },
      total_real_volume: total_vol,
      member_eids: members.map { |m| m[:eid] }
    }
  end

  # Compare entities in cat_a (Model A) against cat_b (Model B) by BB intersection.
  # When opts['cluster'] is true (default), merges touching/overlapping entities into
  # clusters before comparing — so a group of small footings can match one large footing.
  # Results: matching, discrepancies (only_b + modified), only_a (unchanged)
  def self.compare_categories(cat_a, cat_b, opts = {})
    sr = @scan_results || []
    ca = @category_assignments || {}
    reg = @entity_registry || {}

    puts "[FF Compare] Starting: A='#{cat_a}' vs B='#{cat_b}'"
    puts "[FF Compare] Total scan results: #{sr.length}, registry: #{reg.length}"

    # Collect entities per model+category with world-space bounding boxes
    a_items = []; b_items = []
    sr.each do |r|
      e = reg[r[:entity_id]]
      next unless e && e.valid?
      cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
      ms = e.get_attribute('FormAndField', 'model_source') || 'model_a'

      bounds = get_world_bounds(e)
      next unless bounds && bounds[:volume] > 0

      item = { r: r, e: e, eid: r[:entity_id], bounds: bounds,
               name: r[:display_name] || r[:definition_name] || '' }

      if ms == 'model_a' && cat == cat_a
        a_items << item
      elsif ms != 'model_a' && cat == cat_b
        b_items << item
      end
    end

    puts "[FF Compare] A: #{a_items.length} entities, B: #{b_items.length} entities"

    # Debug: print first 3 entities from each side
    a_items[0..2].each do |it|
      puts "[FF Compare]   A #{it[:name]}: center=#{it[:bounds][:center].map{|v|v.round(1)}.inspect} vol=#{it[:bounds][:volume].round(1)}"
    end
    b_items[0..2].each do |it|
      puts "[FF Compare]   B #{it[:name]}: center=#{it[:bounds][:center].map{|v|v.round(1)}.inspect} vol=#{it[:bounds][:volume].round(1)}"
    end

    # Parse comparison options
    use_cluster = opts.fetch('cluster', true)
    spatial_tol = opts.fetch('spatialTol', COMPARE_CLUSTER_SPATIAL_TOL).to_f
    vol_tol = opts.fetch('volTol', use_cluster ? COMPARE_CLUSTER_VOL_TOL : COMPARE_VOLUME_TOLERANCE).to_f

    matched = []
    only_a  = []
    only_b  = []
    b_used  = {}

    if use_cluster && (a_items.length > 1 || b_items.length > 1)
      # ── Cluster-to-cluster comparison ──
      puts "[FF Compare] Clustering: spatialTol=#{spatial_tol}\", volTol=#{(vol_tol * 100).round}%"
      a_clusters = cluster_entities_by_proximity(a_items, spatial_tol)
      b_clusters = cluster_entities_by_proximity(b_items, spatial_tol)
      puts "[FF Compare] Clusters: A=#{a_clusters.length} (from #{a_items.length}), B=#{b_clusters.length} (from #{b_items.length})"

      a_clusters.each do |ac|
        best = nil
        best_overlap = 0

        b_clusters.each_with_index do |bc, bi|
          next if b_used[bi]
          next unless bb_overlap?(ac[:combined_bb], bc[:combined_bb])
          ratio = bb_overlap_ratio(ac[:combined_bb], bc[:combined_bb])
          if ratio > COMPARE_OVERLAP_THRESHOLD && ratio > best_overlap
            best = { bc: bc, idx: bi, overlap: ratio }
            best_overlap = ratio
          end
        end

        if best
          b_used[best[:idx]] = true
          bc = best[:bc]

          # Volume comparison using REAL summed volumes (not BB volumes)
          vol_a = ac[:total_real_volume]
          vol_b = bc[:total_real_volume]
          max_vol = [vol_a, vol_b].max
          vol_diff = max_vol > 0 ? (vol_a - vol_b).abs / max_vol : 0

          status = vol_diff < vol_tol ? 'matching' : 'modified'
          delta = status == 'modified' ? { vol_diff: vol_diff.round(3), overlap: best[:overlap].round(3),
                    a_count: ac[:members].length, b_count: bc[:members].length } : {}

          # Expand cluster match → individual eid pairs
          a_eids = ac[:member_eids]
          b_eids = bc[:member_eids]
          [a_eids.length, b_eids.length].max.times do |i|
            ae = a_eids[i]; be = b_eids[i]
            if ae && be
              matched << { a_eid: ae, b_eid: be, status: status, delta: delta }
            elsif ae
              only_a << ae
            elsif be
              only_b << be
            end
          end
        else
          only_a.concat(ac[:member_eids])
        end
      end

      b_clusters.each_with_index { |bc, idx| only_b.concat(bc[:member_eids]) unless b_used[idx] }

    else
      # ── Original entity-to-entity comparison ──
      a_items.each_with_index do |ai, a_idx|
        best = nil
        best_overlap = 0

        b_items.each_with_index do |bi, bi_idx|
          next if b_used[bi_idx]
          next unless bb_overlap?(ai[:bounds], bi[:bounds])

          ratio = bb_overlap_ratio(ai[:bounds], bi[:bounds])
          if ratio > COMPARE_OVERLAP_THRESHOLD && ratio > best_overlap
            best = { bi: bi, idx: bi_idx, overlap: ratio }
            best_overlap = ratio
          end
        end

        if best
          b_used[best[:idx]] = true
          bi = best[:bi]

          vol_a = ai[:bounds][:volume]
          vol_b = bi[:bounds][:volume]
          max_vol = [vol_a, vol_b].max
          vol_diff = max_vol > 0 ? (vol_a - vol_b).abs / max_vol : 0

          if vol_diff < vol_tol
            status = 'matching'
            delta = {}
          else
            status = 'modified'
            delta = { vol_diff: vol_diff.round(3), overlap: best[:overlap].round(3) }
          end
          matched << { a_eid: ai[:eid], b_eid: bi[:eid], status: status, delta: delta }
        else
          only_a << ai[:eid]
        end

        if (a_idx + 1) % 50 == 0
          puts "[FF Compare] Processed #{a_idx + 1}/#{a_items.length}..."
        end
      end

      b_items.each_with_index do |bi, idx|
        only_b << bi[:eid] unless b_used[idx]
      end
    end

    matching_n = matched.count { |m| m[:status] == 'matching' }
    modified_n = matched.count { |m| m[:status] == 'modified' }
    puts "[FF Compare] Results: #{matching_n} matching, #{modified_n} modified, #{only_a.length} only-A, #{only_b.length} only-B"

    @compare_results = { catA: cat_a, catB: cat_b, matched: matched, onlyA: only_a, onlyB: only_b }
  end

  # Preview: highlight matching green, discrepancies red in viewport
  def self.apply_compare_highlights
    return unless @compare_results
    model = Sketchup.active_model
    return unless model
    reg = @entity_registry || {}

    model.rendering_options['DisplayColorByLayer'] = false

    model.start_operation('Compare Highlights', true)

    # Green = matching (will be stashed)
    mat_green_name = 'FF_Compare_Matching'
    mat_green = model.materials[mat_green_name] || model.materials.add(mat_green_name)
    mat_green.color = Sketchup::Color.new(166, 227, 161)
    mat_green.alpha = 0.5

    # Red = discrepancy (will be flagged)
    mat_red_name = 'FF_Compare_Discrepancy'
    mat_red = model.materials[mat_red_name] || model.materials.add(mat_red_name)
    mat_red.color = Sketchup::Color.new(243, 139, 168)
    mat_red.alpha = 0.7

    @compare_orig_mats = {}
    all_eids = []

    # Matching pairs: paint both A and B copies green
    @compare_results[:matched].each do |pair|
      mat = (pair[:status] == 'matching') ? mat_green : mat_red
      [pair[:a_eid], pair[:b_eid]].each do |eid|
        e = reg[eid]
        next unless e && e.valid?
        @compare_orig_mats[eid] = e.material
        e.material = mat
        all_eids << eid
      end
    end

    # Only in B: paint red (new in B = discrepancy)
    @compare_results[:onlyB].each do |eid|
      e = reg[eid]
      next unless e && e.valid?
      @compare_orig_mats[eid] = e.material
      e.material = mat_red
      all_eids << eid
    end

    # Only in A: leave as-is but include in isolation set
    @compare_results[:onlyA].each do |eid|
      all_eids << eid if reg[eid] && reg[eid].valid?
    end

    model.commit_operation

    puts "[FF Compare] Highlighted #{all_eids.length} entities (#{@compare_orig_mats.length} tinted)"

    Highlighter.isolate_entities(@scan_results, all_eids) if all_eids.any?
  end

  # Restore original materials and show all entities
  def self.clear_compare_highlights
    model = Sketchup.active_model
    return unless model
    reg = @entity_registry || {}

    if @compare_orig_mats && @compare_orig_mats.any?
      model.start_operation('Clear Compare', true)
      @compare_orig_mats.each do |eid, orig_mat|
        e = reg[eid]
        next unless e && e.valid?
        e.material = orig_mat
      end
      model.commit_operation
    end

    @compare_orig_mats = nil

    if active_mv_view == 'ab'
      model.rendering_options['DisplayColorByLayer'] = true
    end

    Highlighter.show_all
  end

  # Serialize compare results to a plain string-keyed hash for JSON transport
  def self.serialize_compare_results
    return nil unless @compare_results
    r = @compare_results
    matching     = r[:matched].select { |m| m[:status] == 'matching' }
    modified     = r[:matched].select { |m| m[:status] == 'modified' }
    disc_count   = modified.length + r[:onlyB].length
    # Use string keys so JSON.generate produces exactly what JS expects
    {
      'catA' => r[:catA].to_s,
      'catB' => r[:catB].to_s,
      'matchingCount' => matching.length,
      'discrepancyCount' => disc_count,
      'modifiedCount' => modified.length,
      'onlyACount' => r[:onlyA].length,
      'onlyBCount' => r[:onlyB].length,
      'matchingEids' => matching.flat_map { |m| [m[:a_eid], m[:b_eid]] },
      'discrepancyEids' => modified.flat_map { |m| [m[:a_eid], m[:b_eid]] } + r[:onlyB],
      'onlyAEids' => r[:onlyA],
    }
  end

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
