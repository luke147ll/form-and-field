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

    # ─── Measurement methods (UNCHANGED — use FF_Original entity attrs, not originals cache) ───

    def self.clear_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide Measurement HL', true)
      hide_measurement_highlights_inner(m)
      m.commit_operation
    end

    # Non-destructive hide: restores SF face materials but keeps FF_Original attrs
    def self.hide_measurement_highlights_inner(m)
      restored = 0

      # Restore SF-colored faces inside all definitions (components/groups)
      m.definitions.each do |defn|
        next if defn.image?
        defn.entities.grep(Sketchup::Face).each do |face|
          orig_name = face.get_attribute('FF_Original', 'material')
          next unless orig_name
          face.material = orig_name.empty? ? nil : m.materials[orig_name]
          # Keep FF_Original attrs for re-show
          restored += 1
        end
      end

      # Restore loose faces in model entities
      m.entities.grep(Sketchup::Face).each do |face|
        orig_name = face.get_attribute('FF_Original', 'material')
        next unless orig_name
        face.material = orig_name.empty? ? nil : m.materials[orig_name]
        restored += 1
      end

      # Hide LF ribbon groups
      hidden = 0
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        if (mtype == 'LF' || mtype == 'ELEV' || mtype == 'BENCHMARK') && grp.visible?
          grp.visible = false
          hidden += 1
        end
        grp.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
      end

      puts "Takeoff: Hid measurement highlights (#{restored} faces restored, #{hidden} ribbons hidden)" if restored > 0 || hidden > 0
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
      m.start_operation('Show All Measurements', true)
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        if mtype == 'LF'
          grp.visible = true
        elsif mtype == 'SF'
          show_sf_measurement_faces(m, grp)
        elsif mtype == 'ELEV' || mtype == 'BENCHMARK'
          grp.visible = true
        end
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
      if mtype == 'LF'
        grp.visible = true
      elsif mtype == 'SF'
        show_sf_measurement_faces(m, grp)
      elsif mtype == 'ELEV' || mtype == 'BENCHMARK'
        grp.visible = true
      end
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
      if mtype == 'LF'
        grp.visible = false
      elsif mtype == 'SF'
        hide_sf_measurement_faces(m, grp)
      elsif mtype == 'ELEV' || mtype == 'BENCHMARK'
        grp.visible = false
      end
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
      m.commit_operation
    end

    def self.delete_measurement(grp_eid)
      m = Sketchup.active_model; return unless m
      grp = TakeoffTool.find_entity(grp_eid.to_i)
      return unless grp && grp.valid?
      mtype = grp.get_attribute('TakeoffMeasurement', 'type')

      m.start_operation('Delete Measurement', true)
      if mtype == 'SF'
        delete_sf_measurement_faces(m, grp)
      end

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

    private

    # Resolve face references stored in group attrs
    def self.resolve_face_refs(m, grp)
      require 'json'
      refs_json = grp.get_attribute('TakeoffMeasurement', 'face_refs')
      return [] unless refs_json
      begin
        refs = JSON.parse(refs_json)
      rescue
        return []
      end
      faces = []
      refs.each do |ref|
        face = nil
        # Try persistent_id first
        pid = ref['pid']
        if pid
          face = find_face_by_persistent_id(m, pid)
        end
        # Fallback: defn + fidx
        unless face
          defn_name = ref['defn']
          fidx = ref['fidx']
          if defn_name && fidx && fidx >= 0
            if defn_name == '__model__'
              all_faces = m.entities.grep(Sketchup::Face)
              face = all_faces[fidx] if fidx < all_faces.length
            else
              defn = m.definitions[defn_name]
              if defn
                all_faces = defn.entities.grep(Sketchup::Face)
                face = all_faces[fidx] if fidx < all_faces.length
              end
            end
          end
        end
        faces << face if face && face.valid?
      end
      faces
    end

    def self.find_face_by_persistent_id(m, pid)
      # Search loose model entities
      m.entities.grep(Sketchup::Face).each do |f|
        return f if f.respond_to?(:persistent_id) && f.persistent_id == pid
      end
      # Search definitions
      m.definitions.each do |defn|
        next if defn.image?
        defn.entities.grep(Sketchup::Face).each do |f|
          return f if f.respond_to?(:persistent_id) && f.persistent_id == pid
        end
      end
      nil
    end

    def self.show_sf_measurement_faces(m, grp)
      require 'json'
      mat_name = grp.get_attribute('TakeoffMeasurement', 'material_name')
      rgba_json = grp.get_attribute('TakeoffMeasurement', 'color_rgba')
      return unless mat_name

      # Get or create the material
      mat = m.materials[mat_name]
      unless mat
        rgba = begin; JSON.parse(rgba_json); rescue; [255, 100, 255, 140]; end
        mat = m.materials.add(mat_name)
        mat.color = Sketchup::Color.new(rgba[0], rgba[1], rgba[2])
        mat.alpha = (rgba[3] || 140) / 255.0
      end

      faces = resolve_face_refs(m, grp)
      faces.each do |face|
        begin
          # Save original material if not already saved
          unless face.get_attribute('FF_Original', 'material')
            orig_name = face.material ? face.material.display_name : ''
            face.set_attribute('FF_Original', 'material', orig_name)
          end
          face.material = mat
        rescue => e
          puts "HL: show_sf face error: #{e.message}"
        end
      end
    end

    def self.hide_sf_measurement_faces(m, grp)
      faces = resolve_face_refs(m, grp)
      faces.each do |face|
        begin
          orig_name = face.get_attribute('FF_Original', 'material')
          next unless orig_name
          face.material = orig_name.empty? ? nil : m.materials[orig_name]
          # Keep FF_Original attrs for re-show
        rescue => e
          puts "HL: hide_sf face error: #{e.message}"
        end
      end
    end

    def self.delete_sf_measurement_faces(m, grp)
      faces = resolve_face_refs(m, grp)
      faces.each do |face|
        begin
          orig_name = face.get_attribute('FF_Original', 'material')
          if orig_name
            face.material = orig_name.empty? ? nil : m.materials[orig_name]
          end
          face.delete_attribute('FF_Original', 'material')
          face.delete_attribute('FF_Original', 'group_eid')
          face.delete_attribute('FF_Original') rescue nil
        rescue => e
          puts "HL: delete_sf face error: #{e.message}"
        end
      end
    end

    # ─── Visibility (UNCHANGED) ───

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

      keep_ids, keep_layers = build_keep_visible_set(visible)

      m.start_operation('Isolate Entities', true)
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        e.visible = !!keep_ids[e.entityID]
      end
      keep_ids.each_value { |a| a.visible = true if a.valid? && !a.visible? }
      keep_layers.each_key do |ln|
        l = m.layers[ln]; l.visible = true if l && !l.visible?
      end
      m.commit_operation
      puts "HL: isolate_entities done — kept #{keep_ids.length} entities, #{keep_layers.length} layers"
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

      m.layers.each { |l| l.visible = !!keep_layers[l.name] }
      m.commit_operation
    end

    def self.clear_isolate_state
      @isolated_categories = nil
    end

    def self.show_all
      @isolated_categories = nil
      m = Sketchup.active_model; return unless m
      m.start_operation('Show All', true)

      TakeoffTool.entity_registry.each_value { |e| e.visible = true if e && e.valid? }
      show_hierarchy(m.entities)

      mv_view = TakeoffTool.active_mv_view rescue nil
      m.layers.each do |l|
        if mv_view == 'a' && (l.name == 'FF_Model_B')
          l.visible = false
        elsif mv_view == 'b' && (l.name == 'FF_Model_A')
          l.visible = false
        else
          l.visible = true
        end
      end
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
          e.visible = true unless e.visible?
          defn = e.respond_to?(:definition) ? e.definition : nil
          show_hierarchy(defn.entities) if defn
        end
      end
    end
  end
end
