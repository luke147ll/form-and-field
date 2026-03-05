module TakeoffTool
  module Highlighter
    unless defined?(COLORS)
    COLORS = {
      'Drywall'=>[255,240,140],'Wall Framing'=>[255,180,100],'Walls'=>[240,200,160],
      'Wall Finish'=>[240,220,160],'Wall Structure'=>[220,170,120],'Wall Sheathing'=>[230,210,160],
      'Masonry / Veneer'=>[210,180,140],'Siding'=>[140,200,140],'Exterior Finish'=>[120,190,120],
      'Metal Roofing'=>[140,180,220],'Shingle Roofing'=>[160,140,180],'Roofing'=>[150,170,210],
      'Roof Framing'=>[200,150,100],'Roof Sheathing'=>[230,200,150],
      'Concrete'=>[170,170,170],'Flooring'=>[190,180,150],
      'Structural Lumber'=>[220,160,80],'Insulation'=>[255,180,220],'Membrane'=>[200,200,255],
      'Windows'=>[100,180,255],'Doors'=>[160,120,80],
      'Casework'=>[180,200,140],'Countertops'=>[200,180,160],
      'Ceilings'=>[160,200,230],'Plumbing'=>[100,200,200],
      'Hardware'=>[200,200,200],'Trim'=>[180,140,200],'Fascia'=>[180,160,200],
      'Soffit'=>[200,180,220],'Generic Models'=>[200,200,160],'Uncategorized'=>[255,100,100],
    }
    @orig_instance = {}   # entityID => original instance material
    @orig_faces = {}      # entityID => array of [face, original_material]
    @mats = {}
    @isolated_categories = nil  # nil = no isolation, Hash = { cat => true }
    @highlights_active = false
    @last_highlight_mode = nil  # :all or :category
    @last_highlight_sr = nil
    @last_highlight_ca = nil
    @last_highlight_cat = nil
    @active_cat_colors = {}  # cat_name => true for per-category inline toggles
    end # unless defined?(COLORS)

    def self.highlight_all(sr, ca)
      m = Sketchup.active_model
      return puts("HL: No model") unless m
      @last_highlight_mode = :all
      @last_highlight_sr = sr
      @last_highlight_ca = ca
      clear_all

      puts "HL: highlight_all called with #{sr.length} scan results"
      puts "HL: entity_registry has #{TakeoffTool.entity_registry.length} entries"

      @custom_colors = load_custom_colors

      m.start_operation('Highlight All', true)
      found = 0; colored = 0; missed = 0

      sr.each do |r|
        eid = r[:entity_id]
        e = TakeoffTool.find_entity(eid)

        unless e
          missed += 1
          puts "HL: MISS eid=#{eid} name=#{r[:display_name]}" if missed <= 5
          next
        end

        unless e.valid?
          missed += 1
          puts "HL: INVALID eid=#{eid}" if missed <= 5
          next
        end

        found += 1
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next if cat == '_IGNORE'

        sub = (e.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || ''
        mat = gmat_for_entity(m, eid, cat, sub)
        applied = apply_highlight(e, eid, mat)
        colored += 1 if applied
      end

      m.commit_operation
      @custom_colors = nil
      @highlights_active = true
      puts "HL: Done. found=#{found} colored=#{colored} missed=#{missed}"
    end

    def self.highlight_category(sr, ca, tc)
      m = Sketchup.active_model; return unless m
      @last_highlight_mode = :category
      @last_highlight_sr = sr
      @last_highlight_ca = ca
      @last_highlight_cat = tc
      clear_all
      @custom_colors = load_custom_colors
      m.start_operation('Highlight Cat', true); n=0
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == tc
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        sub = (e.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || ''
        mat = gmat_for_entity(m, r[:entity_id], cat, sub)
        apply_highlight(e, r[:entity_id], mat)
        n += 1
      end
      m.commit_operation
      @custom_colors = nil
      @highlights_active = true
      puts "HL: Category '#{tc}' highlighted #{n}"
    end

    def self.highlight_single(eid)
      m = Sketchup.active_model; return unless m
      eid = eid.to_i
      e = TakeoffTool.find_entity(eid)
      puts "HL: single eid=#{eid} found=#{!e.nil?} valid=#{e ? e.valid? : 'n/a'} type=#{e ? e.typename : 'n/a'}"
      return unless e && e.valid?
      m.start_operation('Highlight', true)
      apply_highlight(e, eid, selmat(m))
      m.commit_operation
    end

    def self.highlight_entities(ids)
      m = Sketchup.active_model; return unless m
      puts "HL: entities count=#{ids.length}"
      clear_all
      m.start_operation('Highlight Set', true)
      n = 0
      ids.each do |id|
        e = TakeoffTool.find_entity(id.to_i); next unless e && e.valid?
        apply_highlight(e, id.to_i, selmat(m))
        n += 1
      end
      m.commit_operation
      puts "HL: highlighted #{n} of #{ids.length}"
    end

    def self.clear_all
      m = Sketchup.active_model; return unless m
      m.start_operation('Clear HL', true)

      # Restore instance materials
      @orig_instance.each do |eid, orig_mat|
        e = TakeoffTool.find_entity(eid)
        if e && e.valid?
          begin
            mat_to_set = orig_mat
            # If saved material reference is no longer valid, look up by name
            if mat_to_set && mat_to_set.respond_to?(:valid?) && !mat_to_set.valid?
              name = mat_to_set.respond_to?(:display_name) ? mat_to_set.display_name : nil
              mat_to_set = name ? m.materials[name] : nil
            end
            e.material = mat_to_set
          rescue => ex
            puts "HL: restore instance eid=#{eid} failed: #{ex.message}"
            # Fallback: remove any material rather than leaving highlight stuck
            begin; e.material = nil; rescue; end
          end
        end
      end

      # Restore face materials
      @orig_faces.each do |_eid, face_list|
        restore_face_list(face_list)
      end

      # Don't remove highlight materials from the model — if any face/entity
      # wasn't properly restored, removing the material causes SketchUp to
      # replace it with nil (flat beige), which is worse than keeping the
      # highlight color. Unused materials can be purged by the user.
      @mats.clear

      @orig_instance.clear
      @orig_faces.clear

      m.commit_operation
      # Only clear active flag if this is a user-initiated clear (not an internal clear before re-highlight)
      unless @refreshing
        @highlights_active = false
        @last_highlight_mode = nil
        @active_cat_colors = {}
      end
    end

    def self.refresh_highlights
      return unless @highlights_active && @last_highlight_mode
      @refreshing = true
      begin
        if @last_highlight_mode == :all && @last_highlight_sr && @last_highlight_ca
          highlight_all(@last_highlight_sr, @last_highlight_ca)
        elsif @last_highlight_mode == :category && @last_highlight_sr && @last_highlight_ca && @last_highlight_cat
          highlight_category(@last_highlight_sr, @last_highlight_ca, @last_highlight_cat)
        end
      ensure
        @refreshing = false
      end
    end

    # Per-category inline color toggle — highlights one category, can stack
    def self.highlight_category_color(sr, ca, cat_name)
      m = Sketchup.active_model; return unless m
      cc = load_custom_colors
      hex = cc.dig('categories', cat_name)
      return unless hex

      m.start_operation('Color ' + cat_name, true)

      # Restore existing highlights for this category before re-applying with new color.
      # IMPORTANT: Do NOT delete from @orig_instance/@orig_faces here — keep the
      # true originals so apply_highlight (which uses `unless key?`) preserves them.
      # This prevents the original from being lost if a restore silently fails.
      sr.each do |r|
        eid = r[:entity_id]
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == cat_name
        e = TakeoffTool.find_entity(eid); next unless e && e.valid?
        if @orig_instance.key?(eid)
          begin; e.material = @orig_instance[eid]; rescue; end
        end
        if @orig_faces.key?(eid)
          restore_face_list(@orig_faces[eid])
        end
      end

      # Create material for this color
      c = hex_to_rgb(hex)
      unless c
        m.commit_operation
        return
      end
      k = "TO_CC_#{hex.gsub('#','')}"
      mt = @mats[k]
      unless mt
        mt = m.materials.add(k)
        mt.color = Sketchup::Color.new(*c)
        mt.alpha = 0.85
        @mats[k] = mt
      end

      # Apply to all entities in this category
      n = 0
      sr.each do |r|
        eid = r[:entity_id]
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == cat_name
        e = TakeoffTool.find_entity(eid); next unless e && e.valid?
        apply_highlight(e, eid, mt)
        n += 1
      end

      @active_cat_colors[cat_name] = true
      m.commit_operation
      puts "HL: Color ON '#{cat_name}' (#{n} entities, #{hex})"
    end

    # Clear per-category inline highlight — restore originals for one category
    def self.clear_category_color(sr, ca, cat_name)
      m = Sketchup.active_model; return unless m
      @active_cat_colors.delete(cat_name)

      m.start_operation('Uncolor ' + cat_name, true)
      n = 0
      sr.each do |r|
        eid = r[:entity_id]
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == cat_name
        e = TakeoffTool.find_entity(eid); next unless e && e.valid?
        if @orig_instance.key?(eid)
          begin
            mat_to_set = @orig_instance[eid]
            if mat_to_set && mat_to_set.respond_to?(:valid?) && !mat_to_set.valid?
              name = mat_to_set.respond_to?(:display_name) ? mat_to_set.display_name : nil
              mat_to_set = name ? m.materials[name] : nil
            end
            e.material = mat_to_set
          rescue => ex
            puts "HL: clear_category restore eid=#{eid} failed: #{ex.message}"
            begin; e.material = nil; rescue; end
          end
          @orig_instance.delete(eid)
          n += 1
        end
        if @orig_faces.key?(eid)
          restore_face_list(@orig_faces[eid])
          @orig_faces.delete(eid)
        end
      end

      m.commit_operation
      puts "HL: Color OFF '#{cat_name}' (#{n} entities restored)"
    end

    def self.active_cat_colors
      @active_cat_colors
    end

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

    # ─── Visibility ───

    # Walk up an entity's parent chain, collecting all ancestor
    # groups/components and their layers.  IFC models nest elements
    # inside IfcBuilding / IfcBuildingStorey containers — hiding a
    # container hides everything inside it.
    #
    # entity.parent returns the ComponentDefinition the entity lives
    # inside.  We need that definition's INSTANCES — those are the
    # actual model objects whose visibility matters.  Walk from
    # definition → instances → instance.parent → repeat until Model.
    def self.collect_ancestors(entity)
      ancestors = []
      layers    = []
      current   = entity

      while current
        # Record this entity's layer
        if current.respond_to?(:layer) && current.layer
          layers << current.layer
        end

        parent = current.respond_to?(:parent) ? current.parent : nil
        break unless parent

        if parent.is_a?(Sketchup::ComponentDefinition)
          # Parent is a definition — find ALL instances (the visible objects)
          parent.instances.each do |inst|
            ancestors << inst
            layers << inst.layer if inst.respond_to?(:layer) && inst.layer
          end
          # Continue walking up from the first instance
          current = parent.instances.first
        elsif parent.is_a?(Sketchup::Model)
          break  # Reached the top
        else
          # Entities collection or other intermediate — keep walking
          current = parent
        end
      end

      [ancestors, layers]
    end

    # Ensure ancestors of visible entities + their layers stay visible
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

      # Phase 1: Determine which entities to show (before touching visibility)
      visible = []
      found_cats = {}
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        found_cats[cat] = (found_cats[cat] || 0) + 1
        visible << e if cat == tc
      end

      puts "HL: isolate_category target='#{tc}' sr=#{sr.length} visible=#{visible.length} cats=#{found_cats.map{|k,v| "#{k}(#{v})"}.first(8).join(', ')}"

      # Safety: if no entities matched, don't hide everything
      if visible.empty?
        puts "HL: WARNING — no entities matched category '#{tc}', skipping isolate to avoid hiding all"
        return
      end

      # Phase 2: Collect ancestors BEFORE any hiding
      keep_ids, keep_layers = build_keep_visible_set(visible)

      # Phase 3: Apply visibility
      m.start_operation('Isolate', true)
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        e.visible = !!keep_ids[e.entityID]
      end
      # Force ancestors visible (they may not be in sr)
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

      # Phase 1
      visible = []
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        visible << e if id_set[r[:entity_id]]
      end

      puts "HL: isolate_entities requested=#{ids.length} matched=#{visible.length} sr=#{sr.length}"

      # Safety: if no entities matched, don't hide everything
      if visible.empty?
        puts "HL: WARNING — no entities matched the requested IDs, skipping isolate"
        return
      end

      # Phase 2
      keep_ids, keep_layers = build_keep_visible_set(visible)

      # Phase 3
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

      # Collect entities on the target tag and their ancestor layers
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

    def self.show_all
      @isolated_categories = nil
      m = Sketchup.active_model; return unless m
      m.start_operation('Show All', true)

      # Show all registry entities
      TakeoffTool.entity_registry.each_value { |e| e.visible = true if e && e.valid? }

      # Walk model hierarchy to restore any hidden ancestor containers
      show_hierarchy(m.entities)

      # Show all layers, but respect multiverse layer visibility
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

    # Show entities by ID and ensure their ancestors are visible
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

    # After an entity is reclassified, update its viewport visibility
    # to match the current isolation. Returns true if entity was hidden.
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

    # Build a complete set of entity IDs + layers that must stay visible.
    # Includes all target entities AND every ancestor in their parent chains.
    # Called BEFORE any visibility changes to avoid stale parent references.
    def self.build_keep_visible_set(visible_entities)
      keep_ids = {}
      keep_layers = { 'Layer0' => true, 'Untagged' => true }

      visible_entities.each do |e|
        keep_ids[e.entityID] = e
        # Add the entity's own layer
        if e.respond_to?(:layer) && e.layer
          keep_layers[e.layer.name] = true
        end
        # Walk up the parent chain
        ancs, lyrs = collect_ancestors(e)
        ancs.each { |a| keep_ids[a.entityID] = a }
        lyrs.each { |l| keep_layers[l.name] = true }
      end

      [keep_ids, keep_layers]
    end

    # Recursively walk model hierarchy, making all groups/components visible.
    # Used by show_all to restore hidden ancestor containers that aren't
    # in the entity_registry (e.g. IfcBuilding, IfcBuildingStorey).
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

    # Apply highlight to an entity. Sets instance-level material.
    # Also paints faces (and nested component faces) to override
    # face-level materials common in IFC imports.
    def self.apply_highlight(entity, eid, mat)
      # Only save the original if we haven't already — prevents overwriting
      # the TRUE original with a highlight material from a previous cycle
      # when restore silently fails and re-highlight re-saves.
      @orig_instance[eid] = entity.material unless @orig_instance.key?(eid)
      entity.material = mat

      defn = nil
      if entity.respond_to?(:definition)
        defn = entity.definition
      elsif entity.is_a?(Sketchup::Group)
        defn = entity.entities.parent
      end

      if defn && defn.respond_to?(:entities) && defn.respond_to?(:instances)
        if defn.instances.length <= 1
          if @orig_faces.key?(eid)
            # Already have saved originals — just repaint without overwriting the save
            repaint_faces_recursive(defn.entities, mat)
          else
            face_list = []
            paint_faces_recursive(defn.entities, mat, face_list)
            @orig_faces[eid] = face_list if face_list.length > 0
          end
        end
      end

      true
    rescue => e
      puts "HL: apply error eid=#{eid}: #{e.message}"
      false
    end

    # Repaint faces without saving originals (used when originals are already saved).
    def self.repaint_faces_recursive(ents, mat)
      ents.grep(Sketchup::Face).each do |face|
        face.material = mat
        face.back_material = mat
      end
      ents.each do |child|
        next unless child.valid?
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        next if child_defn.respond_to?(:instances) && child_defn.instances.length > 1
        child.material = mat
        repaint_faces_recursive(child_defn.entities, mat)
      end
    end

    # Recursively paint faces inside a definition and its nested children.
    # Saves [face, front_mat, back_mat] triples for faces, [inst, mat] pairs for instances.
    def self.paint_faces_recursive(ents, mat, face_list)
      ents.grep(Sketchup::Face).each do |face|
        face_list << [face, face.material, face.back_material]
        face.material = mat
        face.back_material = mat
      end
      # Recurse into nested components/groups
      ents.each do |child|
        next unless child.valid?
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        # Only paint if this child definition isn't shared outside this parent
        next if child_defn.respond_to?(:instances) && child_defn.instances.length > 1
        # Also set instance material on the nested child
        face_list << [child, child.material] if child.respond_to?(:material)
        child.material = mat
        paint_faces_recursive(child_defn.entities, mat, face_list)
      end
    end

    # Restore saved face/instance materials from a face_list.
    # Handles both [face, front, back] triples and [inst, mat] pairs.
    def self.restore_face_list(face_list)
      face_list.each do |entry|
        begin
          obj = entry[0]
          next unless obj.valid?
          saved_mat = entry[1]
          # If saved material reference is no longer valid, look up by name
          if saved_mat && saved_mat.respond_to?(:valid?) && !saved_mat.valid?
            name = saved_mat.respond_to?(:display_name) ? saved_mat.display_name : nil
            saved_mat = name ? Sketchup.active_model.materials[name] : nil
          end
          obj.material = saved_mat
          # Restore back_material for faces (3-element entries)
          if entry.length > 2 && obj.respond_to?(:back_material=)
            saved_back = entry[2]
            if saved_back && saved_back.respond_to?(:valid?) && !saved_back.valid?
              name = saved_back.respond_to?(:display_name) ? saved_back.display_name : nil
              saved_back = name ? Sketchup.active_model.materials[name] : nil
            end
            obj.back_material = saved_back
          end
        rescue => ex
          puts "HL: restore face error: #{ex.message}"
          # Fallback: clear the material rather than leaving highlight stuck
          begin; obj.material = nil; rescue; end
        end
      end
    end

    # Load the full custom colors map from model attributes.
    # In multiverse mode, reads the per-view key (custom_colors_model_a/b)
    # so per-category colors picked in [A] or [B] view are found.
    def self.load_custom_colors
      require 'json'
      mv_view = TakeoffTool.active_mv_view rescue nil
      if mv_view && mv_view != 'ab'
        key = (mv_view == 'a') ? 'custom_colors_model_a' : 'custom_colors_model_b'
        json = Sketchup.active_model.get_attribute('FormAndField', key, nil)
        if json
          return (JSON.parse(json) rescue {})
        end
      end
      json = Sketchup.active_model.get_attribute('FormAndField', 'custom_colors', '{}')
      JSON.parse(json) rescue {}
    end

    # Resolve custom hex for an entity: entity > subcategory > category > nil
    def self.resolve_custom_hex(eid, cat, sub)
      cc = @custom_colors || load_custom_colors
      cc.dig('entities', eid.to_s) ||
        (sub && !sub.empty? && cc.dig('subcategories', "#{cat}|#{sub}")) ||
        cc.dig('categories', cat)
    end

    # Parse hex string "#rrggbb" to [r,g,b] array
    def self.hex_to_rgb(hex)
      return nil unless hex && hex.length >= 7
      [hex[1..2].to_i(16), hex[3..4].to_i(16), hex[5..6].to_i(16)]
    end

    # Get or create a highlight material for a specific entity, checking
    # entity > subcategory > category custom colors, then default
    def self.gmat_for_entity(m, eid, cat, sub)
      custom_hex = resolve_custom_hex(eid, cat, sub)
      if custom_hex
        # Use a material key that includes the hex so different colors don't collide
        k = "TO_CC_#{custom_hex.gsub('#','')}"
        mt = @mats[k]
        unless mt
          c = hex_to_rgb(custom_hex) || COLORS[cat] || COLORS['Uncategorized']
          mt = m.materials.add(k)
          mt.color = Sketchup::Color.new(*c)
          mt.alpha = 0.85
          @mats[k] = mt
        end
        mt
      else
        gmat(m, cat)
      end
    end

    # Get or create a category-level highlight material (default colors + category custom)
    def self.gmat(m, cat)
      k = "TO_#{cat.gsub(/[^a-zA-Z0-9]/, '_')}"
      mt = @mats[k]
      unless mt
        cc = @custom_colors || load_custom_colors
        custom_hex = cc.dig('categories', cat)
        if custom_hex
          c = hex_to_rgb(custom_hex) || COLORS[cat] || COLORS['Uncategorized']
        else
          c = COLORS[cat] || COLORS['Uncategorized']
        end
        mt = m.materials.add(k)
        mt.color = Sketchup::Color.new(*c)
        mt.alpha = 0.85
        @mats[k] = mt
      end
      mt
    end

    def self.clear_cached_material(cat)
      k = "TO_#{cat.gsub(/[^a-zA-Z0-9]/, '_')}"
      @mats.delete(k)
    end

    def self.selmat(m)
      mt = @mats['TO_sel']
      unless mt
        mt = m.materials.add('TO_sel')
        mt.color = Sketchup::Color.new(255, 255, 0)
        mt.alpha = 0.9
        @mats['TO_sel'] = mt
      end
      mt
    end
  end
end
