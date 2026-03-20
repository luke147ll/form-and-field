module TakeoffTool

  # Save a single assignment to the entity's attribute dictionary
  def self.save_assignment(eid, key, value)
    e = find_entity(eid)
    if e && e.valid?
      begin
        e.set_attribute('TakeoffAssignments', key, value)
        publish(EVENT_ASSIGNMENT_CHANGED, eid: eid, key: key, value: value)
        # Debounced save of full assignment map to model attribute
        schedule_assignments_save if key == 'category' || key == 'cost_code'
      rescue => err
        puts "Takeoff: save_assignment error eid=#{eid} key=#{key}: #{err.message}"
      end
    else
      puts "Takeoff: save_assignment - entity #{eid} not found"
    end
  end

  # Debounce: save assignments to model attribute after a brief pause (batches rapid changes)
  def self.schedule_assignments_save
    @_assignments_save_pending = true
    @_assignments_save_timer ||= UI.start_timer(2.0, false) do
      @_assignments_save_timer = nil
      if @_assignments_save_pending
        @_assignments_save_pending = false
        save_assignments_to_model rescue nil
      end
    end
  end

  # Load all saved assignments from entity attributes after scan
  def self.load_saved_assignments
    count_cat = 0
    count_cc = 0

    # ── Primary: restore from model-level persistent_id map (fast, survives entity ID changes) ──
    m = Sketchup.active_model
    if m
      require 'json'
      pid_to_eid = build_persistent_id_map(m)

      ca_json = m.get_attribute('FormAndField', 'saved_category_assignments')
      if ca_json && !ca_json.empty?
        saved_cats = (JSON.parse(ca_json) rescue {})
        saved_cats.each do |pid, cat|
          eid = pid_to_eid[pid.to_s]
          if eid && cat && !cat.empty?
            @category_assignments[eid] = cat
            count_cat += 1
          end
        end
      end

      cc_json = m.get_attribute('FormAndField', 'saved_cost_code_assignments')
      if cc_json && !cc_json.empty?
        saved_ccs = (JSON.parse(cc_json) rescue {})
        saved_ccs.each do |pid, cc|
          eid = pid_to_eid[pid.to_s]
          if eid && cc && !cc.empty?
            @cost_code_assignments[eid] = cc
            count_cc += 1
          end
        end
      end
    end

    # ── Fallback: read from entity attributes (catches anything missed above) ──
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      begin
        cat = e.get_attribute('TakeoffAssignments', 'category')
        if cat && !cat.empty? && !@category_assignments.key?(eid)
          @category_assignments[eid] = cat
          count_cat += 1
        end
        cc = e.get_attribute('TakeoffAssignments', 'cost_code')
        if cc && !cc.empty? && !@cost_code_assignments.key?(eid)
          @cost_code_assignments[eid] = cc
          count_cc += 1
        end
        sz = e.get_attribute('TakeoffAssignments', 'size')
        if sz && !sz.empty?
          @scan_results.each do |r|
            if r[:entity_id] == eid
              r[:parsed][:size_nominal] = sz
              break
            end
          end
        end
      rescue => err
        puts "Takeoff: load_saved error eid=#{eid}: #{err.message}"
      end
    end
    puts "Takeoff: Loaded #{count_cat} saved categories, #{count_cc} saved cost codes" if (count_cat + count_cc) > 0
  end

  # Build persistent_id → current entityID lookup (once per load)
  def self.build_persistent_id_map(model)
    pid_map = {}
    model.definitions.each do |defn|
      next if defn.image?
      defn.instances.each do |inst|
        pid_map[inst.persistent_id.to_s] = inst.entityID if inst.respond_to?(:persistent_id)
      end
    end
    pid_map
  end

  # Save assignments as model-level JSON keyed by persistent_id (survives entity ID changes)
  def self.save_assignments_to_model
    m = Sketchup.active_model
    return unless m
    require 'json'

    # Build entityID → persistent_id map directly from model (doesn't depend on entity_registry)
    eid_to_pid = {}
    m.definitions.each do |defn|
      next if defn.image?
      defn.instances.each do |inst|
        eid_to_pid[inst.entityID] = inst.persistent_id.to_s if inst.respond_to?(:persistent_id)
      end
    end

    ca_by_pid = {}
    (@category_assignments || {}).each do |eid, cat|
      pid = eid_to_pid[eid]
      ca_by_pid[pid] = cat if pid && cat && !cat.empty?
    end
    cc_by_pid = {}
    (@cost_code_assignments || {}).each do |eid, cc|
      pid = eid_to_pid[eid]
      cc_by_pid[pid] = cc if pid && cc && !cc.empty?
    end

    m.set_attribute('FormAndField', 'saved_category_assignments', JSON.generate(ca_by_pid))
    m.set_attribute('FormAndField', 'saved_cost_code_assignments', JSON.generate(cc_by_pid))
  end

  # Count active definitions excluding CAD overlay groups
  def self.scannable_def_count(model)
    cad_defs = {}
    model.active_entities.grep(Sketchup::Group).each do |grp|
      next unless grp.valid? && grp.get_attribute('FF_CadOverlay', 'sheet_name')
      Scanner.mark_cad_skip_defs(grp.definition, cad_defs) if grp.respond_to?(:definition)
    end
    model.definitions.count { |d| !d.image? && d.instances.length > 0 && !cad_defs[d] }
  end

  # Save model-level scan metadata
  def self.save_scan_metadata(model)
    model.set_attribute('FormAndField', 'scan_version', PLUGIN_VERSION)
    model.set_attribute('FormAndField', 'scan_time', Time.now.to_i)
    model.set_attribute('FormAndField', 'scan_count', @scan_results.length)
    model.set_attribute('FormAndField', 'def_count', scannable_def_count(model))
  end

  # Persist scan results to entity attributes so data survives between sessions
  def self.save_scan_to_model
    m = Sketchup.active_model
    return unless m
    save_scan_metadata(m)
    count = 0
    @scan_results.each do |r|
      next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
      e = @entity_registry[r[:entity_id]]
      next unless e && e.valid?
      d = 'TakeoffScanData'
      e.set_attribute(d, 'display_name', r[:display_name].to_s)
      e.set_attribute(d, 'tag', r[:tag].to_s)
      e.set_attribute(d, 'auto_category', r[:parsed][:auto_category].to_s)
      e.set_attribute(d, 'auto_subcategory', (r[:parsed][:auto_subcategory] || '').to_s)
      e.set_attribute(d, 'measurement_type', (r[:parsed][:measurement_type] || '').to_s)
      e.set_attribute(d, 'category_source', (r[:parsed][:category_source] || '').to_s)
      e.set_attribute(d, 'is_solid', r[:is_solid] ? true : false)
      e.set_attribute(d, 'volume_ft3', r[:volume_ft3].to_f)
      e.set_attribute(d, 'area_sf', r[:area_sf] ? r[:area_sf].to_f : 0.0)
      e.set_attribute(d, 'linear_ft', r[:linear_ft].to_f)
      e.set_attribute(d, 'instance_count', r[:instance_count].to_i)
      e.set_attribute(d, 'material', (r[:material] || '').to_s)
      e.set_attribute(d, 'ifc_type', (r[:ifc_type] || '').to_s)
      e.set_attribute(d, 'element_type', (r[:parsed][:element_type] || '').to_s)
      e.set_attribute(d, 'function', (r[:parsed][:function] || '').to_s)
      e.set_attribute(d, 'parsed_material', (r[:parsed][:material] || '').to_s)
      e.set_attribute(d, 'thickness', (r[:parsed][:thickness] || '').to_s)
      e.set_attribute(d, 'size_nominal', (r[:parsed][:size_nominal] || '').to_s)
      e.set_attribute(d, 'revit_id', (r[:parsed][:revit_id] || '').to_s)
      e.set_attribute(d, 'confidence', (r[:parsed][:confidence] || '').to_s)
      e.set_attribute(d, 'cost_code_parsed', (r[:parsed][:cost_code] || '').to_s)

      # Catalog original materials for reliable restore after analysis
      inst_mat_name = e.material ? e.material.display_name : ''
      e.set_attribute(d, 'original_inst_mat', inst_mat_name)
      defn_obj = e.respond_to?(:definition) ? e.definition : nil
      if defn_obj
        fm_tally = {}
        defn_obj.entities.grep(Sketchup::Face).each do |f|
          fn = f.material ? f.material.display_name : nil
          fm_tally[fn] = (fm_tally[fn] || 0) + 1 if fn
          bn = f.back_material ? f.back_material.display_name : nil
          fm_tally[bn] = (fm_tally[bn] || 0) + 1 if bn
        end
        dominant = fm_tally.max_by { |_, c| c }&.first || ''
        e.set_attribute(d, 'original_face_mat', dominant)
      end

      count += 1
    end
    # Also save assignment maps keyed by persistent_id
    save_assignments_to_model
    puts "Takeoff: Saved #{count} scan results to model"
  rescue => e
    puts "Takeoff: save_scan_to_model error: #{e.message}"
  end

  # Reconstruct scan results from saved entity attributes (no expensive recomputation)
  def self.load_scan_from_model
    m = Sketchup.active_model
    return false unless m
    return false unless m.get_attribute('FormAndField', 'scan_version')

    Dashboard.heartbeat_start('Restoring scan data...') if defined?(Dashboard)
    puts "Takeoff: Loading saved scan data..."
    @scan_results = []
    @entity_registry = {}
    @category_assignments = {}
    @cost_code_assignments = {}

    m.definitions.each do |defn|
      next if defn.image?
      defn.instances.each do |inst|
        d = 'TakeoffScanData'
        auto_cat = inst.get_attribute(d, 'auto_category')
        next unless auto_cat && !auto_cat.empty?

        dname = defn.name || ''
        bb = inst.bounds
        w = bb.width.to_f; h = bb.height.to_f; dp = bb.depth.to_f

        vol_ft3 = (inst.get_attribute(d, 'volume_ft3') || 0.0).to_f
        vi3 = vol_ft3 * 1728.0

        conf_str = inst.get_attribute(d, 'confidence')
        conf_sym = case conf_str
          when 'high' then :high
          when 'medium' then :medium
          when 'low' then :low
          when 'none' then :none
          else nil
        end

        parsed = {
          raw: inst.get_attribute(d, 'display_name') || dname,
          element_type: inst.get_attribute(d, 'element_type'),
          function: inst.get_attribute(d, 'function'),
          material: inst.get_attribute(d, 'parsed_material'),
          thickness: inst.get_attribute(d, 'thickness'),
          size_nominal: inst.get_attribute(d, 'size_nominal'),
          revit_id: inst.get_attribute(d, 'revit_id'),
          auto_category: auto_cat,
          auto_subcategory: inst.get_attribute(d, 'auto_subcategory') || '',
          measurement_type: inst.get_attribute(d, 'measurement_type'),
          category_source: inst.get_attribute(d, 'category_source'),
          confidence: conf_sym,
          cost_code: inst.get_attribute(d, 'cost_code_parsed')
        }
        parsed.each { |k, v| parsed[k] = nil if v.is_a?(String) && v.empty? && k != :auto_subcategory }

        asf_raw = inst.get_attribute(d, 'area_sf')
        asf = (asf_raw && asf_raw.to_f > 0) ? asf_raw.to_f.round(2) : nil

        result = {
          entity_id: inst.entityID,
          entity_type: inst.typename,
          tag: inst.get_attribute(d, 'tag') || (inst.layer ? inst.layer.name : 'Untagged'),
          definition_name: dname,
          display_name: inst.get_attribute(d, 'display_name') || dname,
          instance_name: (inst.name && !inst.name.empty?) ? inst.name : nil,
          is_solid: inst.get_attribute(d, 'is_solid') || false,
          instance_count: (inst.get_attribute(d, 'instance_count') || 1).to_i,
          ifc_type: inst.get_attribute(d, 'ifc_type'),
          volume_in3: vi3.round(2),
          volume_ft3: vol_ft3.round(4),
          volume_bf: (vi3 / 144.0).round(2),
          bb_width_in: w.round(2), bb_height_in: h.round(2), bb_depth_in: dp.round(2),
          linear_ft: (inst.get_attribute(d, 'linear_ft') || 0.0).to_f.round(2),
          area_sf: asf,
          material: inst.get_attribute(d, 'material'),
          parsed: parsed, warnings: []
        }
        # Clean nil/empty ifc_type and material
        result[:ifc_type] = nil if result[:ifc_type].is_a?(String) && result[:ifc_type].empty?
        result[:material] = nil if result[:material].is_a?(String) && result[:material].empty?

        @scan_results << result
        @entity_registry[inst.entityID] = inst
      end
    end

    @scan_results.sort_by! { |r| [r[:tag] || 'zzz', r[:display_name] || ''] }

    load_saved_assignments
    load_custom_categories
    load_master_categories
    load_master_containers
    merge_scan_categories_into_master
    prune_empty_categories
    load_master_subcategories
    load_manual_measurements
    load_multiverse_data

    # Change detection (exclude CAD overlays from count)
    saved_defs = m.get_attribute('FormAndField', 'def_count') || 0
    current_scannable = scannable_def_count(m)
    current_full = m.definitions.count { |d| !d.image? && d.instances.length > 0 }

    if saved_defs > 0
      if saved_defs == current_full && current_full != current_scannable
        # Stored count used old method (included CAD) — migrate silently
        m.set_attribute('FormAndField', 'def_count', current_scannable)
        puts "Takeoff: Migrated def_count to exclude CAD overlays (#{saved_defs} -> #{current_scannable})"
      elsif (current_scannable - saved_defs).abs > [saved_defs * 0.1, 5].max
        puts "Takeoff: WARNING - Model changed since last scan (#{saved_defs} -> #{current_scannable} active defs). Consider rescanning."
      end
    end

    puts "Takeoff: Loaded #{@scan_results.length} elements from saved scan data"
    Dashboard.heartbeat_stop if defined?(Dashboard)
    true
  rescue => e
    Dashboard.heartbeat_stop if defined?(Dashboard)
    puts "Takeoff: load_scan_from_model error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    false
  end

end
