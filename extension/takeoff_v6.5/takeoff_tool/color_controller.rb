module TakeoffTool
  module ColorController
    DEFAULT_OPACITY   = 0.85
    FOCUS_DIM_OPACITY = 0.15
    DIFF_COLORS       = { a: [166, 227, 161], b: [137, 180, 250] }
    DIFF_OPACITY      = 100 / 255.0
    FOCUS_COLOR       = [203, 166, 247]
    SELECTION_COLOR   = [255, 255, 0]

    DEFAULT_COLORS = {
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

    # ─── State ───

    @originals       = {}   # eid => { instance: mat, faces: [[face, front_mat, back_mat], ...] }
    @mats            = {}   # key => Sketchup::Material
    @color_settings  = {}   # level => { key => { 'color' => '#hex', 'opacity' => float } }
    @level_to_mat_key = {}  # "level:key" => material key string
    @active_mode     = :none  # :none | :highlight | :diff | :focus
    @model_view      = nil    # :a | :b | :ab | nil
    @highlights_active = false
    @highlight_state = nil    # { mode:, sr:, ca:, cat: }
    @active_cat_colors = {}   # cat_name => true
    @refreshing      = false
    @diff_active     = false
    @diff_data       = nil
    @diff_orig_mats  = nil    # kept separate for multiverse async batching compatibility

    # ─── Originals Cache ───

    def self.backup(eid, entity)
      return if @originals.key?(eid)
      inst_mat = entity.material
      if inst_mat && inst_mat.respond_to?(:name) && inst_mat.name.start_with?('FF_')
        inst_mat = nil
      end
      entry = { instance: inst_mat, faces: nil }

      defn = nil
      if entity.respond_to?(:definition)
        defn = entity.definition
      elsif entity.is_a?(Sketchup::Group)
        defn = entity.entities.parent
      end

      if defn && defn.respond_to?(:entities) && defn.respond_to?(:instances)
        if defn.instances.length <= 1
          face_list = []
          collect_face_originals(defn.entities, face_list)
          entry[:faces] = face_list if face_list.length > 0
        end
      end

      @originals[eid] = entry
    end

    def self.original_material(eid)
      entry = @originals[eid]
      entry ? entry[:instance] : nil
    end

    def self.restore(eid)
      entry = @originals.delete(eid)
      return unless entry

      e = TakeoffTool.find_entity(eid)
      if e && e.valid?
        safe_set_material(e, entry[:instance])
      end

      if entry[:faces]
        entry[:faces].each do |arr|
          obj = arr[0]
          next unless obj.valid?
          if arr.length == 3
            # [face, front_mat, back_mat]
            safe_set_material(obj, arr[1])
            safe_set_back_material(obj, arr[2])
          else
            # [inst, mat] pair for nested components
            safe_set_material(obj, arr[1])
          end
        end
      end
    end

    def self.restore_all
      m = Sketchup.active_model
      return unless m
      m.start_operation('CC Restore All', true)

      @originals.each_key do |eid|
        entry = @originals[eid]
        e = TakeoffTool.find_entity(eid)
        if e && e.valid?
          safe_set_material(e, entry[:instance])
        end
        next unless entry[:faces]
        entry[:faces].each do |arr|
          obj = arr[0]
          next unless obj.valid?
          if arr.length == 3
            safe_set_material(obj, arr[1])
            safe_set_back_material(obj, arr[2])
          else
            safe_set_material(obj, arr[1])
          end
        end
      end

      @originals.clear
      @mats.clear
      m.commit_operation
    end

    def self.backed_up?(eid)
      @originals.key?(eid)
    end

    # Recursive: saves [face, front_mat, back_mat] triples and [inst, mat] pairs
    def self.collect_face_originals(ents, list)
      ents.grep(Sketchup::Face).each do |face|
        fm = face.material
        bm = face.back_material
        fm = nil if fm && fm.respond_to?(:name) && fm.name.start_with?('FF_')
        bm = nil if bm && bm.respond_to?(:name) && bm.name.start_with?('FF_')
        list << [face, fm, bm]
      end
      ents.each do |child|
        next unless child.valid?
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        next if child_defn.respond_to?(:instances) && child_defn.instances.length > 1
        if child.respond_to?(:material)
          cm = child.material
          cm = nil if cm && cm.respond_to?(:name) && cm.name.start_with?('FF_')
          list << [child, cm]
        end
        collect_face_originals(child_defn.entities, list)
      end
    end

    def self.safe_set_material(obj, mat)
      mat_to_set = mat
      if mat_to_set && mat_to_set.respond_to?(:valid?) && !mat_to_set.valid?
        name = mat_to_set.respond_to?(:display_name) ? mat_to_set.display_name : nil
        mat_to_set = name ? Sketchup.active_model.materials[name] : nil
      end
      obj.material = mat_to_set
    rescue => ex
      puts "CC: safe_set_material error: #{ex.message}"
      begin; obj.material = nil; rescue; end
    end

    def self.safe_set_back_material(obj, mat)
      return unless obj.respond_to?(:back_material=)
      mat_to_set = mat
      if mat_to_set && mat_to_set.respond_to?(:valid?) && !mat_to_set.valid?
        name = mat_to_set.respond_to?(:display_name) ? mat_to_set.display_name : nil
        mat_to_set = name ? Sketchup.active_model.materials[name] : nil
      end
      obj.back_material = mat_to_set
    rescue => ex
      puts "CC: safe_set_back_material error: #{ex.message}"
      begin; obj.back_material = nil; rescue; end
    end

    # ─── Material Factory ───

    def self.get_or_create_material(model, key, rgb, alpha)
      mt = @mats[key]
      return mt if mt && mt.valid?
      mt = model.materials[key] || model.materials.add(key)
      mt.color = Sketchup::Color.new(*rgb)
      mt.alpha = alpha
      @mats[key] = mt
      mt
    end

    def self.clear_cached_material(key)
      k = "FF_HL_#{key.gsub(/[^a-zA-Z0-9]/, '_')}"
      @mats.delete(k)
      # Also clear custom-color keyed materials
      @mats.delete_if { |mk, _| mk.start_with?("FF_CC_") }
    end

    # ─── Color Resolution ───

    def self.resolve_color(eid, cat, sub, container)
      cs = @color_settings
      # Entity-level
      ec = cs.dig('entities', eid.to_s)
      return hex_to_rgb(ec['color']) if ec && ec['color']
      # Subcategory-level
      if sub && !sub.empty?
        sk = "#{cat}|#{sub}"
        sc = cs.dig('subcategories', sk)
        return hex_to_rgb(sc['color']) if sc && sc['color']
      end
      # Category-level
      cc = cs.dig('categories', cat)
      return hex_to_rgb(cc['color']) if cc && cc['color']
      # Container-level (custom override)
      if container && !container.empty?
        ctc = cs.dig('containers', container)
        return hex_to_rgb(ctc['color']) if ctc && ctc['color']
        # Container's own color from master_containers
        cont_obj = (TakeoffTool.master_containers || []).find { |c| c['name'] == container }
        return hex_to_rgb(cont_obj['color']) if cont_obj && cont_obj['color']
      end
      # Default
      DEFAULT_COLORS[cat] || DEFAULT_COLORS['Uncategorized']
    end

    def self.resolve_opacity(eid, cat, sub, container)
      cs = @color_settings
      ec = cs.dig('entities', eid.to_s)
      return ec['opacity'] if ec && ec['opacity']
      if sub && !sub.empty?
        sk = "#{cat}|#{sub}"
        sc = cs.dig('subcategories', sk)
        return sc['opacity'] if sc && sc['opacity']
      end
      cc = cs.dig('categories', cat)
      return cc['opacity'] if cc && cc['opacity']
      if container && !container.empty?
        ctc = cs.dig('containers', container)
        return ctc['opacity'] if ctc && ctc['opacity']
      end
      DEFAULT_OPACITY
    end

    # Build a material key for a given entity's cascade resolution
    def self.mat_key_for(eid, cat, sub, container)
      cs = @color_settings
      if cs.dig('entities', eid.to_s)
        hex = cs.dig('entities', eid.to_s, 'color')
        return "FF_CC_#{hex.gsub('#','')}" if hex
      end
      if sub && !sub.empty?
        sk = "#{cat}|#{sub}"
        if cs.dig('subcategories', sk)
          hex = cs.dig('subcategories', sk, 'color')
          return "FF_CC_#{hex.gsub('#','')}" if hex
        end
      end
      if cs.dig('categories', cat)
        hex = cs.dig('categories', cat, 'color')
        return "FF_CC_#{hex.gsub('#','')}" if hex
      end
      if container && !container.empty?
        if cs.dig('containers', container)
          hex = cs.dig('containers', container, 'color')
          return "FF_CC_#{hex.gsub('#','')}" if hex
        end
        cont_obj = (TakeoffTool.master_containers || []).find { |c| c['name'] == container }
        if cont_obj && cont_obj['color']
          return "FF_CC_#{cont_obj['color'].gsub('#','')}"
        end
      end
      "FF_HL_#{cat.gsub(/[^a-zA-Z0-9]/, '_')}"
    end

    # ─── Persistence ───

    def self.load_settings
      require 'json'
      mv_view = TakeoffTool.active_mv_view rescue nil
      key = 'color_settings'
      if mv_view && mv_view != 'ab'
        key = (mv_view == 'a') ? 'color_settings_model_a' : 'color_settings_model_b'
      end
      json = Sketchup.active_model.get_attribute('FormAndField', key, nil)
      if json
        @color_settings = (JSON.parse(json) rescue {})
      else
        # Try migrating from legacy custom_colors
        migrate_legacy_settings
      end
    end

    def self.save_settings
      require 'json'
      mv_view = TakeoffTool.active_mv_view rescue nil
      key = 'color_settings'
      if mv_view && mv_view != 'ab'
        key = (mv_view == 'a') ? 'color_settings_model_a' : 'color_settings_model_b'
      end
      Sketchup.active_model.set_attribute('FormAndField', key, JSON.generate(@color_settings))
    end

    def self.migrate_legacy_settings
      require 'json'
      mv_view = TakeoffTool.active_mv_view rescue nil
      legacy_key = 'custom_colors'
      if mv_view && mv_view != 'ab'
        legacy_key = (mv_view == 'a') ? 'custom_colors_model_a' : 'custom_colors_model_b'
      end
      json = Sketchup.active_model.get_attribute('FormAndField', legacy_key, nil)
      return unless json
      old = (JSON.parse(json) rescue nil)
      return unless old.is_a?(Hash)

      @color_settings = {}
      old.each do |section, entries|
        next unless entries.is_a?(Hash)
        @color_settings[section] ||= {}
        entries.each do |k, hex|
          @color_settings[section][k] = { 'color' => hex, 'opacity' => DEFAULT_OPACITY }
        end
      end
      save_settings
      puts "CC: Migrated legacy custom_colors to color_settings"
    end

    # Returns settings hash for JS consumption
    def self.get_settings
      @color_settings
    end

    # Also provide legacy-format custom_colors for backwards compatibility with JS
    def self.get_legacy_custom_colors
      result = {}
      @color_settings.each do |section, entries|
        next unless entries.is_a?(Hash)
        result[section] ||= {}
        entries.each do |k, data|
          result[section][k] = data.is_a?(Hash) ? data['color'] : data
        end
      end
      result
    end

    # ─── Helpers ───

    def self.hex_to_rgb(hex)
      return nil unless hex && hex.length >= 7
      [hex[1..2].to_i(16), hex[3..4].to_i(16), hex[5..6].to_i(16)]
    end

    def self.highlights_active?
      @highlights_active
    end

    def self.active_cat_colors
      @active_cat_colors
    end

    def self.active_mode
      @active_mode
    end

    # ─── Pre-strip Baked FF_ Materials ───

    def self.strip_baked_ff_materials
      m = Sketchup.active_model
      return 0 unless m
      reg = TakeoffTool.entity_registry || {}
      return 0 if reg.empty?

      stripped = 0
      m.start_operation('CC Pre-strip', true)
      reg.each do |eid, e|
        next unless e && e.valid?

        # Instance-level
        mat = e.material
        if mat && mat.respond_to?(:name) && mat.name.start_with?('FF_')
          e.material = nil
          stripped += 1
        end

        # Face-level (single-instance definitions only)
        defn = e.respond_to?(:definition) ? e.definition : nil
        defn ||= (e.is_a?(Sketchup::Group) ? e.entities.parent : nil)
        next unless defn && defn.respond_to?(:instances)
        next if defn.instances.length > 1

        defn.entities.grep(Sketchup::Face).each do |face|
          fm = face.material
          if fm && fm.respond_to?(:name) && fm.name.start_with?('FF_')
            face.material = nil
            stripped += 1
          end
          bm = face.back_material
          if bm && bm.respond_to?(:name) && bm.name.start_with?('FF_')
            face.back_material = nil
            stripped += 1
          end
        end
      end
      m.commit_operation
      puts "CC: Pre-strip: #{stripped} baked FF_ materials cleared" if stripped > 0
      stripped
    end

    # ─── Material Catalog ───

    @materials_cataloged = false

    def self.catalog_original_materials
      return if @materials_cataloged
      reg = TakeoffTool.entity_registry || {}
      return if reg.empty?

      # Check if already cataloged (from a previous scan save)
      sample = reg.values.find { |e| e && e.valid? }
      if sample
        existing = sample.get_attribute('TakeoffScanData', 'original_inst_mat') rescue nil
        if existing
          @materials_cataloged = true
          return
        end
      end

      count = 0
      d = 'TakeoffScanData'
      reg.each do |eid, e|
        next unless e && e.valid?
        mat = e.material
        next if mat && mat.respond_to?(:name) && mat.name.start_with?('FF_')

        e.set_attribute(d, 'original_inst_mat', mat ? mat.display_name : '')

        defn = e.respond_to?(:definition) ? e.definition : nil
        defn ||= (e.is_a?(Sketchup::Group) ? e.entities.parent : nil)
        if defn
          fm_tally = {}
          defn.entities.grep(Sketchup::Face).each do |f|
            fn = f.material
            next if fn && fn.respond_to?(:name) && fn.name.start_with?('FF_')
            fm_tally[fn.display_name] = (fm_tally[fn.display_name] || 0) + 1 if fn
            bn = f.back_material
            next if bn && bn.respond_to?(:name) && bn.name.start_with?('FF_')
            fm_tally[bn.display_name] = (fm_tally[bn.display_name] || 0) + 1 if bn
          end
          dominant = fm_tally.max_by { |_, c| c }&.first || ''
          e.set_attribute(d, 'original_face_mat', dominant)
        end
        count += 1
      end
      @materials_cataloged = true
      puts "CC: Cataloged original materials for #{count} entities"
    end

    def self.restore_from_catalog
      m = Sketchup.active_model
      return 0 unless m
      reg = TakeoffTool.entity_registry || {}
      return 0 if reg.empty?

      materials = m.materials
      fixed = 0
      d = 'TakeoffScanData'

      reg.each do |eid, e|
        next unless e && e.valid?

        # Fix instance material
        imat = e.material
        if imat && imat.respond_to?(:name) && imat.name.start_with?('FF_')
          orig_name = e.get_attribute(d, 'original_inst_mat') rescue nil
          e.material = (orig_name && !orig_name.empty?) ? materials[orig_name] : nil
          fixed += 1
        end

        # Fix face materials in single-instance definitions
        defn = e.respond_to?(:definition) ? e.definition : nil
        defn ||= (e.is_a?(Sketchup::Group) ? e.entities.parent : nil)
        next unless defn && defn.respond_to?(:instances)
        next if defn.instances.length > 1

        face_mat_name = e.get_attribute(d, 'original_face_mat') rescue nil
        next unless face_mat_name && !face_mat_name.empty?
        face_mat = materials[face_mat_name]
        next unless face_mat

        defn.entities.grep(Sketchup::Face).each do |f|
          fm = f.material
          if fm.nil? || (fm.respond_to?(:name) && fm.name.start_with?('FF_'))
            f.material = face_mat
            fixed += 1
          end
          bm = f.back_material
          if bm.nil? || (bm.respond_to?(:name) && bm.name.start_with?('FF_'))
            f.back_material = face_mat
            fixed += 1
          end
        end
      end
      puts "CC: Catalog restore fixed #{fixed} materials" if fixed > 0
      fixed
    end

    # ─── Highlight Mode ───

    def self.highlight_all(sr, ca)
      m = Sketchup.active_model
      return puts("CC: No model") unless m
      @highlight_state = { mode: :all, sr: sr, ca: ca, cat: nil }
      catalog_original_materials
      deactivate_internal
      strip_baked_ff_materials

      load_settings

      puts "CC: highlight_all called with #{sr.length} scan results"

      m.start_operation('Highlight All', true)
      found = 0; colored = 0; missed = 0

      sr.each do |r|
        eid = r[:entity_id]
        e = TakeoffTool.find_entity(eid)
        unless e
          missed += 1
          puts "CC: MISS eid=#{eid} name=#{r[:display_name]}" if missed <= 5
          next
        end
        unless e.valid?
          missed += 1
          puts "CC: INVALID eid=#{eid}" if missed <= 5
          next
        end

        found += 1
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next if cat == '_IGNORE'

        sub = (e.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || ''
        container = find_container_for_cat(cat)

        rgb = resolve_color(eid, cat, sub, container)
        opacity = resolve_opacity(eid, cat, sub, container)
        mk = mat_key_for(eid, cat, sub, container)

        mat = get_or_create_material(m, mk, rgb, opacity)

        # Track level→material for in-place updates
        @level_to_mat_key["categories:#{cat}"] = mk

        applied = apply_paint(e, eid, mat)
        colored += 1 if applied
      end

      m.commit_operation
      @highlights_active = true
      @active_mode = :highlight
      puts "CC: Done. found=#{found} colored=#{colored} missed=#{missed}"
    end

    def self.highlight_category(sr, ca, tc)
      m = Sketchup.active_model; return unless m
      @highlight_state = { mode: :category, sr: sr, ca: ca, cat: tc }
      deactivate_internal

      load_settings

      m.start_operation('Highlight Cat', true); n = 0
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == tc
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        eid = r[:entity_id]
        sub = (e.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || ''
        container = find_container_for_cat(cat)

        rgb = resolve_color(eid, cat, sub, container)
        opacity = resolve_opacity(eid, cat, sub, container)
        mk = mat_key_for(eid, cat, sub, container)
        mat = get_or_create_material(m, mk, rgb, opacity)
        @level_to_mat_key["categories:#{cat}"] = mk

        apply_paint(e, eid, mat)
        n += 1
      end
      m.commit_operation
      @highlights_active = true
      @active_mode = :highlight
      puts "CC: Category '#{tc}' highlighted #{n}"
    end

    def self.highlight_single(eid)
      m = Sketchup.active_model; return unless m
      eid = eid.to_i
      e = TakeoffTool.find_entity(eid)
      puts "CC: single eid=#{eid} found=#{!e.nil?} valid=#{e ? e.valid? : 'n/a'}"
      return unless e && e.valid?
      m.start_operation('Highlight', true)
      mat = get_or_create_material(m, 'FF_SEL', SELECTION_COLOR, 0.9)
      apply_paint(e, eid, mat)
      m.commit_operation
    end

    def self.highlight_entities(ids)
      m = Sketchup.active_model; return unless m
      puts "CC: entities count=#{ids.length}"
      deactivate_internal
      m.start_operation('Highlight Set', true)
      mat = get_or_create_material(m, 'FF_SEL', SELECTION_COLOR, 0.9)
      n = 0
      ids.each do |id|
        e = TakeoffTool.find_entity(id.to_i); next unless e && e.valid?
        apply_paint(e, id.to_i, mat)
        n += 1
      end
      m.commit_operation
      puts "CC: highlighted #{n} of #{ids.length}"
    end

    def self.highlight_category_color(sr, ca, cat_name)
      m = Sketchup.active_model; return unless m
      load_settings

      cs = @color_settings
      hex = cs.dig('categories', cat_name, 'color')
      unless hex
        # Fall back to container color
        container = find_container_for_cat(cat_name)
        hex = cs.dig('containers', container, 'color') if container
        return unless hex
      end

      m.start_operation('Color ' + cat_name, true)

      # Restore existing highlights for this category before re-applying
      sr.each do |r|
        eid = r[:entity_id]
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == cat_name
        e = TakeoffTool.find_entity(eid); next unless e && e.valid?
        if @originals.key?(eid)
          entry = @originals[eid]
          safe_set_material(e, entry[:instance])
          if entry[:faces]
            entry[:faces].each do |arr|
              obj = arr[0]
              next unless obj.valid?
              safe_set_material(obj, arr[1])
              safe_set_back_material(obj, arr[2]) if arr.length == 3
            end
          end
        end
      end

      # Create material for this color
      c = hex_to_rgb(hex)
      unless c
        m.commit_operation
        return
      end
      opacity = cs.dig('categories', cat_name, 'opacity')
      unless opacity
        container = find_container_for_cat(cat_name)
        opacity = cs.dig('containers', container, 'opacity') if container
      end
      opacity ||= DEFAULT_OPACITY
      k = "FF_CC_#{hex.gsub('#','')}"
      mat = get_or_create_material(m, k, c, opacity)

      # Apply to all entities in this category
      n = 0
      sr.each do |r|
        eid = r[:entity_id]
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == cat_name
        e = TakeoffTool.find_entity(eid); next unless e && e.valid?
        apply_paint(e, eid, mat)
        n += 1
      end

      @active_cat_colors[cat_name] = true
      m.commit_operation
      puts "CC: Color ON '#{cat_name}' (#{n} entities, #{hex})"
    end

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
        if @originals.key?(eid)
          entry = @originals[eid]
          safe_set_material(e, entry[:instance])
          if entry[:faces]
            entry[:faces].each do |arr|
              obj = arr[0]
              next unless obj.valid?
              safe_set_material(obj, arr[1])
              safe_set_back_material(obj, arr[2]) if arr.length == 3
            end
          end
          @originals.delete(eid)
          n += 1
        end
      end

      m.commit_operation
      puts "CC: Color OFF '#{cat_name}' (#{n} entities restored)"
    end

    def self.deactivate
      deactivate_internal
      @highlights_active = false
      @active_mode = :none
      @active_cat_colors = {}
      @highlight_state = nil
      @smart_diff_settings = nil
      @smart_diff_visibility = nil
    end

    def self.refresh_highlights
      return unless @highlights_active && @highlight_state
      @refreshing = true
      begin
        hs = @highlight_state
        if hs[:mode] == :all && hs[:sr] && hs[:ca]
          highlight_all(hs[:sr], hs[:ca])
        elsif hs[:mode] == :category && hs[:sr] && hs[:ca] && hs[:cat]
          highlight_category(hs[:sr], hs[:ca], hs[:cat])
        end
      ensure
        @refreshing = false
      end
    end

    # ─── set_color / set_opacity / clear_color ───

    def self.set_color(level, key, hex, opacity = nil)
      @color_settings[level] ||= {}
      existing_opacity = @color_settings.dig(level, key, 'opacity') || DEFAULT_OPACITY
      @color_settings[level][key] = { 'color' => hex, 'opacity' => opacity || existing_opacity }
      save_settings

      # In-place update: find material via @level_to_mat_key
      lk = "#{level}:#{key}"
      old_mk = @level_to_mat_key[lk]
      if old_mk && @mats[old_mk]
        c = hex_to_rgb(hex)
        if c
          @mats[old_mk].color = Sketchup::Color.new(*c)
          @mats[old_mk].alpha = opacity || existing_opacity
        end
      end

      # Also clear cached default material so next highlight uses new color
      clear_cached_material(key) if level == 'categories'
    end

    def self.set_opacity(level, key, value)
      @color_settings[level] ||= {}
      @color_settings[level][key] ||= {}
      @color_settings[level][key]['opacity'] = value
      save_settings

      # In-place material alpha update
      lk = "#{level}:#{key}"
      mk = @level_to_mat_key[lk]
      if mk && @mats[mk]
        @mats[mk].alpha = value
      end
    end

    def self.clear_color(level, key)
      if @color_settings[level]
        @color_settings[level].delete(key)
      end
      save_settings
      clear_cached_material(key) if level == 'categories'
    end

    # ─── Focus Mode (HyperParser) ───

    def self.focus_entities(ids)
      m = Sketchup.active_model; return unless m
      deactivate_internal unless @active_mode == :focus
      @active_mode = :focus

      m.start_operation('Focus', true)
      bright = get_or_create_material(m, 'FF_FOCUS_BRIGHT', FOCUS_COLOR, 0.9)

      ids.each do |eid|
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?
        backup(eid, e) unless backed_up?(eid)
        e.material = bright

        # Paint faces for full visibility
        defn = e.respond_to?(:definition) ? e.definition : nil
        if defn && defn.respond_to?(:instances) && defn.instances.length <= 1
          repaint_faces_recursive(defn.entities, bright)
        end
      end

      m.commit_operation
    end

    def self.clear_focus
      restore_all
      @active_mode = :none
    end

    # ─── Diff Mode (Multiverse) ───

    def self.apply_diff(work_queue)
      deactivate_internal unless @active_mode == :none
      @active_mode = :diff
      @diff_data = work_queue
      m = Sketchup.active_model; return unless m

      diff_a = get_or_create_material(m, 'FF_DIFF_A', DIFF_COLORS[:a], DIFF_OPACITY)
      diff_b = get_or_create_material(m, 'FF_DIFF_B', DIFF_COLORS[:b], DIFF_OPACITY)
      m.rendering_options['DisplayColorByLayer'] = false

      @diff_orig_mats ||= {}
      work_queue.each do |item|
        e = (TakeoffTool.entity_registry || {})[item[:eid]]
        next unless e && e.valid?
        mat = item[:model] == :a ? diff_a : diff_b
        @diff_orig_mats[item[:eid]] = e.material unless @diff_orig_mats.key?(item[:eid])
        e.material = mat
      end

      @diff_active = true
    end

    def self.remove_diff
      m = Sketchup.active_model; return unless m
      reg = TakeoffTool.entity_registry || {}

      if @diff_orig_mats && @diff_orig_mats.any?
        m.start_operation('Remove Diff', true)
        @diff_orig_mats.each do |eid, orig_mat|
          e = reg[eid]
          next unless e && e.valid?
          e.material = orig_mat
        end
        m.commit_operation
      end

      @diff_orig_mats = nil
      @diff_active = false
      @active_mode = :none

      if TakeoffTool.active_mv_view == 'ab'
        m.rendering_options['DisplayColorByLayer'] = true
      end
      m.active_view.invalidate
      puts "CC: Removed diff highlights"
    end

    def self.toggle_diff
      if @diff_active
        remove_diff
      elsif @diff_data && @diff_data.any?
        m = Sketchup.active_model; return unless m
        diff_a = get_or_create_material(m, 'FF_DIFF_A', DIFF_COLORS[:a], DIFF_OPACITY)
        diff_b = get_or_create_material(m, 'FF_DIFF_B', DIFF_COLORS[:b], DIFF_OPACITY)
        m.rendering_options['DisplayColorByLayer'] = false
        m.start_operation('Apply Diff', true)

        reg = TakeoffTool.entity_registry || {}
        @diff_orig_mats ||= {}
        applied = 0
        @diff_data.each do |item|
          e = reg[item[:eid]]
          next unless e && e.valid?
          mat = item[:model] == :a ? diff_a : diff_b
          @diff_orig_mats[item[:eid]] = e.material unless @diff_orig_mats.key?(item[:eid])
          e.material = mat
          applied += 1
        end
        m.commit_operation
        @diff_active = true
        @active_mode = :diff
        m.active_view.invalidate
        puts "CC: Applied diff to #{applied} entities"
      end
      @diff_active
    end

    def self.diff_active?
      @diff_active
    end

    def self.diff_orig_mats
      @diff_orig_mats
    end

    def self.diff_orig_mats=(val)
      @diff_orig_mats = val
    end

    def self.diff_data
      @diff_data
    end

    def self.diff_data=(val)
      @diff_data = val
    end

    # ─── Smart Diff Mode ───

    SMART_DIFF_COLORS = {
      matched:   [88, 91, 112],    # Surface2 — muted gray
      changed:   [249, 226, 175],  # Yellow — amber
      new_b:     [137, 180, 250],  # Blue — bright
      removed_a: [243, 139, 168]   # Red/pink
    }

    SMART_DIFF_OPACITY = {
      matched:   0.15,
      changed:   0.50,
      new_b:     0.90,
      removed_a: 0.70
    }

    @smart_diff_settings = nil
    @smart_diff_visibility = nil

    def self.apply_smart_diff(ab_classification, category_filter: nil)
      m = Sketchup.active_model
      return unless m

      # Clean up any existing mode
      catalog_original_materials
      deactivate_internal unless @originals.empty?
      remove_diff_if_active
      strip_baked_ff_materials

      @active_mode = :smart_diff
      @smart_diff_settings ||= SMART_DIFF_OPACITY.dup
      @smart_diff_visibility ||= { matched: true, changed: true, new_b: true, removed_a: true }

      # Category filter: array of allowed category names, or nil for all
      cat_set = category_filter ? category_filter.map(&:to_s) : nil
      ab_cats = TakeoffTool.ab_categories || {}

      m.rendering_options['DisplayColorByLayer'] = false
      m.start_operation('Smart Diff', true)

      # Create materials for each state
      sd_mats = {}
      SMART_DIFF_COLORS.each do |state, rgb|
        opacity = @smart_diff_settings[state] || SMART_DIFF_OPACITY[state]
        key = "FF_SD_#{state}"
        sd_mats[state] = get_or_create_material(m, key, rgb, opacity)
      end

      applied = 0
      hidden = 0
      ab_classification.each do |eid, state|
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?

        # Category filter check — hide entities not in selected categories
        if cat_set
          ent_cat = ab_cats[eid].to_s
          unless cat_set.include?(ent_cat)
            backup(eid, e)
            e.visible = false
            hidden += 1
            next
          end
        end

        # Visibility check (state toggle)
        unless @smart_diff_visibility[state]
          backup(eid, e)
          e.visible = false
          hidden += 1
          next
        end

        mat = sd_mats[state]
        next unless mat
        apply_paint(e, eid, mat)
        applied += 1
      end

      m.commit_operation
      @highlights_active = true
      m.active_view.invalidate
      puts "CC: Smart diff applied=#{applied} hidden=#{hidden} cat_filter=#{cat_set ? cat_set.length : 'all'}"
    end

    def self.set_smart_diff_opacity(state, value)
      @smart_diff_settings ||= SMART_DIFF_OPACITY.dup
      @smart_diff_settings[state.to_sym] = value
      key = "FF_SD_#{state}"
      if @mats[key]
        @mats[key].alpha = value
      end
    end

    def self.set_smart_diff_visibility(state, visible)
      @smart_diff_visibility ||= { matched: true, changed: true, new_b: true, removed_a: true }
      @smart_diff_visibility[state.to_sym] = visible
    end

    def self.smart_diff_settings
      @smart_diff_settings || SMART_DIFF_OPACITY.dup
    end

    def self.smart_diff_visibility
      @smart_diff_visibility || { matched: true, changed: true, new_b: true, removed_a: true }
    end

    # Helper: clean up diff state if active before entering smart diff
    def self.remove_diff_if_active
      if @diff_active
        remove_diff
      end
    end

    private

    # Internal deactivate: restore all without clearing mode state
    def self.deactivate_internal
      m = Sketchup.active_model; return unless m
      m.start_operation('CC Clear', true)

      unless @originals.empty?
        @originals.each do |eid, entry|
          e = TakeoffTool.find_entity(eid)
          if e && e.valid?
            safe_set_material(e, entry[:instance])
          end
          next unless entry[:faces]
          entry[:faces].each do |arr|
            obj = arr[0]
            next unless obj.valid?
            if arr.length == 3
              safe_set_material(obj, arr[1])
              safe_set_back_material(obj, arr[2])
            else
              safe_set_material(obj, arr[1])
            end
          end
        end
        @originals.clear
        @mats.clear
      end

      # Catalog-based safety net: fix anything the @originals restore missed
      restore_from_catalog

      m.commit_operation
      m.active_view.invalidate

      unless @refreshing
        @highlights_active = false
        @active_cat_colors = {}
      end
    end

    def self.apply_paint(entity, eid, mat)
      backup(eid, entity)
      entity.material = mat

      defn = nil
      if entity.respond_to?(:definition)
        defn = entity.definition
      elsif entity.is_a?(Sketchup::Group)
        defn = entity.entities.parent
      end

      if defn && defn.respond_to?(:entities) && defn.respond_to?(:instances)
        if defn.instances.length <= 1
          if backed_up?(eid) && @originals[eid][:faces]
            repaint_faces_recursive(defn.entities, mat)
          else
            face_list = []
            paint_faces_recursive(defn.entities, mat, face_list)
            @originals[eid][:faces] = face_list if face_list.length > 0
          end
        end
      end

      true
    rescue => e
      puts "CC: apply_paint error eid=#{eid}: #{e.message}"
      false
    end

    def self.paint_faces_recursive(ents, mat, face_list)
      ents.grep(Sketchup::Face).each do |face|
        face_list << [face, face.material, face.back_material]
        face.material = mat
        face.back_material = mat
      end
      ents.each do |child|
        next unless child.valid?
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        next if child_defn.respond_to?(:instances) && child_defn.instances.length > 1
        face_list << [child, child.material] if child.respond_to?(:material)
        child.material = mat
        paint_faces_recursive(child_defn.entities, mat, face_list)
      end
    end

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

    # Keyword map mirroring dashboard CONT_KW — longest match first
    CONT_KEYWORDS = [
      # multi-word specifics
      ['plumbing fixture','MEP'],['lighting fixture','MEP'],
      ['ceiling framing','Structure'],['roof framing','Structure'],['wall framing','Structure'],
      ['floor framing','Structure'],['floor truss','Structure'],['roof truss','Structure'],
      ['roof sheath','Structure'],['wall sheath','Structure'],['floor sheath','Structure'],
      ['stud pack','Structure'],['wide flange','Structure'],['w beam','Structure'],
      ['grade beam','Foundation'],['stem wall','Foundation'],
      ['exterior door','Full Enclosure'],['garage door','Full Enclosure'],
      ['glass door','Full Enclosure'],['interior door','Finish'],['int door','Finish'],
      ['exterior trim','Full Enclosure'],['interior trim','Finish'],
      ['wall finish','Full Enclosure'],['floor finish','Finish'],
      ['wood panel','Full Enclosure'],['gyp board','Finish'],
      ['shower glass','Finish'],['tile wall','Finish'],
      ['low voltage','MEP'],['retaining wall','Exterior/Site'],['i-joist','Structure'],
      # single-word
      ['footing','Foundation'],['foundation','Foundation'],['slab','Foundation'],
      ['concrete','Foundation'],['gypcrete','Finish'],['cmu','Foundation'],
      ['pier','Foundation'],['basement','Foundation'],
      ['steel','Structure'],['lumber','Structure'],['timber','Structure'],
      ['framing','Structure'],['truss','Structure'],['sheathing','Structure'],
      ['header','Structure'],['lvl','Structure'],['tji','Structure'],['bci','Structure'],
      ['joist','Structure'],['rafter','Structure'],['beam','Structure'],
      ['column','Structure'],['post','Structure'],['blocking','Structure'],
      ['purlin','Structure'],['ridge','Structure'],['chord','Structure'],
      ['brace','Structure'],['structural','Structure'],['decking','Structure'],['deck','Structure'],
      ['roofing','Full Enclosure'],['siding','Full Enclosure'],['soffit','Full Enclosure'],
      ['fascia','Full Enclosure'],['window','Full Enclosure'],['glazing','Full Enclosure'],
      ['garage','Full Enclosure'],['railing','Full Enclosure'],['guard','Full Enclosure'],
      ['masonry','Full Enclosure'],['stone','Full Enclosure'],['brick','Full Enclosure'],
      ['insulation','Full Enclosure'],['stucco','Full Enclosure'],
      ['gutter','Full Enclosure'],['downspout','Full Enclosure'],
      ['flashing','Full Enclosure'],['paneling','Full Enclosure'],
      ['wrap','Full Enclosure'],['door','Full Enclosure'],
      ['drywall','Finish'],['trim','Finish'],['flooring','Finish'],['floor','Finish'],
      ['tile','Finish'],['cabinet','Finish'],['vanity','Finish'],['vanities','Finish'],
      ['casework','Finish'],['countertop','Finish'],['counter','Finish'],
      ['stair','Finish'],['shelf','Finish'],['shelving','Finish'],
      ['mirror','Finish'],['paint','Finish'],['hardware','Finish'],
      ['millwork','Finish'],['molding','Finish'],['baseboard','Finish'],
      ['crown','Finish'],['ceiling','Finish'],['wainscot','Finish'],
      ['electric','MEP'],['conduit','MEP'],['panel','MEP'],['switch','MEP'],
      ['outlet','MEP'],['receptacle','MEP'],['light','MEP'],['luminaire','MEP'],
      ['plumb','MEP'],['pipe','MEP'],['sink','MEP'],['toilet','MEP'],
      ['faucet','MEP'],['tub','MEP'],['shower','MEP'],['fixture','MEP'],
      ['hvac','MEP'],['mechanical','MEP'],['duct','MEP'],['diffuser','MEP'],
      ['fire','MEP'],['sprinkler','MEP'],
      ['landscape','Exterior/Site'],['paving','Exterior/Site'],['asphalt','Exterior/Site'],
      ['retaining','Exterior/Site'],['fence','Exterior/Site'],['fencing','Exterior/Site'],
      ['site','Exterior/Site'],['excavat','Exterior/Site'],['backfill','Exterior/Site'],['patio','Exterior/Site'],
      ['appliance','Specialty'],['washer','Specialty'],['dryer','Specialty'],
      ['refrigerator','Specialty'],['oven','Specialty'],['range','Specialty'],
      ['dishwasher','Specialty'],['furniture','Specialty'],
      ['equipment','Specialty'],['specialty','Specialty'],
    ].freeze

    # Find container name for a category from master_containers
    def self.find_container_for_cat(cat)
      return nil unless cat && !cat.empty?
      containers = TakeoffTool.master_containers || []
      # 1. Explicit assignment
      containers.each do |cont|
        cats = cont['categories'] || []
        return cont['name'] if cats.include?(cat)
      end
      # 2. Keyword matching (mirrors dashboard CONT_KW)
      return nil if cat == '_IGNORE'
      return 'Other' if cat == 'Uncategorized'
      low = cat.downcase
      cont_names = containers.map { |c| c['name'] }
      CONT_KEYWORDS.each do |kw, cont_name|
        if low.include?(kw) && cont_names.include?(cont_name)
          return cont_name
        end
      end
      nil
    end
  end
end
