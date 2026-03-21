module TakeoffTool
  module Highlighter
    unless defined?(COLORS)
    COLORS = ColorController::DEFAULT_COLORS
    @isolated_categories = nil  # nil = no isolation, Hash = { cat => true }
    end # unless defined?(COLORS)

    # ─── Color delegations to ColorController ───

    def self.highlight_all(sr, ca)
      ColorController.highlight_all(sr, ca)
    end

    def self.highlight_category(sr, ca, tc)
      ColorController.highlight_category(sr, ca, tc)
    end

    def self.highlight_single(eid)
      ColorController.highlight_single(eid)
    end

    def self.highlight_entities(ids)
      ColorController.highlight_entities(ids)
    end

    def self.highlight_category_color(sr, ca, cat_name)
      ColorController.highlight_category_color(sr, ca, cat_name)
    end

    def self.clear_category_color(sr, ca, cat_name)
      ColorController.clear_category_color(sr, ca, cat_name)
    end

    def self.clear_all
      ColorController.deactivate
    end

    def self.refresh_highlights
      ColorController.refresh_highlights
    end

    def self.clear_cached_material(cat)
      ColorController.clear_cached_material(cat)
    end

    def self.active_cat_colors
      ColorController.active_cat_colors
    end

    def self.highlights_active?
      ColorController.highlights_active?
    end

    # ─── Measurement visibility (all types use group.visible) ───

    def self.clear_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide Measurement HL', true)
      hide_measurement_highlights_inner(m)
      m.commit_operation
    end

    # Non-destructive hide: hides all measurement groups (skip GRID tags — those toggle with gridlines)
    def self.hide_measurement_highlights_inner(m)
      hidden = 0
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        next if mtype == 'GRID' || mtype == 'CARD'
        if grp.visible?
          grp.visible = false
          hidden += 1
        end
        grp.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
      end

      puts "Takeoff: Hid measurement highlights (#{hidden} groups hidden)" if hidden > 0
    end

    # ─── Measurement visibility controls ───

    def self.hide_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide All Measurements', true)
      hide_measurement_highlights_inner(m)
      m.commit_operation
    end

    def self.show_all_measurement_highlights
      m = Sketchup.active_model; return unless m
      TakeoffTool.refresh_sf_material_colors rescue nil
      m.start_operation('Show All Measurements', true)
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        next if mtype == 'GRID' || mtype == 'CARD'
        grp.visible = true
        grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      end
      m.commit_operation
    end

    def self.hide_all_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide All Measurements', true)
      hide_measurement_highlights_inner(m)
      m.commit_operation
    end

    def self.show_measurement_highlight(grp_eid)
      m = Sketchup.active_model; return unless m
      grp = TakeoffTool.find_entity(grp_eid.to_i)
      return unless grp && grp.valid?
      mtype = grp.get_attribute('TakeoffMeasurement', 'type')
      return unless mtype

      m.start_operation('Show Measurement', true)
      grp.visible = true
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      m.commit_operation
    end

    def self.hide_measurement_highlight(grp_eid)
      m = Sketchup.active_model; return unless m
      grp = TakeoffTool.find_entity(grp_eid.to_i)
      return unless grp && grp.valid?
      mtype = grp.get_attribute('TakeoffMeasurement', 'type')
      return unless mtype

      m.start_operation('Hide Measurement', true)
      grp.visible = false
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
      m.commit_operation
    end

    def self.delete_measurement(grp_eid)
      m = Sketchup.active_model; return unless m
      grp = TakeoffTool.find_entity(grp_eid.to_i)
      return unless grp && grp.valid?

      m.start_operation('Delete Measurement', true)

      # Remove from registries
      eid = grp.entityID
      TakeoffTool.entity_registry.delete(eid)
      TakeoffTool.scan_results.reject! { |r| r[:entity_id] == eid }
      TakeoffTool.category_assignments.delete(eid)
      TakeoffTool.cost_code_assignments.delete(eid)

      # Erase the group
      grp.erase! if grp.valid?
      m.commit_operation
      puts "Takeoff: Deleted measurement eid=#{eid}"
    end

    # ─── Visibility ───

    def self.collect_ancestors(entity)
      ancestors = []
      layers    = []
      current   = entity

      while current
        if current.respond_to?(:layer) && current.layer
          layers << current.layer
        end

        parent = current.respond_to?(:parent) ? current.parent : nil
        break unless parent

        if parent.is_a?(Sketchup::ComponentDefinition)
          parent.instances.each do |inst|
            ancestors << inst
            layers << inst.layer if inst.respond_to?(:layer) && inst.layer
          end
          current = parent.instances.first
        elsif parent.is_a?(Sketchup::Model)
          break
        else
          current = parent
        end
      end

      [ancestors, layers]
    end

    def self.ensure_ancestors_visible(visible_entities, m)
      ancestor_ids = {}
      ancestor_layer_names = { 'Layer0' => true, 'Untagged' => true }
      visible_entities.each do |e|
        ancs, lyrs = collect_ancestors(e)
        ancs.each { |a| ancestor_ids[a.entityID] = a }
        lyrs.each { |l| ancestor_layer_names[l.name] = true }
      end
      ancestor_ids.each_value do |a|
        a.visible = true if a.valid? && !a.visible?
      end
      ancestor_layer_names.each_key do |ln|
        l = m.layers[ln]
        l.visible = true if l && !l.visible?
      end
    end

    def self.isolate_category(sr, ca, tc)
      m = Sketchup.active_model; return unless m

      visible = []
      found_cats = {}
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        found_cats[cat] = (found_cats[cat] || 0) + 1
        visible << e if cat == tc
      end

      puts "HL: isolate_category target='#{tc}' sr=#{sr.length} visible=#{visible.length} cats=#{found_cats.map{|k,v| "#{k}(#{v})"}.first(8).join(', ')}"

      if visible.empty?
        puts "HL: WARNING — no entities matched category '#{tc}', skipping isolate to avoid hiding all"
        return
      end

      keep_ids, keep_layers = build_keep_visible_set(visible)

      m.start_operation('Isolate', true)
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        e.visible = !!keep_ids[e.entityID]
      end
      keep_ids.each_value { |a| a.visible = true if a.valid? && !a.visible? }
      keep_layers.each_key do |ln|
        l = m.layers[ln]; l.visible = true if l && !l.visible?
      end
      m.commit_operation
      @isolated_categories = { tc => true }
      puts "HL: isolate done — kept #{keep_ids.length} entities, #{keep_layers.length} layers visible"
    end

    def self.isolate_entities(sr, ids)
      @isolated_categories = nil
      m = Sketchup.active_model; return unless m
      id_set = {}
      ids.each { |id| id_set[id] = true }

      visible = []
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        visible << e if id_set[r[:entity_id]]
      end

      puts "HL: isolate_entities requested=#{ids.length} matched=#{visible.length} sr=#{sr.length}"

      if visible.empty?
        puts "HL: WARNING — no entities matched the requested IDs, skipping isolate"
        return
      end

      keep_ids, _keep_layers = build_keep_visible_set(visible)

      m.start_operation('Isolate Entities', true)
      # Hide all scan entities not in keep set
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        e.visible = !!keep_ids[e.entityID]
      end
      # Ensure ancestors of visible entities are shown (parent groups/components)
      keep_ids.each_value { |a| a.visible = true if a.valid? && !a.visible? }
      # NOTE: We intentionally do NOT force layers visible here.
      # Entity-level isolation uses entity.visible only — forcing layers
      # visible would un-hide non-scan entities on shared layers (e.g. casework).
      m.commit_operation
      puts "HL: isolate_entities done — kept #{keep_ids.length} entities"
    end

    def self.isolate_tag(tn)
      @isolated_categories = nil
      m = Sketchup.active_model; return unless m
      m.start_operation('Isolate Tag', true)

      keep_layers = { 'Layer0' => true, 'Untagged' => true, tn => true }
      TakeoffTool.entity_registry.each_value do |e|
        next unless e && e.valid?
        next unless e.respond_to?(:layer) && e.layer && e.layer.name == tn
        _ancs, lyrs = collect_ancestors(e)
        lyrs.each { |l| keep_layers[l.name] = true }
      end

      m.layers.each do |l|
        # Preserve CAD overlay, gridline, and elevation tag layer visibility
        next if l.name.start_with?('FF_CAD_') || l.name == 'FF_Gridlines' || l.name == 'FF_Elevation_Tags'
        l.visible = !!keep_layers[l.name]
      end
      m.commit_operation
    end

    def self.clear_isolate_state
      @isolated_categories = nil
    end

    def self.show_all
      @isolated_categories = nil
      m = Sketchup.active_model; return unless m
      m.start_operation('Show All', true)

      TakeoffTool.entity_registry.each_value do |e|
        next unless e && e.valid?
        next if cad_or_grid?(e)
        e.visible = true
      end
      show_hierarchy(m.entities)

      mv_view = TakeoffTool.active_mv_view rescue nil
      m.layers.each do |l|
        if mv_view == 'a' && (l.name == 'FF_Model_B')
          l.visible = false
        elsif mv_view == 'b' && (l.name == 'FF_Model_A')
          l.visible = false
        elsif l.name.start_with?('FF_CAD_') || l.name == 'FF_Gridlines' || l.name == 'FF_Elevation_Tags'
          # Leave CAD overlay, gridline, and elevation tag layers in their current state
        else
          l.visible = true
        end
      end
      m.commit_operation
    end

    def self.hide_category(sr, ca, tc)
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide Category', true)
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == tc
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        e.visible = false
      end
      m.commit_operation
    end

    def self.show_category(sr, ca, tc)
      m = Sketchup.active_model; return unless m
      visible = []
      m.start_operation('Show Category', true)
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == tc
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        e.visible = true
        visible << e
      end
      ensure_ancestors_visible(visible, m) if visible.any?
      m.commit_operation
    end

    def self.show_entities_with_ancestors(ids)
      m = Sketchup.active_model; return unless m
      visible = []
      m.start_operation('Show', true)
      ids.each do |id|
        e = TakeoffTool.find_entity(id.to_i)
        next unless e && e.valid?
        e.visible = true
        visible << e
      end
      ensure_ancestors_visible(visible, m)
      m.commit_operation
    end

    def self.isolated_categories
      @isolated_categories
    end

    def self.update_entity_isolation(eid, new_cat)
      return nil unless @isolated_categories
      e = TakeoffTool.find_entity(eid)
      return nil unless e && e.valid?
      m = Sketchup.active_model
      return nil unless m

      should_show = !!@isolated_categories[new_cat]

      m.start_operation('Update Isolation', true)
      if should_show && !e.visible?
        e.visible = true
        ancs, lyrs = collect_ancestors(e)
        ancs.each { |a| a.visible = true if a.valid? && !a.visible? }
        lyrs.each { |l| l.visible = true if l && !l.visible? }
        if e.respond_to?(:layer) && e.layer
          e.layer.visible = true unless e.layer.visible?
        end
      elsif !should_show && e.visible?
        e.visible = false
      end
      m.commit_operation

      !should_show
    end

    private

    # Returns true for groups that have their own visibility controls
    # and should not be touched by show_all/isolate/hide_category.
    def self.cad_or_grid?(e)
      return false unless e.is_a?(Sketchup::Group)
      return true if e.get_attribute('FF_CadOverlay', 'sheet_name')
      return true if e.get_attribute('TakeoffGridline', 'label')
      return true if e.get_attribute('TakeoffMeasurement', 'type')
      false
    rescue
      false
    end

    def self.build_keep_visible_set(visible_entities)
      keep_ids = {}
      keep_layers = { 'Layer0' => true, 'Untagged' => true }

      visible_entities.each do |e|
        keep_ids[e.entityID] = e
        if e.respond_to?(:layer) && e.layer
          keep_layers[e.layer.name] = true
        end
        ancs, lyrs = collect_ancestors(e)
        ancs.each { |a| keep_ids[a.entityID] = a }
        lyrs.each { |l| keep_layers[l.name] = true }
      end

      [keep_ids, keep_layers]
    end

    def self.show_hierarchy(ents)
      ents.each do |e|
        next unless e.valid?
        if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if cad_or_grid?(e)
          e.visible = true unless e.visible?
          defn = e.respond_to?(:definition) ? e.definition : nil
          show_hierarchy(defn.entities) if defn
        end
      end
    end
  end
end
