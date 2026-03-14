require 'set'

module TakeoffTool
  module Scanner
    unless defined?(CONFIDENCE_SCORES)
    # ─── Confidence scoring for multi-strategy parser ───
    CONFIDENCE_SCORES = { high: 4, medium: 3, low: 2, none: 1 }.freeze

    # ─── Nominal lumber sizes: actual inches → nominal label ───
    NOMINAL_SIZES = [
      [1.5, '2'], [1.75, '1-3/4'], [2.625, '2-5/8'], [3.5, '4'],
      [3.625, '3-5/8'], [5.5, '6'], [7.25, '8'], [9.25, '10'],
      [11.25, '12'], [13.25, '14'], [15.25, '16'], [17.5, '18']
    ].freeze

    # ─── Material classification regexes (Strategy 3: Material + BBox) ───
    WOOD_SPECIES_RE   = /\b(Oak|White\s*Oak|Red\s*Oak|Cedar|Douglas\s*Fir|Fir|Pine|Walnut|Cherry|Maple|Poplar|Ash|Birch|Hemlock|Spruce)\b/i
    FRAMING_MAT_RE    = /^Framing\d*$/i
    ENGINEERED_MAT_RE = /\b(LVL|Microlam|PSL|LSL|Parallam|Glulam)\b/i
    STEEL_MAT_RE      = /\b(Steel|Iron|Galvanized)\b/i
    REBAR_MAT_RE      = /\bConcrete\s*Steel\b|\bRebar\b|\bReinforc(?:ing\s*Steel|ement)\b/i
    CONCRETE_MAT_RE   = /^Concrete|\bCMU\b|\bBlock\b|\bMasonry\b|\bGrout\b/i

    # ─── Foundation / concrete keywords: [regex, category, subcategory] ───
    FOUNDATION_KW = [
      [/\bGrade\s*Beam\b/i,  'Concrete',            'Grade Beam'],
      [/\bPier\b/i,          'Concrete',            'Pier'],
      [/\bPiling\b/i,        'Foundation Footings', 'Piling'],
      [/\bFooting\b/i,       'Foundation Footings', 'Footing'],
      [/\bFoundation\b/i,    'Concrete',            'Foundation'],
      [/\bCaisson\b/i,       'Foundation Footings', 'Caisson'],
      [/\bSlab\b/i,          'Foundation Slabs',    'Slab'],
    ].freeze

    # ─── Material-only fallback (Strategy 6: material display_name only) ───
    # Catches generic ComponentNNNN items that have clear material names.
    # Checked ONLY when all other strategies left the entity uncategorized.
    MATERIAL_FALLBACK_MAP = [
      # Rebar/Reinforcement (before generic concrete)
      [/\bConcrete\s*Steel\b|\bRebar\b|\bReinforc(?:ing\s*Steel|ement)\b/i, 'Concrete', 'Rebar/Reinforcement'],
      # Wood species → Timber Frame (hardwood always = timber)
      [/\b(Oak|White\s*Oak|Red\s*Oak|Cedar|Douglas\s*Fir|Walnut|Cherry|Maple|Poplar|Ash|Birch|Hemlock|Spruce)\b/i, 'Timber Frame', nil],
      # Generic framing material
      [/^Framing\d*$/i, 'Structural Lumber', nil],
      # Engineered wood
      [/\b(LVL|Microlam|PSL|LSL|Parallam|Glulam)\b/i, 'Structural Lumber', nil],
      # Fir/Pine (softwood — could be structural or finish)
      [/\b(Fir|Pine)\b/i, 'Structural Lumber', nil],
      # Steel/Iron
      [/\b(Steel|Iron|Galvanized)\b/i, 'Structural Steel', nil],
      # Concrete (generic)
      [/^Concrete|\bCMU\b|\bBlock\b|\bMasonry\b|\bGrout\b/i, 'Concrete', nil],
      # Drywall
      [/\b(Drywall|Gypsum|GWB|Sheetrock)\b/i, 'Drywall', nil],
      # Insulation
      [/\b(Insulation|Batt|Rigid\s+Foam)\b/i, 'Insulation', nil],
      # Sheathing
      [/\b(Sheathing|OSB|Plywood)\b/i, 'Sheathing', nil],
      # Siding
      [/\b(Siding|Hardie)\b/i, 'Siding', nil],
      # Membrane
      [/\bMembrane\b/i, 'Membrane', nil],
      # Tile
      [/\b(Tile|Porcelain|Ceramic)\b/i, 'Tile', nil],
    ].freeze

    # ─── Keyword scan patterns (Strategy 5: last resort) ───
    KEYWORD_MAP = [
      [/\bDrywall\b|\bGypsum\b|\bGWB\b/i, 'Drywall'],
      [/\bInsulation\b|\bBatt\b|\bRigid\s+Foam\b/i, 'Insulation'],
      [/\bSheathing\b|\bShtg\b|\bOSB\b|\bPlywood\b/i, 'Sheathing'],
      [/\bSiding\b|\bLap\s+Siding\b|\bHardie\b/i, 'Siding'],
      [/\bRebar\b|\bReinforc(?:ing)?\b/i, 'Concrete'],
      [/\bConcrete\b|\bCMU\b/i, 'Concrete'],
      [/\bRafter\b|\bJoist\b|\bBeam\b|\bPost\b|\bStud\b/i, 'Structural Lumber'],
      [/\bWindow\b/i, 'Windows'],
      [/\bDoor\b/i, 'Doors'],
      [/\bTrim\b|\bMolding\b|\bBaseboard\b|\bCasing\b/i, 'Trim'],
      [/\bCabinet\b|\bVanit/i, 'Casework'],
      [/\bCounter\s*top\b/i, 'Countertops'],
      [/\bRoofing\b|\bShingle\b/i, 'Roofing'],
      [/\bMembrane\b/i, 'Membrane'],
      [/\bFloor\b/i, 'Flooring'],
    ].freeze
    end # unless defined?(CONFIDENCE_SCORES)

    # Beam/structural categories — use longest-edge LF instead of extrusion detection
    BEAM_RE = /W-Beam|HSS|Steel Tube|Structural Steel|Steel Post|Column|Beam|Purlin|Girder|Structural Framing|Timber/i unless defined?(BEAM_RE)

    # Wall categories — use longest horizontal edge for LF
    WALL_LF_RE = /Wall Framing|Wall Finish|Wall Structure|Wall Sheathing|Masonry|Siding|Stucco|Exterior Finish/i unless defined?(WALL_LF_RE)

    # Cache for debug restore: face-level and instance-level originals
    @debug_face_originals = {}
    @debug_inst_originals = {}

    def self.debug_save_face(face)
      fid = face.entityID
      unless @debug_face_originals.key?(fid)
        @debug_face_originals[fid] = { face: face, front: face.material, back: face.back_material }
      end
    end

    def self.debug_paint(face, mat)
      debug_save_face(face)
      face.material = mat
      face.back_material = mat
    end

    # Recursively paint all faces in an entity (including nested groups/components)
    def self.debug_paint_entity(entity, mat)
      defn = entity.respond_to?(:definition) ? entity.definition : nil
      return unless defn
      debug_paint_recursive(defn.entities, mat)
      # Also paint instance material
      eid = entity.entityID
      unless @debug_inst_originals.key?(eid)
        @debug_inst_originals[eid] = { entity: entity, mat: entity.material }
      end
      entity.material = mat
    end

    def self.debug_paint_recursive(ents, mat)
      ents.grep(Sketchup::Face).each do |f|
        debug_save_face(f)
        f.material = mat
        f.back_material = mat
      end
      ents.each do |child|
        next unless child.valid?
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        debug_paint_recursive(child_defn.entities, mat)
      end
    end

    def self.debug_restore_all
      m = Sketchup.active_model
      return 0 unless m
      m.start_operation('Restore Debug', true)
      restored = 0
      @debug_face_originals.each_value do |entry|
        face = entry[:face]
        next unless face && face.valid?
        face.material = entry[:front]
        face.back_material = entry[:back]
        restored += 1
      end
      @debug_inst_originals.each_value do |entry|
        ent = entry[:entity]
        next unless ent && ent.valid?
        ent.material = entry[:mat]
        restored += 1
      end
      m.commit_operation
      @debug_face_originals = {}
      @debug_inst_originals = {}
      restored
    end

    # ═══════════════════════════════════════════════════════════
    # scan_model — Main entry point
    # ═══════════════════════════════════════════════════════════

    # model_source_filter: nil = scan all, 'model_a' = only model_a, 'model_b' = only non-model_a
    # existing_results/existing_reg: when provided, append to these instead of starting fresh
    def self.scan_model(model, model_source_filter: nil, existing_results: nil, existing_reg: nil, &progress)
      results = existing_results || []; reg = existing_reg || {}; seen = {}
      # When appending, mark existing entity IDs as seen so we don't re-process them
      reg.each_key { |eid| seen[eid] = true } if existing_reg
      @is_ifc_model = IFCParser.ifc_model?(model)

      # Pre-load cost code map and learned rules
      CostCodeParser.load_map
      LearningSystem.load_rules(force: true)
      progress.call("Cost code map and learned rules loaded") if progress

      # Auto-detection summary
      has_revit = model.definitions.any? { |d| !d.image? && d.name =~ /^Basic Wall|^Basic Roof|^Compound Ceiling/i }
      if @is_ifc_model
        progress.call("IFC model detected — IFC + material + keyword parsers active") if progress
      elsif has_revit
        progress.call("Revit model detected — name + material + keyword parsers active") if progress
      else
        progress.call("Generic model — material + keyword parsers active") if progress
      end

      filter_label = model_source_filter == 'model_b' ? ' (Model B only)' : (model_source_filter == 'model_a' ? ' (Model A only)' : '')

      # Pre-load parts registry for injection after scan
      all_parts = TakeoffTool.load_parts rescue {}
      parts_found = 0

      # Pre-collect CAD overlay group definitions so scanner skips them
      cad_overlay_defs = {}
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid? && grp.get_attribute('FF_CadOverlay', 'sheet_name')
        mark_cad_skip_defs(grp.definition, cad_overlay_defs) if grp.respond_to?(:definition)
      end

      defs = model.definitions.select { |d| !d.image? }
      total_defs = defs.length
      progress.call("Found #{total_defs} definitions to process#{filter_label}") if progress
      Dashboard.scan_log_status("CLASSIFYING ENTITIES") rescue nil
      entity_count = 0
      discovered_cats = {}

      defs.each_with_index do |defn, idx|
        inst_count = defn.instances.length
        progress.call("Definition #{idx+1}/#{total_defs}: #{defn.name} (#{inst_count} instances)") if progress && inst_count > 0
        defn.instances.each do |inst|
          next if seen[inst.entityID]; seen[inst.entityID] = true

          # Model source filter: skip entities not matching the requested scope
          if model_source_filter
            ms = inst.get_attribute('FormAndField', 'model_source') || 'model_a'
            if model_source_filter == 'model_a'
              next unless ms == 'model_a'
            elsif model_source_filter == 'model_b'
              next if ms == 'model_a'
            end
          end

          # Detect part groups: skip processing, inject as 1 EA later
          if (inst.get_attribute('FormAndField', 'is_part') rescue nil)
            reg[inst.entityID] = inst
            parts_found += 1
            next
          end

          # Skip entities inside CAD overlay groups
          next if cad_overlay_defs[inst.parent]

          # Skip entities nested inside a part group (their parent def is a part)
          if inst.parent.is_a?(Sketchup::ComponentDefinition)
            parent_is_part = inst.parent.instances.any? { |pi|
              (pi.get_attribute('FormAndField', 'is_part') rescue nil) == true
            }
            if parent_is_part
              next
            end
          end

          reg[inst.entityID] = inst
          prev_len = results.length
          process(inst, defn, results)
          entity_count += 1
          # Emit newly discovered categories as pills
          if results.length > prev_len
            cat = results.last[:parsed][:auto_category] rescue nil
            if cat && cat != '_IGNORE' && !discovered_cats[cat]
              discovered_cats[cat] = true
              Dashboard.scan_log_pill(cat) rescue nil
            end
          end
          Dashboard.scan_log_count(entity_count) if entity_count % 25 == 0
        end
      end

      Dashboard.scan_log_count(entity_count) rescue nil
      Dashboard.scan_log_status("FINALIZING") rescue nil

      # Inject part results: 1 EA per named part group
      if all_parts.any?
        puts "[FF Scanner] Found #{parts_found} part group(s), injecting #{all_parts.length} part result(s)"
        progress.call("Injecting #{all_parts.length} part(s)") if progress
        all_parts.each do |part_name, pdata|
          cat = pdata['category'] || 'Uncategorized'
          sub = pdata['subcategory'] || ''
          grp_eid = pdata['group_id']
          results << {
            entity_id: grp_eid || "part_#{part_name}",
            entity_type: 'Part',
            tag: '',
            definition_name: part_name,
            display_name: part_name,
            instance_name: part_name,
            is_solid: false,
            instance_count: 1,
            ifc_type: nil,
            volume_in3: 0.0, volume_ft3: 0.0, volume_bf: 0.0,
            bb_width_in: 0.0, bb_height_in: 0.0, bb_depth_in: 0.0,
            linear_ft: nil, area_sf: nil, material: nil,
            parsed: {
              raw: part_name,
              element_type: nil, function: nil, material: nil,
              thickness: nil, size_nominal: nil, revit_id: nil,
              auto_category: cat,
              auto_subcategory: sub,
              measurement_type: 'ea',
              category_source: 'part',
              confidence: :high,
              cost_code: nil
            },
            warnings: [],
            part_name: part_name,
            part_child_count: pdata['child_count'] || 0
          }
          if !discovered_cats[cat]
            discovered_cats[cat] = true
            Dashboard.scan_log_pill(cat) rescue nil
          end
        end
      end

      progress.call("Processing warnings...") if progress
      check_warnings(results)

      # Safety: deduplicate by entity_id (should not happen but guards against double-counting)
      before = results.length
      results.uniq! { |r| r[:entity_id] }
      if results.length < before
        dups = before - results.length
        puts "[FF Scanner] WARNING: removed #{dups} duplicate entities from scan results"
        progress.call("Removed #{dups} duplicate entities") if progress
      end

      # Report IFC geometry children skipped
      if @ifc_geom_skipped && @ifc_geom_skipped > 0
        puts "[FF Scanner] Skipped #{@ifc_geom_skipped} IFC geometry children (parent carries metadata)"
        progress.call("Skipped #{@ifc_geom_skipped} IFC geometry children") if progress
        @ifc_geom_skipped = 0
      end

      # Post-scan: remove nested children from EA-measured categories
      # (e.g., a can light's bulb/trim/housing shouldn't count as separate fixtures)
      progress.call("Filtering nested EA children...") if progress
      filter_ea_children(results, reg)

      # Post-scan: detect possible overcounts for EA categories
      @overcount_warnings = detect_overcounts(results, reg)
      if @overcount_warnings.any?
        puts "[FF Scanner] Overcount warnings: #{@overcount_warnings.length} categories flagged"
        @overcount_warnings.each { |w| puts "  #{w[:message]}" }
      end

      progress.call("Sorting #{results.length} results") if progress
      [results.sort_by{|r|[r[:tag]||'zzz',r[:display_name]||'']}, reg]
    end

    def self.overcount_warnings
      @overcount_warnings || []
    end

    # ═══════════════════════════════════════════════════════════
    # recalculate_sf — Re-compute area_sf for all scan results
    #   using current category assignments (no full rescan needed)
    # ═══════════════════════════════════════════════════════════

    def self.recalculate_sf
      results = TakeoffTool.scan_results
      return 0 unless results && !results.empty?

      ca = TakeoffTool.category_assignments
      updated = 0

      results.each do |r|
        eid = r[:entity_id]
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?

        defn = e.respond_to?(:definition) ? e.definition : nil
        next unless defn

        # Use user's assigned category, fall back to auto_category
        user_cat = ca[eid]
        cat = user_cat || r[:parsed][:auto_category]
        mtype = r[:parsed][:measurement_type] || Parser.measurement_for(cat)

        next unless %w[sf sf_cy sf_sheets].include?(mtype)

        geo_sf = face_area_for_entity(defn, cat, e.transformation)
        next unless geo_sf

        old_sf = r[:area_sf]
        if old_sf.nil? || (geo_sf.round(2) - (old_sf || 0)).abs > 0.1
          r[:area_sf] = geo_sf.round(2)
          updated += 1
        end
      end

      puts "Takeoff: Recalculated SF for #{updated} entities"
      updated
    end

    private

    # ═══════════════════════════════════════════════════════════
    # process — Per-entity processing
    # ═══════════════════════════════════════════════════════════

    def self.process(inst, defn, results)
      iname = (inst.name && !inst.name.empty?) ? inst.name : nil
      dname = defn.name || ''
      display = iname || dname
      tag = inst.layer ? inst.layer.name : 'Untagged'

      # Flatten pass fallback: inherit name/tag from flattened parent
      inherited_name = inst.get_attribute('FF_Flatten', 'inherited_name') rescue nil
      if inherited_name && display =~ /^Component\d*$/i
        display = inherited_name
      end
      parent_tag = inst.get_attribute('FF_Flatten', 'parent_tag') rescue nil
      if parent_tag && (tag == 'Untagged' || tag == 'Layer0')
        tag = parent_tag
      end

      # Compute material
      mat = nil
      if inst.material
        mat = inst.material.display_name
      else
        f = defn.entities.grep(Sketchup::Face).first
        mat = f.material.display_name if f && f.material
      end

      # Compute IFC type (check IFC 4, IFC 2x3, and other schema versions)
      ifc = nil
      if defn.attribute_dictionaries
        a = defn.attribute_dictionaries['AppliedSchemaTypes']
        if a
          ifc = a['IFC 4'] || a['IFC 2x3'] || a['IFC 4x3'] || a['IFC2x3']
        end
      end
      # Flatten pass fallback: inherit IFC type from flattened parent
      if !ifc
        parent_ifc = inst.get_attribute('FF_Flatten', 'parent_ifc_type') rescue nil
        ifc = parent_ifc if parent_ifc
      end

      # Skip IFC organizational containers
      return if @is_ifc_model && %w[IfcBuilding IfcBuildingStorey IfcSite IfcProject].include?(tag)

      # Skip IFC geometry children of named elements.
      # IFC imports create: NamedElement (instance name "8x6 Joist") → Component (geometry).
      # The parent carries all metadata and is scanned separately. The child is a
      # duplicate with no name/IFC type — skip it to avoid double-counting.
      if @is_ifc_model && display =~ /^Component\d*$/i
        pd = inst.parent
        if pd.is_a?(Sketchup::ComponentDefinition)
          if pd.instances.any? { |pi| pi.name && !pi.name.empty? && pi.name !~ /^Component\d*$/i }
            @ifc_geom_skipped = (@ifc_geom_skipped || 0) + 1
            return
          end
        end
      end

      # Skip datum/level markers
      return if display =~ /^T\.O\.|^B\.O\.|^Level|^Datum|S\.F\./i

      # Skip junk entries
      return if tag == '<Revit Missing Links>'
      if tag == 'Layer0'
        # Allow through if entity has a classifiable material name (Cadworks-style)
        has_known_mat = mat && (mat =~ WOOD_SPECIES_RE || mat =~ FRAMING_MAT_RE ||
                                mat =~ ENGINEERED_MAT_RE || mat =~ STEEL_MAT_RE ||
                                mat =~ CONCRETE_MAT_RE)
        return unless iname || has_known_mat
        return if display =~ /^<not associated>|^Project.*\.rvt|^Undefined/i
      end

      # ── Multi-strategy parse ──
      parsed = scan_entity(inst, defn, display, tag, mat, ifc)
      return unless parsed
      return if parsed[:auto_category] == '_IGNORE'

      is_solid = false; vol = 0.0
      begin
        if inst.respond_to?(:manifold?) && inst.manifold?
          is_solid = true; vol = inst.volume
        end
      rescue; end

      bb = inst.bounds
      w = bb.width.to_f; h = bb.height.to_f; d = bb.depth.to_f

      # Each scan result = 1 entity. No multiplication.
      cnt = 1

      vi3 = vol.to_f; vf3 = vi3/1728.0; vbf = vi3/144.0

      area = nil
      if parsed[:thickness] && is_solid
        tin = Parser.dim_to_in(parsed[:thickness])
        area = vi3/tin/144.0 if tin && tin > 0
      end

      # Compute LF from actual edge geometry.
      # Wall categories use XY-projected edge geometry (handles rotated/angled walls).
      # Other LF items use extrusion detection. BB fallback as last resort.
      acat = parsed[:auto_category]
      mtype = parsed[:measurement_type] || Parser.measurement_for(acat)
      geo_lf = nil
      if mtype == 'lf'
        if acat =~ WALL_LF_RE
          geo_lf = wall_linear_ft(defn, inst.transformation)
        elsif acat =~ BEAM_RE
          geo_lf = beam_linear_ft(defn, inst.transformation)
        end
        geo_lf ||= geometry_linear_ft(defn, inst.transformation)
      end
      if geo_lf
        linear_ft = geo_lf
      else
        longest_in = [w, h, d].max
        linear_ft = longest_in / 12.0
      end

      # For Rooms: compute area from BB width x depth (two largest dims)
      if parsed[:auto_category] == 'Rooms'
        dims = [w, h, d].sort
        area = (dims[1] * dims[2]) / 144.0
      end

      # Extract thickness from foundation names if parser didn't find one
      if parsed[:auto_category] =~ /Foundation/i && !parsed[:thickness]
        ft = display =~ /(\d+)\s*inch/i ? "#{$1}\"" : nil
        parsed[:thickness] = ft if ft
      end

      # ─── Dimension enrichment: set size_nominal from BB when parser didn't ───
      dims = [w, h, d].sort  # dims[0]=shortest, dims[1]=middle, dims[2]=longest
      cat = parsed[:auto_category]
      subcat = parsed[:auto_subcategory]

      if !parsed[:size_nominal] || parsed[:size_nominal].to_s.empty?
        if cat == 'Concrete' && (subcat =~ /Footing/i || subcat == 'Grade Beam')
          # Footings: width x depth (two shortest dims)
          fw = dims[1]; fd = dims[0]
          parsed[:size_nominal] = "#{fw.round(1)}\" x #{fd.round(1)}\""
          parsed[:thickness] ||= "#{fd.round(1)}\""
        elsif cat == 'Concrete' && subcat =~ /Slab|Grade/i
          # Slabs: thickness only (shortest dim)
          parsed[:size_nominal] = "#{dims[0].round(1)}\""
          parsed[:thickness] ||= "#{dims[0].round(1)}\""
        elsif cat == 'Concrete' && subcat =~ /Wall/i
          # Concrete walls: thickness (shortest dim)
          parsed[:size_nominal] = "#{dims[0].round(1)}\""
          parsed[:thickness] ||= "#{dims[0].round(1)}\""
        elsif cat == 'Concrete' && subcat =~ /Pier/i
          # Piers: width x depth (two shortest dims)
          fw = dims[1]; fd = dims[0]
          parsed[:size_nominal] = "#{fw.round(1)}\" x #{fd.round(1)}\""
        elsif cat =~ /Wall Framing|Wall Finish|Wall Structure|Wall Sheathing|Masonry|Foundation Walls|Drywall|Stucco|Siding/i
          # Walls: thickness (shortest dim)
          parsed[:size_nominal] ||= parsed[:thickness]
          if !parsed[:size_nominal] || parsed[:size_nominal].to_s.empty?
            parsed[:size_nominal] = "#{dims[0].round(1)}\""
          end
        end
      end

      # ─── SF area from face geometry (dominant side) ───
      # Always use face geometry for all SF items — volume/thickness is
      # unreliable for compound structures (inflates area).
      sf_cat = inst.get_attribute('TakeoffAssignments', 'category') || cat
      mtype = parsed[:measurement_type] || Parser.measurement_for(sf_cat)
      if %w[sf sf_cy sf_sheets].include?(mtype)
        geo_sf = face_area_for_entity(defn, sf_cat, inst.transformation)
        if geo_sf
          area = geo_sf
        end
      end

      results << {
        entity_id: inst.entityID, entity_type: inst.typename, tag: tag,
        definition_name: dname, display_name: display, instance_name: iname,
        is_solid: is_solid, instance_count: cnt, ifc_type: ifc,
        volume_in3: vi3.round(2), volume_ft3: vf3.round(4), volume_bf: vbf.round(2),
        bb_width_in: w.round(2), bb_height_in: h.round(2), bb_depth_in: d.round(2),
        linear_ft: linear_ft.round(2),
        area_sf: area ? area.round(2) : nil, material: mat,
        parsed: parsed, warnings: []
      }
    end

    # ═══════════════════════════════════════════════════════════
    # check_warnings — Cross-entity warning logic
    # ═══════════════════════════════════════════════════════════

    def self.check_warnings(results)
      walls = results.select{|r| r[:tag]=='Walls'}
      wc = walls.map{|r| r[:parsed][:auto_category]}.compact.uniq
      if wc.any?{|c| c=~/Siding|Exterior Finish/i} && !wc.any?{|c| c=~/Sheathing/i}
        walls.each{|r| r[:warnings]<<"No wall sheathing detected" if r[:parsed][:auto_category]=~/Siding|Exterior Finish/i}
      end
      if wc.any?{|c| c=~/Wall Framing/i} && !wc.any?{|c| c=~/Drywall/i}
        walls.each{|r| r[:warnings]<<"No drywall detected on framed walls" if r[:parsed][:auto_category]=~/Wall Framing/i}
      end

      roofs = results.select{|r| r[:tag]=='Roofs'}
      rc = roofs.map{|r| r[:parsed][:auto_category]}.compact.uniq
      if rc.any?{|c| c=~/Roofing|Metal Roofing|Shingle/i} && !rc.any?{|c| c=~/Sheathing/i}
        roofs.each{|r| r[:warnings]<<"No roof sheathing detected" if r[:parsed][:auto_category]=~/Roofing|Metal|Shingle/i}
      end
    end

    # ═══════════════════════════════════════════════════════════
    # scan_entity — Multi-strategy parser orchestrator
    #
    # Tries all parsing strategies and picks the highest confidence result.
    # First match wins on ties.
    #
    # Strategies:
    #   1+2. IFC Parser        (HIGH/MEDIUM)  — IFC models only
    #   3.   Material + BBox   (MEDIUM)        — all models
    #   4.   Existing Parser   (HIGH/LOW)      — all models (Revit names, tags)
    #   5.   Keyword Scan      (LOW)           — all models (name+tag+mat keywords)
    #   6.   Material Fallback (LOW)           — all models (material name only)
    # ═══════════════════════════════════════════════════════════

    # Recursively mark definitions inside CAD overlays for scanner skip
    # Handles both Groups and ComponentInstances (DWG imports create ComponentInstances)
    def self.mark_cad_skip_defs(defn, skip_set)
      skip_set[defn] = true
      defn.entities.each do |e|
        if (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.respond_to?(:definition)
          next if skip_set[e.definition]  # avoid cycles
          mark_cad_skip_defs(e.definition, skip_set)
        end
      end
    end

    def self.scan_entity(inst, defn, display, tag, mat, ifc_type)
      # Strategy 0: Steel shape early-exit — W shapes, HSS, plates, L-angles, C-channels
      # Assigns specific categories for identifiable steel shapes
      if display =~ /\bW\d+[xX]\d+\b/ || display =~ /^W-Wide Flange\b/i
        return {
          raw: display, element_type: 'Steel Shape', function: nil,
          material: mat, thickness: nil, size_nominal: display[/W[\d.]+[xX][\d.]+/],
          revit_id: nil, auto_category: 'W-Beams',
          auto_subcategory: display[/W\d+/] || 'W-Beam',
          measurement_type: 'lf',
          category_source: 'name', confidence: :high
        }
      end
      if display =~ /\bHSS\d/i
        return {
          raw: display, element_type: 'Steel Shape', function: nil,
          material: mat, thickness: nil, size_nominal: display[/HSS[\d.xX\/]+/],
          revit_id: nil, auto_category: 'Steel Tubes (HSS)',
          auto_subcategory: display[/HSS[\d.xX\/]+/] || 'HSS',
          measurement_type: 'lf',
          category_source: 'name', confidence: :high
        }
      end
      if display =~ /^PL\d/i || display =~ /\bPL\s*\d/i
        return {
          raw: display, element_type: 'Steel Shape', function: nil,
          material: mat, thickness: nil, size_nominal: display,
          revit_id: nil, auto_category: 'Steel Plates',
          auto_subcategory: 'Plate',
          measurement_type: 'ea',
          category_source: 'name', confidence: :high
        }
      end
      if display =~ /\b[LC]\d+[xX]\d+\b/
        return {
          raw: display, element_type: 'Steel Shape', function: nil,
          material: mat, thickness: nil, size_nominal: display[/[LC][\d.]+[xX][\d.]+/],
          revit_id: nil, auto_category: 'Structural Steel',
          auto_subcategory: display[/[LC]\d+/] || 'Steel',
          measurement_type: 'lf',
          category_source: 'name', confidence: :high
        }
      end

      candidates = []

      # Strategy 1+2: IFC-aware parser (name-based = HIGH, tag-based = MEDIUM)
      if @is_ifc_model
        r = IFCParser.parse_ifc(inst)
        if r
          r[:confidence] ||= (r[:category_source] == 'ifc_name') ? :high : :medium
          candidates << r
        end
      end

      # Strategy 3: Material + bounding box (Cadworks-style models)
      r = try_material_bbox(inst, display, mat)
      candidates << r if r

      # Strategy 3.5: Cost Code Map parser
      bb = inst.respond_to?(:bounds) ? inst.bounds : nil
      cc_dims = bb ? [bb.width.to_f, bb.height.to_f, bb.depth.to_f] : nil
      r = CostCodeParser.classify(display, tag, mat, ifc_type, cc_dims)
      candidates << r if r

      # Strategy 4: Existing parser (Revit name patterns + tag fallback)
      r = Parser.parse_definition(display, tag, material: mat, ifc_type: ifc_type)
      if r && r[:auto_category] != '_IGNORE'
        r[:confidence] ||= case r[:category_source]
          when 'name' then :high
          when 'material' then :medium
          when 'tag', 'ifc' then :low
          else :none
        end
        candidates << r
      end

      # Strategy 5: Generic keyword scan (last resort)
      r = try_keyword_scan(display, tag, mat)
      candidates << r if r

      # Strategy 6: Material-only fallback (catches generic ComponentNNNN with clear materials)
      r = try_material_fallback(display, mat)
      candidates << r if r

      # Pick highest confidence — first match wins ties
      best = nil; best_score = -1
      candidates.each do |c|
        s = CONFIDENCE_SCORES[c[:confidence] || :none]
        if s > best_score
          best_score = s; best = c
        end
      end

      # Tier 2: Learned rules override — user-verified classifications
      # Applied AFTER strategy selection so they always win when they match
      learned = LearningSystem.apply(display, mat, ifc_type, definition_name: defn&.name)
      if learned
        learned[:confidence] = :high
        learned[:cost_code_score] = 92
        best = learned
      end

      best
    end

    # ═══════════════════════════════════════════════════════════
    # Strategy 3: Material + Bounding Box Parser
    #
    # For models where material names indicate the type (e.g. Cadworks:
    # "Framing", "Oak", "Steel", "Concrete1") and bounding box gives size.
    # ═══════════════════════════════════════════════════════════

    def self.try_material_bbox(inst, display, mat)
      return nil unless mat && !mat.empty?

      bb = inst.respond_to?(:bounds) ? inst.bounds : nil
      return nil unless bb

      dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort
      # dims[0] = smallest (cross-section), dims[2] = longest (length)

      if mat =~ ENGINEERED_MAT_RE
        return mat_bbox_engineered(display, mat, dims)
      elsif mat =~ WOOD_SPECIES_RE || mat =~ FRAMING_MAT_RE
        return mat_bbox_wood(display, mat, dims)
      elsif mat =~ STEEL_MAT_RE
        return mat_bbox_steel(display, mat, dims)
      elsif mat =~ REBAR_MAT_RE
        return mat_bbox_rebar(display, mat, dims)
      elsif mat =~ CONCRETE_MAT_RE
        return mat_bbox_concrete(display, mat, dims)
      end

      nil
    end

    # ─── Wood (species or "Framing" material) ─────────────────

    def self.mat_bbox_wood(display, mat, dims)
      cross_w = dims[0]  # smallest
      cross_h = dims[1]  # middle

      # Sanity: cross-section should be reasonable for lumber/timber
      return nil if cross_w < 0.5 || cross_h > 30

      nom_w = to_nominal(cross_w)
      nom_h = to_nominal(cross_h)
      is_species = !!(mat =~ WOOD_SPECIES_RE)

      if nom_w && nom_h
        size_str = "#{nom_w}x#{nom_h}"
      elsif is_species
        # Species material — always report approximate size even if non-standard
        size_str = "~#{cross_w.round(1)}x#{cross_h.round(1)}"
      elsif cross_w >= 5.5 && cross_h >= 5.5
        size_str = "~#{cross_w.round(1)}x#{cross_h.round(1)}"
      else
        return nil  # Can't determine meaningful lumber size for "Framing" material
      end

      # Species material = ALWAYS Timber Frame (hardwood override)
      if is_species
        cat = 'Timber Frame'
      elsif cross_w >= 5.5 && cross_h >= 5.5
        cat = 'Timber Frame'
      else
        cat = 'Structural Lumber'
      end

      member = nil
      begin; member = IFCParser.find_member_type(display); rescue; end
      mt = cat == 'Timber Frame' ? 'ea_bf' : 'ea'

      {
        raw: display,
        element_type: cat == 'Timber Frame' ? 'Timber Member' : 'Lumber',
        function: member,
        material: mat,
        thickness: nil,
        size_nominal: size_str,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: member,
        measurement_type: mt,
        category_source: 'material_bbox',
        confidence: :medium,
        ifc_parsed: {
          material_type: 'wood',
          dimensions: { width: cross_w.round(3), height: cross_h.round(3) },
          confidence: :medium
        }
      }
    end

    # ─── Engineered lumber (LVL, Glulam, PSL, etc.) ──────────

    def self.mat_bbox_engineered(display, mat, dims)
      eng_type = mat.match(ENGINEERED_MAT_RE)[1]
      member = nil
      begin; member = IFCParser.find_member_type(display); rescue; end

      {
        raw: display,
        element_type: 'Engineered Lumber',
        function: eng_type,
        material: mat,
        thickness: nil,
        size_nominal: nil,
        revit_id: nil,
        auto_category: 'Structural Lumber',
        auto_subcategory: member || eng_type,
        measurement_type: 'ea',
        category_source: 'material_bbox',
        confidence: :medium,
        ifc_parsed: {
          material_type: 'wood',
          dimensions: nil,
          confidence: :medium
        }
      }
    end

    # ─── Steel ────────────────────────────────────────────────

    def self.mat_bbox_steel(display, mat, dims)
      cross_w = dims[0]
      cross_h = dims[1]
      length_in = dims[2]

      # Only classify if elongated (length > 2x cross-section height)
      return nil if length_in < cross_h * 2

      subcat = (cross_w - cross_h).abs < 0.5 ? 'Tube/Pipe' : 'Beam/Column'

      {
        raw: display,
        element_type: 'Steel Member',
        function: subcat,
        material: mat,
        thickness: nil,
        size_nominal: "~#{cross_w.round(1)}x#{cross_h.round(1)}",
        revit_id: nil,
        auto_category: 'Structural Steel',
        auto_subcategory: subcat,
        measurement_type: 'lf',
        category_source: 'material_bbox',
        confidence: :medium,
        ifc_parsed: {
          material_type: 'steel',
          dimensions: { width: cross_w.round(3), height: cross_h.round(3) },
          confidence: :medium
        }
      }
    end

    # ─── Concrete ─────────────────────────────────────────────

    def self.mat_bbox_concrete(display, mat, dims)
      thickness_in = dims[0]

      # Check for foundation/concrete keywords in display name
      cat = 'Concrete'
      subcat = nil
      FOUNDATION_KW.each do |re, kw_cat, kw_sub|
        if display =~ re
          cat = kw_cat
          subcat = kw_sub
          break
        end
      end

      mt = Parser.measurement_for(cat)

      {
        raw: display,
        element_type: 'Concrete',
        function: subcat,
        material: mat,
        thickness: "#{thickness_in.round(1)}\"",
        size_nominal: nil,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: subcat,
        measurement_type: mt,
        category_source: 'material_bbox',
        confidence: :medium,
        ifc_parsed: {
          material_type: 'concrete',
          dimensions: { thickness: thickness_in.round(2) },
          confidence: :medium
        }
      }
    end

    # ─── Rebar / Reinforcement ─────────────────────────────────

    def self.mat_bbox_rebar(display, mat, dims)
      {
        raw: display,
        element_type: 'Reinforcement',
        function: 'Rebar',
        material: mat,
        thickness: nil,
        size_nominal: nil,
        revit_id: nil,
        auto_category: 'Concrete',
        auto_subcategory: 'Rebar/Reinforcement',
        measurement_type: 'lf',
        category_source: 'material_bbox',
        confidence: :medium,
        ifc_parsed: {
          material_type: 'steel',
          dimensions: nil,
          confidence: :medium
        }
      }
    end

    # ═══════════════════════════════════════════════════════════
    # Strategy 5: Generic Keyword Scan
    #
    # Scans display name + tag + material for category keywords.
    # Only fires when no higher-confidence strategy matched.
    # ═══════════════════════════════════════════════════════════

    def self.try_keyword_scan(display, tag, mat)
      text = "#{display} #{tag} #{mat}"

      KEYWORD_MAP.each do |re, cat|
        if text =~ re
          return {
            raw: display,
            element_type: nil,
            function: nil,
            material: mat,
            thickness: nil,
            size_nominal: nil,
            revit_id: nil,
            auto_category: cat,
            auto_subcategory: nil,
            measurement_type: Parser.measurement_for(cat),
            category_source: 'keyword',
            confidence: :low
          }
        end
      end
      nil
    end

    # ═══════════════════════════════════════════════════════════
    # Strategy 6: Material-Only Fallback
    #
    # Checks ONLY the material display_name against keyword lists.
    # Catches generic ComponentNNNN items that have clear materials
    # (e.g. material "Oak" on "Component2235").
    # Runs last, lowest confidence.
    # ═══════════════════════════════════════════════════════════

    def self.try_material_fallback(display, mat)
      return nil unless mat && !mat.empty?

      MATERIAL_FALLBACK_MAP.each do |re, cat, subcat|
        if mat =~ re
          return {
            raw: display,
            element_type: nil,
            function: nil,
            material: mat,
            thickness: nil,
            size_nominal: nil,
            revit_id: nil,
            auto_category: cat,
            auto_subcategory: subcat,
            measurement_type: Parser.measurement_for(cat),
            category_source: 'material_fallback',
            confidence: :low
          }
        end
      end
      nil
    end

    # ═══════════════════════════════════════════════════════════
    # Helpers
    # ═══════════════════════════════════════════════════════════

    # ═══════════════════════════════════════════════════════════
    # SF Area — from actual face geometry only. No BB fallback.
    #
    # Three paths:
    #   Sheet goods → sum all faces on the dominant side
    #   Enclosed 3D → largest single face
    #   Single-sided → total face area
    # ═══════════════════════════════════════════════════════════

    SHEET_GOOD_RE = /sheathing|drywall|plywood|osb|roofing|siding|insulation|membrane|soffit|fascia|gypcrete|decking|flooring|tile|stucco|wall\s*finish|ceiling|shingle/i

    NORMAL_TOLERANCE_RAD = 18.0 * Math::PI / 180.0

    def self.load_sampled_normal(category)
      return nil unless category
      m = Sketchup.active_model
      return nil unless m
      json = m.get_attribute('TakeoffSFNormals', category) rescue nil
      return nil unless json
      require 'json'
      arr = JSON.parse(json) rescue nil
      return nil unless arr.is_a?(Array) && arr.length == 3
      n = Geom::Vector3d.new(arr[0], arr[1], arr[2])
      n.length > 0.001 ? n.normalize : nil
    end

    def self.face_area_for_entity(defn, category = nil, xform = nil)
      ents = defn.respond_to?(:entities) ? defn.entities : nil
      return nil unless ents

      xf = xform || Geom::Transformation.new

      # Use top-level faces when available (avoids counting compound
      # structure layers from nested sub-groups).  Only recurse into
      # child groups/components when the definition has no direct faces
      # (e.g. flooring elements with all geometry nested).
      top_faces = ents.grep(Sketchup::Face)
      if top_faces.empty?
        face_data = []
        collect_faces_for_sf(ents, xf, face_data)
        return nil if face_data.empty?
      else
        face_data = top_faces.map { |f| { face: f, xform: xf } }
      end

      dname = defn.respond_to?(:name) ? defn.name : ''

      # Dominant-side with compound-layer deduplication:
      # 1. Group faces by world-space normal direction
      # 2. Within each normal group, sub-group by plane distance
      #    (separates compound structure layers on parallel planes)
      # 3. Keep only the largest plane per normal direction
      # 4. Dominant side = normal direction with largest deduped area
      normal_groups = {}
      face_data.each do |fd|
        wn = fd[:xform] * fd[:face].normal
        key = "#{wn.x.round(1)},#{wn.y.round(1)},#{wn.z.round(1)}"
        normal_groups[key] ||= { wn: wn, fds: [] }
        normal_groups[key][:fds] << fd
      end

      # ── Sampled normal override: filter to matching normal groups ──
      sampled = load_sampled_normal(category)
      if sampled
        matched_area = 0.0
        normal_groups.each do |_nkey, grp|
          wn = grp[:wn]
          wn_n = wn.length > 0.001 ? Geom::Vector3d.new(wn.x, wn.y, wn.z).normalize : wn
          angle = sampled.angle_between(wn_n)
          next unless angle < NORMAL_TOLERANCE_RAD

          fds = grp[:fds]
          if fds.length == 1
            matched_area += world_face_area(fds[0][:face], fds[0][:xform])
          else
            planes = {}
            fds.each do |fd|
              wp = fd[:xform] * fd[:face].vertices.first.position
              d = wn.x * wp.x + wn.y * wp.y + wn.z * wp.z
              d_key = d.round(0)
              planes[d_key] ||= 0.0
              planes[d_key] += world_face_area(fd[:face], fd[:xform])
            end
            matched_area += planes.values.max || 0.0
          end
        end
        sf = matched_area / 144.0
        puts "[FF Measure] '#{dname}': sampled normal = #{sf.round(1)} SF (#{face_data.length} faces)"
        return sf
      end

      # ── Default: dominant side (largest normal group) ──
      # Compute deduped area per normal group
      side_areas = {}
      normal_groups.each do |nkey, grp|
        fds = grp[:fds]
        if fds.length == 1
          side_areas[nkey] = world_face_area(fds[0][:face], fds[0][:xform])
        else
          wn = grp[:wn]
          planes = {}
          fds.each do |fd|
            wp = fd[:xform] * fd[:face].vertices.first.position
            d = wn.x * wp.x + wn.y * wp.y + wn.z * wp.z
            d_key = d.round(0)
            planes[d_key] ||= 0.0
            planes[d_key] += world_face_area(fd[:face], fd[:xform])
          end
          side_areas[nkey] = planes.values.max || 0.0
        end
      end

      dom_key = side_areas.max_by { |_k, a| a }&.first
      dom_area = side_areas[dom_key] || 0.0

      # Prefer top-facing surface for horizontal elements (floors, slabs, roofing, decking).
      # If an upward-facing group (z > 0.5, i.e. within ~60° of horizontal) has area
      # >= 70% of the dominant side, pick top over bottom/sides.
      top_key = nil
      top_area = 0.0
      normal_groups.each do |nkey, grp|
        wn = grp[:wn]
        wn_len = Math.sqrt(wn.x**2 + wn.y**2 + wn.z**2)
        next if wn_len < 0.001
        z_up = wn.z / wn_len
        if z_up > 0.5 && side_areas[nkey] > top_area
          top_key = nkey
          top_area = side_areas[nkey]
        end
      end

      if top_key && top_key != dom_key && top_area >= dom_area * 0.7
        sf = top_area / 144.0
        puts "[FF Measure] '#{dname}': TOP SURFACE = #{sf.round(1)} SF (preferred over dominant #{(dom_area / 144.0).round(1)} SF)"
      else
        sf = (top_key == dom_key && top_key ? top_area : dom_area) / 144.0
        puts "[FF Measure] '#{dname}': dominant side = #{sf.round(1)} SF (#{face_data.length} faces, #{normal_groups.length} normals)"
      end
      sf
    end

    # Recursively collect faces from a definition and its nested groups/components
    def self.collect_faces_for_sf(ents, xform, result)
      ents.grep(Sketchup::Face).each { |f| result << { face: f, xform: xform } }
      ents.each do |child|
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        collect_faces_for_sf(child_defn.entities, xform * child.transformation, result)
      end
    end

    # enclosed_3d check using face_data with per-face transforms
    def self.enclosed_3d_data?(face_data)
      normals = {}
      face_data.first(20).each do |fd|
        wn = fd[:xform] * fd[:face].normal
        key = "#{wn.x.round(1)},#{wn.y.round(1)},#{wn.z.round(1)}"
        normals[key] = true
      end
      normals.length >= 3
    end

    # ═══════════════════════════════════════════════════════════
    # geometry_linear_ft — Compute LF from face geometry
    #
    # For any extrusion (trim, fascia, framing — straight, L, U, sloped):
    #   path_length = total_side_face_area / profile_perimeter
    #
    # End faces (cross-section caps) are identified as the smallest faces.
    # Side face area = total area minus end faces.
    # Profile perimeter = edge lengths of one end face.
    # Works for any profile shape and any bend/slope.
    # Returns nil if geometry doesn't look like an extrusion.
    # ═══════════════════════════════════════════════════════════

    def self.geometry_linear_ft(defn, xform = nil)
      xf = xform || Geom::Transformation.new
      face_data = []
      collect_faces_for_lf(defn.entities, xf, face_data)

      # Filter degenerate faces, need at least 2 end caps + 1 side
      face_data.reject! { |fd| fd[:area] < 0.1 }
      return nil if face_data.length < 3

      face_data.sort_by! { |fd| fd[:area] }
      total_area = face_data.sum { |fd| fd[:area] }

      # End faces are the two smallest with similar areas,
      # whose combined area is a small fraction of the total
      ef1 = face_data[0]
      ef2 = nil
      (1...[face_data.length, 8].min).each do |i|
        candidate = face_data[i]
        ratio = candidate[:area] / [ef1[:area], 0.01].max
        combined = ef1[:area] + candidate[:area]
        if ratio < 2.0 && combined < total_area * 0.20
          ef2 = candidate
          break
        end
      end

      return nil unless ef2

      perimeter = ef1[:perimeter]
      return nil if perimeter < 0.5

      side_area = total_area - ef1[:area] - ef2[:area]
      return nil if side_area < 1.0

      lf_in = side_area / perimeter
      lf_in / 12.0
    end

    # Compute wall LF from actual edge geometry projected onto XY plane.
    # Finds the longest horizontal edge in the entity — handles rotated,
    # angled, and compound walls correctly (no bounding-box dependency).
    def self.wall_linear_ft(defn, xform = nil)
      xf = xform || Geom::Transformation.new
      edge_segs = []
      collect_wall_edges(defn.entities, xf, edge_segs)
      return nil if edge_segs.empty?

      # Filter to horizontal edges (both endpoints within 1" Z of each other)
      horiz = edge_segs.select { |s| (s[:p1].z - s[:p2].z).abs < 1.0 }
      return nil if horiz.empty?

      # Compute XY-projected length for each horizontal edge
      horiz.each do |s|
        dx = s[:p2].x - s[:p1].x
        dy = s[:p2].y - s[:p1].y
        s[:xy_len] = Math.sqrt(dx * dx + dy * dy)
      end

      # Find longest horizontal edge — this is the wall's run length
      best = horiz.max_by { |s| s[:xy_len] }
      return nil unless best && best[:xy_len] > 0.5

      lf = best[:xy_len] / 12.0
      dname = defn.respond_to?(:name) ? defn.name : ''
      puts "[FF Measure] '#{dname}': wall LF = #{lf.round(2)} ft (#{edge_segs.length} edges, #{horiz.length} horizontal)"
      lf
    end

    def self.collect_wall_edges(ents, xform, result)
      ents.grep(Sketchup::Edge).each do |edge|
        p1 = xform * edge.start.position
        p2 = xform * edge.end.position
        result << { p1: p1, p2: p2 }
      end
      ents.each do |child|
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        collect_wall_edges(child_defn.entities, xform * child.transformation, result)
      end
    end

    # ═══════════════════════════════════════════════════════════
    # beam_linear_ft — Compute LF from the longest edge in entity
    #
    # Simple and reliable for beams, columns, structural steel.
    # The longest edge always runs along the member's length axis.
    # Returns nil if no edges found.
    # ═══════════════════════════════════════════════════════════

    def self.beam_linear_ft(defn, xform = nil)
      xf = xform || Geom::Transformation.new
      edge_data = []
      collect_edges_for_beam(defn.entities, xf, edge_data)
      return nil if edge_data.empty?

      best = edge_data.max_by { |e| e[:length] }
      return nil unless best && best[:length] > 0.5

      best[:length] / 12.0
    end

    def self.collect_edges_for_beam(ents, xform, result)
      ents.grep(Sketchup::Edge).each do |edge|
        p1 = xform * edge.start.position
        p2 = xform * edge.end.position
        result << { edge: edge, p1: p1, p2: p2, length: p1.distance(p2) }
      end
      ents.each do |child|
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        collect_edges_for_beam(child_defn.entities, xform * child.transformation, result)
      end
    end

    # ═══════════════════════════════════════════════════════════
    # beam_net_section — True cross-section via oriented bounding box
    #
    # Finds the leaf component (innermost geometry), then computes
    # an oriented bounding box aligned to the beam axis (longest
    # edge). Projects all vertices onto the plane perpendicular
    # to the beam axis to get the true W×H regardless of angle.
    #
    # Returns [w, h] in inches (sorted small to large), or nil.
    # ═══════════════════════════════════════════════════════════

    def self.beam_net_section(defn, _xform = nil)
      leaf = leaf_lumber_defn(defn)
      return nil unless leaf

      # Collect edges from the leaf definition in local space
      edges = []
      collect_edges_for_beam(leaf.entities, Geom::Transformation.new, edges)
      return nil if edges.length < 3

      # Beam axis = longest edge direction
      best = edges.max_by { |e| e[:length] }
      return nil unless best && best[:length] > 1.0

      axis = Geom::Vector3d.new(
        best[:p2].x - best[:p1].x,
        best[:p2].y - best[:p1].y,
        best[:p2].z - best[:p1].z
      )
      axis.normalize!

      # Find a cross-section edge (perpendicular to beam axis)
      x_dir = nil
      edges.each do |e|
        next if e[:length] < 0.3
        d = Geom::Vector3d.new(
          e[:p2].x - e[:p1].x,
          e[:p2].y - e[:p1].y,
          e[:p2].z - e[:p1].z
        )
        d.normalize!
        if d.dot(axis).abs < 0.3
          x_dir = d
          break
        end
      end

      # Fallback: arbitrary perpendicular
      unless x_dir
        ref = axis.x.abs < 0.9 ? Geom::Vector3d.new(1, 0, 0) : Geom::Vector3d.new(0, 1, 0)
        x_dir = axis.cross(ref)
      end

      # Orthogonalize: remove any axis component from x_dir
      ax_comp = x_dir.dot(axis)
      x_dir = Geom::Vector3d.new(
        x_dir.x - axis.x * ax_comp,
        x_dir.y - axis.y * ax_comp,
        x_dir.z - axis.z * ax_comp
      )
      return nil if x_dir.length < 0.001
      x_dir.normalize!

      y_dir = axis.cross(x_dir)
      return nil if y_dir.length < 0.001
      y_dir.normalize!

      # Project all edge endpoints onto the cross-section plane
      x_min = Float::INFINITY;  x_max = -Float::INFINITY
      y_min = Float::INFINITY;  y_max = -Float::INFINITY
      edges.each do |e|
        [e[:p1], e[:p2]].each do |pt|
          px = pt.x * x_dir.x + pt.y * x_dir.y + pt.z * x_dir.z
          py = pt.x * y_dir.x + pt.y * y_dir.y + pt.z * y_dir.z
          x_min = px if px < x_min;  x_max = px if px > x_max
          y_min = py if py < y_min;  y_max = py if py > y_max
        end
      end

      w = x_max - x_min
      h = y_max - y_min
      return nil if w < 0.1 || h < 0.1

      [w.round(2), h.round(2)].sort
    end

    # Walk down nested components to find the deepest definition
    # that contains only raw geometry (faces/edges, no sub-components).
    # For box beams with mixed lumber, picks the most common piece.
    def self.leaf_lumber_defn(defn)
      children = defn.entities.select { |e|
        e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
      }

      # No sub-components — this definition IS the leaf
      return defn if children.empty?

      # Recurse into children, count leaves by definition
      leaf_counts = {}
      children.each do |child|
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        leaf = leaf_lumber_defn(child_defn)
        next unless leaf
        leaf_counts[leaf] ||= 0
        leaf_counts[leaf] += 1
      end

      return nil if leaf_counts.empty?

      # Most common leaf = primary lumber piece
      leaf_counts.max_by { |_d, c| c }.first
    end

    def self.collect_faces_for_lf(ents, xform, result)
      ents.grep(Sketchup::Face).each do |f|
        area = world_face_area(f, xform)
        perimeter = 0.0
        f.loops.each do |loop|
          loop.edges.each do |edge|
            p1 = xform * edge.start.position
            p2 = xform * edge.end.position
            perimeter += p1.distance(p2)
          end
        end
        result << { area: area, perimeter: perimeter }
      end
      ents.each do |child|
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        collect_faces_for_lf(child_defn.entities, xform * child.transformation, result)
      end
    end

    # Like collect_faces_for_lf but also stores the face reference for debug painting.
    def self.collect_faces_for_lf_debug(ents, xform, result)
      ents.grep(Sketchup::Face).each do |f|
        area = world_face_area(f, xform)
        perimeter = 0.0
        f.loops.each do |loop|
          loop.edges.each do |edge|
            p1 = xform * edge.start.position
            p2 = xform * edge.end.position
            perimeter += p1.distance(p2)
          end
        end
        result << { face: f, area: area, perimeter: perimeter }
      end
      ents.each do |child|
        next unless child.is_a?(Sketchup::ComponentInstance) || child.is_a?(Sketchup::Group)
        child_defn = child.respond_to?(:definition) ? child.definition : nil
        next unless child_defn
        collect_faces_for_lf_debug(child_defn.entities, xform * child.transformation, result)
      end
    end

    # Compute face area in world coordinates, accounting for instance transform.
    # face.area is in the definition's local coordinate space.
    def self.world_face_area(face, xform = nil)
      return face.area unless xform
      begin
        mesh = face.mesh(0)
        total = 0.0
        (1..mesh.count_polygons).each do |pi|
          tri = mesh.polygon_points_at(pi)
          next unless tri && tri.length >= 3
          p0 = xform * tri[0]
          p1 = xform * tri[1]
          p2 = xform * tri[2]
          v1 = p1 - p0
          v2 = p2 - p0
          total += v1.cross(v2).length / 2.0
        end
        total
      rescue
        face.area
      end
    end

    # Sum faces that share the dominant normal direction.
    # Groups by rounded normal, picks the group with largest total area.
    def self.dominant_side_area(faces, xform = nil)
      groups = {}
      faces.each do |f|
        n = f.normal
        key = "#{n.x.round(1)},#{n.y.round(1)},#{n.z.round(1)}"
        groups[key] ||= 0.0
        groups[key] += world_face_area(f, xform)
      end
      # Return the largest group's total area
      groups.values.max || 0.0
    end

    # ═══════════════════════════════════════════════════════════
    # debug_area — Visual SF measurement debugger
    #
    # Paints measured faces green, excluded faces red, logs per-face breakdown.
    # Call via dashboard callback 'debugArea' with entity ID.
    # ═══════════════════════════════════════════════════════════

    def self.debug_area(eid)
      e = TakeoffTool.find_entity(eid)
      unless e && e.valid?
        puts "[FF Debug Area] Entity #{eid} not found"
        return
      end

      defn = e.respond_to?(:definition) ? e.definition : nil
      unless defn
        puts "[FF Debug Area] Entity #{eid} has no definition"
        return
      end

      xform = e.transformation

      # ── Collect faces using the SAME strategy as face_area_for_entity ──
      # Top-level faces first; only recurse if no direct faces exist
      top_faces = defn.entities.grep(Sketchup::Face)
      all_face_data = []
      collect_faces_for_sf(defn.entities, xform, all_face_data)
      if top_faces.empty?
        face_data = all_face_data
      else
        face_data = top_faces.map { |f| { face: f, xform: xform } }
      end
      if face_data.empty?
        puts "[FF Debug Area] Entity #{eid} '#{defn.name}' has no faces"
        return
      end

      # Determine category and measurement path
      sr = TakeoffTool.filtered_scan_results
      match = sr&.find { |r| r[:entity_id] == eid }
      cat = match ? match[:parsed][:auto_category] : nil
      dname = defn.name

      puts ""
      puts "═══════════════════════════════════════════════"
      puts "[FF Debug Area] Entity #{eid}: '#{dname}'"
      puts "  Category: #{cat || '(unknown)'}"
      puts "  Transform scale: x=#{Geom::Vector3d.new(xform.xaxis).length.round(4)} y=#{Geom::Vector3d.new(xform.yaxis).length.round(4)} z=#{Geom::Vector3d.new(xform.zaxis).length.round(4)}"
      puts "  Total faces: #{all_face_data.length} (#{top_faces.length} top-level, #{all_face_data.length - top_faces.length} nested)"
      puts "  Using: #{top_faces.empty? ? 'ALL (recursed — no top-level faces)' : "#{face_data.length} TOP-LEVEL faces"}"
      puts "───────────────────────────────────────────────"

      m = Sketchup.active_model
      return unless m

      # Create debug materials
      mat_measured = m.materials['FF_DEBUG_MEASURED'] || m.materials.add('FF_DEBUG_MEASURED')
      mat_measured.color = Sketchup::Color.new(0, 200, 0, 180)
      mat_excluded = m.materials['FF_DEBUG_EXCLUDED'] || m.materials.add('FF_DEBUG_EXCLUDED')
      mat_excluded.color = Sketchup::Color.new(200, 0, 0, 120)

      # ── Classify faces using the SAME logic as face_area_for_entity ──
      measured_fd = []
      excluded_fd = []

      # Group by world-space normal
      normal_groups = {}
      face_data.each do |fd|
        wn = fd[:xform] * fd[:face].normal
        key = "#{wn.x.round(1)},#{wn.y.round(1)},#{wn.z.round(1)}"
        normal_groups[key] ||= { wn: wn, fds: [] }
        normal_groups[key][:fds] << fd
      end

      sampled = load_sampled_normal(cat)
      if sampled
        puts "  Mode: SAMPLED NORMAL"
        normal_groups.each do |_nkey, grp|
          wn = grp[:wn]
          wn_n = wn.length > 0.001 ? Geom::Vector3d.new(wn.x, wn.y, wn.z).normalize : wn
          angle = sampled.angle_between(wn_n)
          if angle < NORMAL_TOLERANCE_RAD
            fds = grp[:fds]
            if fds.length == 1
              measured_fd << fds[0]
            else
              planes = {}
              fds.each do |fd|
                wp = fd[:xform] * fd[:face].vertices.first.position
                d = wn.x * wp.x + wn.y * wp.y + wn.z * wp.z
                d_key = d.round(0)
                planes[d_key] ||= []
                planes[d_key] << fd
              end
              best_key = planes.max_by { |_k, pf| pf.sum { |fd| world_face_area(fd[:face], fd[:xform]) } }&.first
              planes.each do |pk, pf|
                pf.each { |fd| pk == best_key ? measured_fd << fd : excluded_fd << fd }
              end
            end
          else
            grp[:fds].each { |fd| excluded_fd << fd }
          end
        end
      else
        puts "  Mode: DOMINANT SIDE (compound-layer dedup)"
        # Dominant side with compound-layer dedup (mirrors face_area_for_entity)
        side_data = {}
        normal_groups.each do |nkey, grp|
          fds = grp[:fds]
          wn = grp[:wn]
          if fds.length == 1
            side_data[nkey] = {
              measured: fds, excluded: [],
              area: world_face_area(fds[0][:face], fds[0][:xform])
            }
          else
            planes = {}
            fds.each do |fd|
              wp = fd[:xform] * fd[:face].vertices.first.position
              d = wn.x * wp.x + wn.y * wp.y + wn.z * wp.z
              d_key = d.round(0)
              planes[d_key] ||= []
              planes[d_key] << fd
            end
            best_key = planes.max_by { |_k, pf| pf.sum { |fd| world_face_area(fd[:face], fd[:xform]) } }&.first
            m_fds = []
            e_fds = []
            planes.each do |pk, pf|
              pf.each { |fd| pk == best_key ? m_fds << fd : e_fds << fd }
            end
            side_data[nkey] = {
              measured: m_fds, excluded: e_fds,
              area: m_fds.sum { |fd| world_face_area(fd[:face], fd[:xform]) }
            }
          end
        end

        dom_key = side_data.max_by { |_k, v| v[:area] }&.first
        dom_area = side_data[dom_key] ? side_data[dom_key][:area] : 0.0

        # Prefer top-facing surface for horizontal elements
        top_key = nil
        top_area = 0.0
        normal_groups.each do |nkey, grp|
          wn = grp[:wn]
          wn_len = Math.sqrt(wn.x**2 + wn.y**2 + wn.z**2)
          next if wn_len < 0.001
          z_up = wn.z / wn_len
          if z_up > 0.5 && side_data[nkey] && side_data[nkey][:area] > top_area
            top_key = nkey
            top_area = side_data[nkey][:area]
          end
        end

        pick_key = dom_key
        if top_key && top_key != dom_key && top_area >= dom_area * 0.7
          pick_key = top_key
          puts "  ↑ TOP SURFACE preferred (#{(top_area/144.0).round(2)} SF vs dominant #{(dom_area/144.0).round(2)} SF)"
        end

        side_data.each do |nkey, v|
          sf = v[:area] / 144.0
          is_pick = nkey == pick_key
          puts "    Normal #{nkey}: #{v[:measured].length} faces, #{sf.round(2)} SF #{is_pick ? '← MEASURED' : '(excluded)'}"
          if is_pick
            measured_fd.concat(v[:measured])
            excluded_fd.concat(v[:excluded])
          else
            excluded_fd.concat(v[:measured])
            excluded_fd.concat(v[:excluded])
          end
        end
      end

      total_measured_sf = measured_fd.sum { |fd| world_face_area(fd[:face], fd[:xform]) } / 144.0
      total_excluded_sf = excluded_fd.sum { |fd| world_face_area(fd[:face], fd[:xform]) } / 144.0
      local_sf = measured_fd.sum { |fd| fd[:face].area } / 144.0

      puts "───────────────────────────────────────────────"
      puts "  Measured: #{measured_fd.length} faces = #{total_measured_sf.round(2)} SF (world)"
      puts "  Excluded: #{excluded_fd.length} faces = #{total_excluded_sf.round(2)} SF (world)"
      puts "  Local (no transform): #{local_sf.round(2)} SF"
      puts "  Stored area_sf: #{match ? match[:area_sf] : 'N/A'}"
      puts "═══════════════════════════════════════════════"
      puts ""

      # Paint the faces (save originals first)
      m.start_operation('Debug Area', true)
      measured_fd.each { |fd| debug_paint(fd[:face], mat_measured) }
      excluded_fd.each { |fd| debug_paint(fd[:face], mat_excluded) }
      m.commit_operation

      # Zoom to entity
      begin
        bb = Geom::BoundingBox.new
        bb.add(e.bounds)
        m.active_view.zoom(bb) unless bb.empty?
      rescue; end

      puts "[FF Debug Area] Green = measured, Red = excluded. Run Scanner.clear_debug to restore."
    end

    def self.clear_debug
      count = debug_restore_all
      m = Sketchup.active_model
      if m
        m.start_operation('Clear Debug Mats', true)
        %w[FF_DEBUG_MEASURED FF_DEBUG_EXCLUDED FF_DEBUG_OPEN FF_DEBUG_PARTIAL FF_DEBUG_BLOCKED FF_DEBUG_LF_SIDE FF_DEBUG_LF_ENDCAP FF_DEBUG_LF_BBOX].each do |name|
          m.materials.remove(m.materials[name]) if m.materials[name]
        end
        m.commit_operation
      end
      puts "[FF Debug] Restored #{count} faces, debug materials cleared"
    end

    # ═══════════════════════════════════════════════════════════
    # debug_lf_category — Debug all LF entities in a category
    #
    # Three methods based on category type:
    #   Beams:      longest edge = length. Blue endcaps, green sides.
    #               Console shows WxHxL x qty inventory.
    #   Walls:      longest horizontal edge. Green verticals, blue caps.
    #   Extrusions: side_area / perimeter. Blue endcaps, green sides.
    #   Fallback:   orange = bounding box (no geometry detection).
    # ═══════════════════════════════════════════════════════════

    def self.debug_lf_category(category)
      sr = TakeoffTool.filtered_scan_results
      ca = TakeoffTool.category_assignments
      return unless sr

      # Find all entities in this category with LF values
      # (Don't filter by measurement_type — the user clicked an LF measurement,
      # so we show all entities in this category that have linear_ft data)
      entries = sr.select do |r|
        assigned = ca[r[:entity_id]]
        cat = assigned || r[:parsed][:auto_category]
        cat == category && r[:linear_ft] && r[:linear_ft] > 0
      end

      # IFC compound layer dedup
      if (IFCParser.ifc_model?(Sketchup.active_model) rescue false)
        ifc_preferred = {}
        sr.each do |r2|
          next if r2[:source] == :manual_lf || r2[:source] == :manual_sf || r2[:source] == :manual_box
          dname = r2[:definition_name] || r2[:display_name] || ''
          next if dname.empty?
          eid2 = r2[:entity_id]
          has_ca = !!ca[eid2]
          prev = ifc_preferred[dname]
          if prev.nil? || (has_ca && !prev[:assigned])
            ifc_preferred[dname] = { eid: eid2, assigned: has_ca }
          end
        end
        entries = entries.select do |r|
          dname = r[:definition_name] || r[:display_name] || ''
          pref = ifc_preferred[dname]
          !pref || pref[:eid] == r[:entity_id]
        end
      end

      if entries.empty?
        puts "[FF Debug LF] No LF entities found in '#{category}'"
        return
      end

      m = Sketchup.active_model
      return unless m

      # Determine category method
      is_beam = category =~ BEAM_RE
      is_wall = category =~ WALL_LF_RE

      # Create debug materials
      mat_side = m.materials['FF_DEBUG_LF_SIDE'] || m.materials.add('FF_DEBUG_LF_SIDE')
      mat_side.color = Sketchup::Color.new(0, 200, 0, 180)       # Green = side faces / wall verticals
      mat_endcap = m.materials['FF_DEBUG_LF_ENDCAP'] || m.materials.add('FF_DEBUG_LF_ENDCAP')
      mat_endcap.color = Sketchup::Color.new(0, 150, 255, 180)   # Blue = end caps / wall top-bottom
      mat_bbox = m.materials['FF_DEBUG_LF_BBOX'] || m.materials.add('FF_DEBUG_LF_BBOX')
      mat_bbox.color = Sketchup::Color.new(255, 165, 0, 160)     # Orange = bounding box fallback

      method_label = is_beam ? 'BEAM (longest edge)' : is_wall ? 'WALL (longest horiz edge)' : 'EXTRUSION'
      puts ""
      puts "═══════════════════════════════════════════════════════════"
      puts "[FF Debug LF] Category: '#{category}' — #{entries.length} entities"
      puts "[FF Debug LF] Method: #{method_label}"
      puts "═══════════════════════════════════════════════════════════"

      grand_lf = 0.0
      grand_stored = 0.0
      # For beam inventory: group by definition → { lengths: [lf, lf, ...], section: "WxH", method: str }
      beam_inventory = {}

      m.start_operation('Debug LF Category', true)

      entries.each do |r|
        eid = r[:entity_id]
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?

        defn = e.respond_to?(:definition) ? e.definition : nil
        next unless defn

        xform = e.transformation
        dname = r[:display_name] || defn.name
        acat = r[:parsed][:auto_category] || category
        stored_lf = r[:linear_ft] || 0

        computed_lf = nil
        method_used = nil

        # ── BEAM: longest edge ──────────────────────────────────
        if is_beam
          edge_data = []
          collect_edges_for_beam(defn.entities, xform, edge_data)

          if edge_data.any?
            best = edge_data.max_by { |ed| ed[:length] }
            if best && best[:length] > 0.5
              computed_lf = best[:length] / 12.0
              method_used = 'beam'

              # Beam axis = direction of longest edge
              axis = Geom::Vector3d.new(
                best[:p2].x - best[:p1].x,
                best[:p2].y - best[:p1].y,
                best[:p2].z - best[:p1].z
              )
              axis_len = axis.length
              axis = axis.normalize if axis_len > 0.001

              # Paint faces: endcap (normal ∥ axis) = blue, side (normal ⊥ axis) = green
              face_data = []
              collect_faces_for_lf_debug(defn.entities, xform, face_data)
              side_count = 0
              cap_count = 0
              face_data.each do |fd|
                wn = fd[:face].normal.transform(xform)
                wn_len = Math.sqrt(wn.x**2 + wn.y**2 + wn.z**2)
                next if wn_len < 0.001
                wn_n = Geom::Vector3d.new(wn.x / wn_len, wn.y / wn_len, wn.z / wn_len)
                dot = (axis.x * wn_n.x + axis.y * wn_n.y + axis.z * wn_n.z).abs
                if dot > 0.7
                  debug_paint(fd[:face], mat_endcap)  # endcap
                  cap_count += 1
                else
                  debug_paint(fd[:face], mat_side)    # side
                  side_count += 1
                end
              end

              # Cross-section from BB (two shorter dims)
              dims = [r[:bb_width_in] || 0, r[:bb_height_in] || 0, r[:bb_depth_in] || 0].sort
              section = "#{dims[0].round(1)}x#{dims[1].round(1)}"

              # Build inventory
              beam_inventory[dname] ||= { lengths: [], section: section }
              beam_inventory[dname][:lengths] << computed_lf

              puts "  #{dname}: #{computed_lf.round(2)}' (beam, #{side_count} side + #{cap_count} endcap faces)"
            end
          end
        end

        # ── WALL: longest horizontal edge ───────────────────────
        if computed_lf.nil? && (is_wall || acat =~ WALL_LF_RE)
          computed_lf = wall_linear_ft(defn, xform)
          if computed_lf
            method_used = 'wall'

            # Paint faces by orientation
            wall_faces = []
            collect_faces_for_lf_debug(defn.entities, xform, wall_faces)
            vert_count = 0
            horiz_count = 0
            wall_faces.each do |fd|
              wn = fd[:face].normal.transform(xform)
              wn_len = Math.sqrt(wn.x**2 + wn.y**2 + wn.z**2)
              z_ratio = wn_len > 0.001 ? wn.z.abs / wn_len : 0
              if z_ratio > 0.7
                debug_paint(fd[:face], mat_endcap)
                horiz_count += 1
              else
                debug_paint(fd[:face], mat_side)
                vert_count += 1
              end
            end

            puts "  #{dname}: #{computed_lf.round(2)}' (wall, #{vert_count} vert + #{horiz_count} horiz faces)"
          end
        end

        # ── EXTRUSION: side_area / perimeter ────────────────────
        if computed_lf.nil?
          face_data = []
          collect_faces_for_lf_debug(defn.entities, xform, face_data)
          face_data.reject! { |fd| fd[:area] < 0.1 }

          if face_data.length >= 3
            face_data.sort_by! { |fd| fd[:area] }
            total_area = face_data.sum { |fd| fd[:area] }
            ef1 = face_data[0]
            ef2 = nil
            (1...[face_data.length, 8].min).each do |i|
              candidate = face_data[i]
              ratio = candidate[:area] / [ef1[:area], 0.01].max
              combined = ef1[:area] + candidate[:area]
              if ratio < 2.0 && combined < total_area * 0.20
                ef2 = candidate
                break
              end
            end

            if ef2 && ef1[:perimeter] >= 0.5
              side_area = total_area - ef1[:area] - ef2[:area]
              if side_area >= 1.0
                computed_lf = (side_area / ef1[:perimeter]) / 12.0
                method_used = 'extrusion'
                endcap_faces = [ef1[:face], ef2[:face]]
                face_data.each do |fd|
                  if endcap_faces.include?(fd[:face])
                    debug_paint(fd[:face], mat_endcap)
                  else
                    debug_paint(fd[:face], mat_side)
                  end
                end
                puts "  #{dname}: #{computed_lf.round(2)}' (extrusion, side=#{(side_area/144.0).round(1)} SF / perim=#{(ef1[:perimeter]/12.0).round(2)}')"
              end
            end
          end
        end

        # ── FALLBACK: bounding box ──────────────────────────────
        if computed_lf.nil?
          longest_in = [r[:bb_width_in] || 0, r[:bb_height_in] || 0, r[:bb_depth_in] || 0].max
          computed_lf = longest_in / 12.0
          method_used = 'bbox'
          debug_paint_entity(e, mat_bbox)
          dims = [r[:bb_width_in] || 0, r[:bb_height_in] || 0, r[:bb_depth_in] || 0].sort
          puts "  #{dname}: #{computed_lf.round(2)}' (BBOX FALLBACK — orange) #{dims[0].round(1)}x#{dims[1].round(1)}x#{dims[2].round(1)}\""
        end

        grand_lf += computed_lf
        grand_stored += stored_lf
      end

      m.commit_operation

      # ── Beam inventory: WxH x L' x qty ──────────────────────
      if is_beam && beam_inventory.any?
        puts ""
        puts "── Beam Inventory ──────────────────────────────────────"
        beam_inventory.sort_by { |_dn, v| -v[:lengths].sum }.each do |dn, v|
          label = dn.length > 60 ? dn[0..57] + '...' : dn
          puts "  #{label}"
          puts "    Section: #{v[:section]}\""

          # Group lengths (round to nearest 3")
          len_groups = {}
          v[:lengths].each do |l|
            rounded = (l * 4).round / 4.0  # round to 0.25 ft (3")
            len_groups[rounded] ||= 0
            len_groups[rounded] += 1
          end
          len_groups.sort_by { |l, _c| -l }.each do |len, qty|
            puts "    #{v[:section]}\" x #{len.round(2)}' x #{qty} = #{(len * qty).round(1)} LF"
          end
          puts "    Subtotal: #{v[:lengths].sum.round(1)} LF (#{v[:lengths].length} members)"
        end
      end

      # ── Summary ──────────────────────────────────────────────
      puts ""
      puts "═══════════════════════════════════════════════════════════"
      puts "  TOTAL COMPUTED:  #{grand_lf.round(1)} LF"
      puts "  TOTAL STORED:    #{grand_stored.round(1)} LF"
      puts "  Entity count:    #{entries.length}"
      puts "═══════════════════════════════════════════════════════════"
      puts ""
      puts "[FF Debug LF] Color legend:"
      puts "  Green  = side faces / vertical wall surfaces"
      puts "  Blue   = end caps (beam profile) / top-bottom wall caps"
      puts "  Orange = bounding box fallback (no geometry detection)"
      puts "[FF Debug LF] Run Scanner.clear_debug to restore."
    end

    # ═══════════════════════════════════════════════════════════
    # debug_area_category — Debug all SF entities in a category
    #
    # Paints all measured faces green, excluded red across every
    # entity in the category. Logs per-entity and summary totals.
    # ═══════════════════════════════════════════════════════════

    def self.debug_area_category(category)
      sr = TakeoffTool.filtered_scan_results
      ca = TakeoffTool.category_assignments
      return unless sr

      # Find all entities in this category with SF area
      entries = sr.select do |r|
        assigned = ca[r[:entity_id]]
        cat = assigned || r[:parsed][:auto_category]
        cat == category && r[:area_sf] && r[:area_sf] > 0
      end

      # IFC compound layer dedup: two-pass — prefer explicitly assigned instances
      if (IFCParser.ifc_model?(Sketchup.active_model) rescue false)
        ifc_preferred = {}
        sr.each do |r2|
          next if r2[:source] == :manual_lf || r2[:source] == :manual_sf || r2[:source] == :manual_box
          dname = r2[:definition_name] || r2[:display_name] || ''
          next if dname.empty?
          eid2 = r2[:entity_id]
          has_ca = !!ca[eid2]
          prev = ifc_preferred[dname]
          if prev.nil? || (has_ca && !prev[:assigned])
            ifc_preferred[dname] = { eid: eid2, assigned: has_ca }
          end
        end
        entries = entries.select do |r|
          dname = r[:definition_name] || r[:display_name] || ''
          pref = ifc_preferred[dname]
          !pref || pref[:eid] == r[:entity_id]
        end
      end

      if entries.empty?
        all_cats = sr.map { |r| ca[r[:entity_id]] || r[:parsed][:auto_category] }.compact.uniq.sort
        cat_count = sr.count { |r| (ca[r[:entity_id]] || r[:parsed][:auto_category]) == category }
        puts "[FF Debug Area] No SF entities found in '#{category}'"
        puts "  Entities in this category: #{cat_count}"
        if cat_count == 0
          close = all_cats.select { |c| c.downcase.include?(category.downcase) }
          puts "  Similar categories: #{close.any? ? close.join(', ') : 'none'}"
          puts "  All categories: #{all_cats.join(', ')}"
        else
          with_sf = sr.count { |r| (ca[r[:entity_id]] || r[:parsed][:auto_category]) == category && r[:area_sf] }
          puts "  With area_sf set: #{with_sf}"
        end
        return
      end

      m = Sketchup.active_model
      return unless m

      # Create debug materials
      mat_measured = m.materials['FF_DEBUG_MEASURED'] || m.materials.add('FF_DEBUG_MEASURED')
      mat_measured.color = Sketchup::Color.new(0, 200, 0, 180)
      mat_excluded = m.materials['FF_DEBUG_EXCLUDED'] || m.materials.add('FF_DEBUG_EXCLUDED')
      mat_excluded.color = Sketchup::Color.new(200, 0, 0, 120)

      puts ""
      puts "═══════════════════════════════════════════════════════════"
      puts "[FF Debug Area] Category: '#{category}' — #{entries.length} entities with SF"
      puts "═══════════════════════════════════════════════════════════"

      grand_measured = 0.0
      grand_excluded = 0.0
      grand_stored = 0.0
      all_measured_faces = []
      all_excluded_faces = []
      by_defn = {}  # group by definition name for summary

      m.start_operation('Debug Area Category', true)

      entries.each do |r|
        eid = r[:entity_id]
        e = TakeoffTool.find_entity(eid)
        next unless e && e.valid?

        defn = e.respond_to?(:definition) ? e.definition : nil
        next unless defn

        xform = e.transformation
        dname = r[:display_name] || defn.name

        # ── Collect faces using the SAME strategy as face_area_for_entity ──
        # Top-level faces first; only recurse if no direct faces exist
        top_faces = defn.entities.grep(Sketchup::Face)
        if top_faces.empty?
          fd_list = []
          collect_faces_for_sf(defn.entities, xform, fd_list)
        else
          fd_list = top_faces.map { |f| { face: f, xform: xform } }
        end
        next if fd_list.empty?

        measured_fd = []
        excluded_fd = []

        # ── Group faces by world-space normal (mirrors face_area_for_entity) ──
        normal_groups = {}
        fd_list.each do |fd|
          wn = fd[:xform] * fd[:face].normal
          key = "#{wn.x.round(1)},#{wn.y.round(1)},#{wn.z.round(1)}"
          normal_groups[key] ||= { wn: wn, fds: [] }
          normal_groups[key][:fds] << fd
        end

        # ── Sampled normal override (mirrors face_area_for_entity) ──
        sampled = load_sampled_normal(category)
        if sampled
          normal_groups.each do |_nkey, grp|
            wn = grp[:wn]
            wn_n = wn.length > 0.001 ? Geom::Vector3d.new(wn.x, wn.y, wn.z).normalize : wn
            angle = sampled.angle_between(wn_n)
            if angle < NORMAL_TOLERANCE_RAD
              fds = grp[:fds]
              if fds.length == 1
                measured_fd << fds[0]
              else
                # Compound layer dedup: group by plane distance, keep largest plane
                planes = {}
                fds.each do |fd|
                  wp = fd[:xform] * fd[:face].vertices.first.position
                  d = wn.x * wp.x + wn.y * wp.y + wn.z * wp.z
                  d_key = d.round(0)
                  planes[d_key] ||= []
                  planes[d_key] << fd
                end
                best_key = planes.max_by { |_k, pf| pf.sum { |fd| world_face_area(fd[:face], fd[:xform]) } }&.first
                planes.each do |pk, pf|
                  pf.each { |fd| pk == best_key ? measured_fd << fd : excluded_fd << fd }
                end
              end
            else
              grp[:fds].each { |fd| excluded_fd << fd }
            end
          end
        else
          # ── Default: dominant side with compound-layer dedup ──
          # For each normal group, sub-group by plane distance, keep largest plane.
          # Then pick the normal group with the largest deduped area.
          side_data = {}
          normal_groups.each do |nkey, grp|
            fds = grp[:fds]
            wn = grp[:wn]
            if fds.length == 1
              side_data[nkey] = {
                measured: fds,
                excluded: [],
                area: world_face_area(fds[0][:face], fds[0][:xform])
              }
            else
              planes = {}
              fds.each do |fd|
                wp = fd[:xform] * fd[:face].vertices.first.position
                d = wn.x * wp.x + wn.y * wp.y + wn.z * wp.z
                d_key = d.round(0)
                planes[d_key] ||= []
                planes[d_key] << fd
              end
              best_key = planes.max_by { |_k, pf| pf.sum { |fd| world_face_area(fd[:face], fd[:xform]) } }&.first
              m_fds = []
              e_fds = []
              planes.each do |pk, pf|
                pf.each { |fd| pk == best_key ? m_fds << fd : e_fds << fd }
              end
              side_data[nkey] = {
                measured: m_fds,
                excluded: e_fds,
                area: m_fds.sum { |fd| world_face_area(fd[:face], fd[:xform]) }
              }
            end
          end

          dom_key = side_data.max_by { |_k, v| v[:area] }&.first
          dom_area = side_data[dom_key] ? side_data[dom_key][:area] : 0.0

          # Prefer top-facing surface for horizontal elements
          top_key = nil
          top_area = 0.0
          normal_groups.each do |nkey, grp|
            wn = grp[:wn]
            wn_len = Math.sqrt(wn.x**2 + wn.y**2 + wn.z**2)
            next if wn_len < 0.001
            z_up = wn.z / wn_len
            if z_up > 0.5 && side_data[nkey] && side_data[nkey][:area] > top_area
              top_key = nkey
              top_area = side_data[nkey][:area]
            end
          end

          pick_key = dom_key
          if top_key && top_key != dom_key && top_area >= dom_area * 0.7
            pick_key = top_key
          end

          side_data.each do |nkey, v|
            if nkey == pick_key
              measured_fd.concat(v[:measured])
              excluded_fd.concat(v[:excluded])
            else
              excluded_fd.concat(v[:measured])
              excluded_fd.concat(v[:excluded])
            end
          end
        end

        entity_sf = measured_fd.sum { |fd| world_face_area(fd[:face], fd[:xform]) } / 144.0
        excl_sf = excluded_fd.sum { |fd| world_face_area(fd[:face], fd[:xform]) } / 144.0
        stored_sf = r[:area_sf] || 0

        grand_measured += entity_sf
        grand_excluded += excl_sf
        grand_stored += stored_sf

        # Group by definition name
        by_defn[dname] ||= { count: 0, sf: 0.0, stored: 0.0 }
        by_defn[dname][:count] += 1
        by_defn[dname][:sf] += entity_sf
        by_defn[dname][:stored] += stored_sf

        # Paint faces (save originals first)
        measured_fd.each { |fd| debug_paint(fd[:face], mat_measured) }
        excluded_fd.each { |fd| debug_paint(fd[:face], mat_excluded) }

        all_measured_faces.concat(measured_fd.map { |fd| fd[:face] })
        all_excluded_faces.concat(excluded_fd.map { |fd| fd[:face] })
      end

      m.commit_operation

      # Per-definition summary (sorted by total SF descending)
      puts ""
      puts "  %-60s %5s %10s %10s" % ['Definition', 'Count', 'Measured', 'Stored']
      puts "  " + "─" * 87
      by_defn.sort_by { |_k, v| -v[:sf] }.each do |dname, v|
        label = dname.length > 58 ? dname[0..55] + '...' : dname
        puts "  %-60s %5d %9.1f %9.1f" % [label, v[:count], v[:sf], v[:stored]]
      end

      puts ""
      puts "═══════════════════════════════════════════════════════════"
      puts "  TOTAL MEASURED:  #{grand_measured.round(1)} SF (#{all_measured_faces.length} faces)"
      puts "  TOTAL EXCLUDED:  #{grand_excluded.round(1)} SF (#{all_excluded_faces.length} faces)"
      puts "  TOTAL STORED:    #{grand_stored.round(1)} SF"
      puts "  Entity count:    #{entries.length}"
      puts "═══════════════════════════════════════════════════════════"
      puts ""
      puts "[FF Debug Area] Green = measured, Red = excluded. Run Scanner.clear_debug to restore."
    end

    # ═══════════════════════════════════════════════════════════
    # debug_occlusion — Raycast occlusion analysis for SF category
    #
    # For each measured face, raycasts outward from sample points to
    # detect blocking objects (cabinets, other finishes, framing).
    # Green = exposed, Yellow = partially blocked, Red = fully blocked.
    # ═══════════════════════════════════════════════════════════

    DEBUG_OCC_SAMPLES = 6     # ray sample points per face
    DEBUG_OCC_OFFSET  = 0.5   # inches offset from surface to avoid self-hit
    DEBUG_OCC_MIN     = 2.0   # inches min distance (ignore very close self-geometry)

    # Categories/tags to ignore as blockers (rooms, volumes, levels)
    OCC_IGNORE_RE = /room|volume|level|datum|space|zone|story|storey/i

    # Wall assembly / structural categories to ignore as blockers.
    # These are expected behind drywall, not true occlusion.
    OCC_ASSEMBLY_RE = /wall\s*framing|ceiling\s*framing|roof\s*framing|floor\s*framing|
      truss|sheathing|siding|soffit|fascia|drywall|gyp|
      window|door|opening|curtain\s*wall|
      footing|foundation|slab|masonry|veneer|
      framing|stud|joist|rafter|beam|header|
      insulation|vapor\s*barrier|membrane|flashing/ix

    def self.debug_occlusion(category, threshold_in = 18.0)
      sr = TakeoffTool.filtered_scan_results
      ca = TakeoffTool.category_assignments
      return unless sr

      entries = sr.select do |r|
        assigned = ca[r[:entity_id]]
        cat = assigned || r[:parsed][:auto_category]
        cat == category && r[:area_sf] && r[:area_sf] > 0
      end

      # IFC compound layer dedup: two-pass — prefer explicitly assigned instances
      if (IFCParser.ifc_model?(Sketchup.active_model) rescue false)
        ifc_preferred = {}
        sr.each do |r2|
          next if r2[:source] == :manual_lf || r2[:source] == :manual_sf || r2[:source] == :manual_box
          dname = r2[:definition_name] || r2[:display_name] || ''
          next if dname.empty?
          eid2 = r2[:entity_id]
          has_ca = !!ca[eid2]
          prev = ifc_preferred[dname]
          if prev.nil? || (has_ca && !prev[:assigned])
            ifc_preferred[dname] = { eid: eid2, assigned: has_ca }
          end
        end
        entries = entries.select do |r|
          dname = r[:definition_name] || r[:display_name] || ''
          pref = ifc_preferred[dname]
          !pref || pref[:eid] == r[:entity_id]
        end
      end

      if entries.empty?
        # Diagnostic: check if category exists at all
        all_cats = sr.map { |r| ca[r[:entity_id]] || r[:parsed][:auto_category] }.compact.uniq.sort
        cat_count = sr.count { |r| (ca[r[:entity_id]] || r[:parsed][:auto_category]) == category }
        puts "[FF Occlusion] No SF entities found in '#{category}'"
        puts "  Entities in this category: #{cat_count}"
        if cat_count == 0
          close = all_cats.select { |c| c.downcase.include?(category.downcase) }
          puts "  Similar categories: #{close.any? ? close.join(', ') : 'none'}"
          puts "  All categories: #{all_cats.join(', ')}"
        else
          with_sf = sr.count { |r| (ca[r[:entity_id]] || r[:parsed][:auto_category]) == category && r[:area_sf] }
          puts "  With area_sf set: #{with_sf}"
        end
        return
      end

      m = Sketchup.active_model
      return unless m

      occ_results = []

      # Build blocker lookup: entityID → "Category: DisplayName"
      blocker_lookup = {}
      sr.each do |r|
        bcat = ca[r[:entity_id]] || r[:parsed][:auto_category] || '?'
        bdn = r[:display_name] || r[:definition_name] || ''
        # Shorten long Revit GUIDs to something readable
        if bdn.length > 36 && bdn.include?('-')
          bdn = r[:parsed][:element_type] || r[:parsed][:function] || bdn[0..20] + '...'
        end
        blocker_lookup[r[:entity_id]] = "#{bcat}: #{bdn}"
      end

      # Debug materials
      mat_open = m.materials['FF_DEBUG_OPEN'] || m.materials.add('FF_DEBUG_OPEN')
      mat_open.color = Sketchup::Color.new(0, 200, 0, 180)
      mat_partial = m.materials['FF_DEBUG_PARTIAL'] || m.materials.add('FF_DEBUG_PARTIAL')
      mat_partial.color = Sketchup::Color.new(240, 200, 0, 180)
      mat_blocked = m.materials['FF_DEBUG_BLOCKED'] || m.materials.add('FF_DEBUG_BLOCKED')
      mat_blocked.color = Sketchup::Color.new(200, 0, 0, 180)

      puts ""
      puts "═══════════════════════════════════════════════════════════"
      puts "[FF Occlusion] Category: '#{category}' — #{entries.length} entities"
      puts "  Threshold: #{threshold_in}\" (#{(threshold_in / 12.0).round(1)} ft)"
      puts "═══════════════════════════════════════════════════════════"

      open_sf = 0.0; partial_sf = 0.0; blocked_sf = 0.0
      open_count = 0; partial_count = 0; blocked_count = 0
      blocker_tally = {}

      m.start_operation('Debug Occlusion', true)

      entries.each_with_index do |r, ei|
        e = TakeoffTool.find_entity(r[:entity_id])
        next unless e && e.valid?
        defn = e.respond_to?(:definition) ? e.definition : nil
        next unless defn

        xform = e.transformation
        faces = defn.entities.grep(Sketchup::Face)
        next if faces.empty?

        # Find the measured face(s) — same logic as face_area_for_entity
        measured = []
        if category =~ SHEET_GOOD_RE
          groups = {}
          faces.each do |f|
            n = f.normal
            key = "#{n.x.round(1)},#{n.y.round(1)},#{n.z.round(1)}"
            groups[key] ||= { faces: [], area: 0.0 }
            groups[key][:faces] << f
            groups[key][:area] += world_face_area(f, xform)
          end
          dom_key = groups.max_by { |_k, v| v[:area] }&.first
          measured = dom_key ? groups[dom_key][:faces] : []
        elsif enclosed_3d?(faces)
          largest = faces.max_by { |f| world_face_area(f, xform) }
          measured = [largest] if largest
        else
          measured = faces
        end
        next if measured.empty?

        # For each measured face, raycast to check occlusion
        face_hits = 0
        face_total = 0

        measured.each do |face|
          # Get the face normal in world space
          normal_world = xform * face.normal
          # Normalize in case of scaling
          normal_world = normal_world.normalize rescue face.normal

          # Sample points on the face via mesh triangles
          samples = face_sample_points(face, xform, DEBUG_OCC_SAMPLES)
          next if samples.empty?

          # Determine room-side direction:
          # Raycast both ways from first sample. The direction that either
          # hits nothing or hits farther away is the "room side."
          test_pt = samples.first
          room_dir = normal_world

          pt_fwd = Geom::Point3d.new(
            test_pt.x + normal_world.x * DEBUG_OCC_OFFSET,
            test_pt.y + normal_world.y * DEBUG_OCC_OFFSET,
            test_pt.z + normal_world.z * DEBUG_OCC_OFFSET
          )
          rev = Geom::Vector3d.new(-normal_world.x, -normal_world.y, -normal_world.z)
          pt_rev = Geom::Point3d.new(
            test_pt.x + rev.x * DEBUG_OCC_OFFSET,
            test_pt.y + rev.y * DEBUG_OCC_OFFSET,
            test_pt.z + rev.z * DEBUG_OCC_OFFSET
          )

          hit_fwd = m.raytest([pt_fwd, normal_world])
          hit_rev = m.raytest([pt_rev, rev])
          dist_fwd = hit_fwd ? pt_fwd.distance(hit_fwd[0]) : 99999
          dist_rev = hit_rev ? pt_rev.distance(hit_rev[0]) : 99999

          # Closer hit = wall cavity side. Farther hit (or none) = room side.
          if dist_rev < dist_fwd && dist_rev < 6.0
            room_dir = normal_world
          elsif dist_fwd < dist_rev && dist_fwd < 6.0
            room_dir = rev
          end
          # If neither is very close, keep normal_world as room direction

          # Raycast from each sample along room direction
          samples.each do |pt|
            ray_origin = Geom::Point3d.new(
              pt.x + room_dir.x * DEBUG_OCC_OFFSET,
              pt.y + room_dir.y * DEBUG_OCC_OFFSET,
              pt.z + room_dir.z * DEBUG_OCC_OFFSET
            )

            result = m.raytest([ray_origin, room_dir])
            face_total += 1

            if result
              hit_pt = result[0]
              dist = ray_origin.distance(hit_pt)
              if dist > DEBUG_OCC_MIN && dist <= threshold_in
                hit_path = result[1]
                # Walk path to find the containing ComponentInstance/Group
                # hit_path is [CI, CI, ..., Face] — we want the deepest CI/Group
                hit_inst = nil
                if hit_path.is_a?(Array)
                  hit_path.reverse_each do |pe|
                    if pe.is_a?(Sketchup::ComponentInstance) || pe.is_a?(Sketchup::Group)
                      hit_inst = pe
                      break
                    end
                  end
                end

                # Self-hit: same entity or same definition
                is_self = false
                if hit_inst
                  is_self = (hit_inst == e) ||
                            (hit_inst.respond_to?(:definition) && hit_inst.definition == defn)
                else
                  # Hit loose geometry — check if it's inside our own definition
                  is_self = true  # loose faces near our entity are likely self
                end

                # Filter: rooms/volumes + wall assembly/structural
                is_skip = false
                if hit_inst
                  hit_eid = hit_inst.respond_to?(:entityID) ? hit_inst.entityID : 0
                  hit_cat = blocker_lookup[hit_eid]&.split(':')&.first&.strip || ''
                  hit_tag = hit_inst.respond_to?(:layer) ? hit_inst.layer.name : ''
                  hit_def = hit_inst.respond_to?(:definition) ? hit_inst.definition.name : ''
                  is_skip = (hit_cat =~ OCC_IGNORE_RE) ||
                            (hit_cat =~ OCC_ASSEMBLY_RE) ||
                            (hit_tag =~ OCC_IGNORE_RE) ||
                            (hit_tag =~ OCC_ASSEMBLY_RE) ||
                            (hit_def =~ OCC_IGNORE_RE)
                end

                unless is_self || is_skip
                  face_hits += 1
                  # Identify the blocker by category + display name
                  hit_eid = hit_inst.respond_to?(:entityID) ? hit_inst.entityID : 0
                  bname = blocker_lookup[hit_eid]
                  unless bname
                    # Not in scan results — use tag + definition name
                    btag = hit_inst.respond_to?(:layer) ? hit_inst.layer.name : '?'
                    bdef = hit_inst.respond_to?(:definition) ? hit_inst.definition.name : '?'
                    bdef = bdef[0..20] + '...' if bdef.length > 24
                    bname = "#{btag}: #{bdef}"
                  end
                  blocker_tally[bname] = (blocker_tally[bname] || 0) + 1
                end
              end
            end
          end
        end

        # Classify this entity
        ratio = face_total > 0 ? face_hits.to_f / face_total : 0
        sf = measured.sum { |f| world_face_area(f, xform) } / 144.0
        dname = r[:display_name] || defn.name
        dname = dname[0..35] + '...' if dname.length > 38

        status = ratio >= 0.6 ? 'blocked' : ratio >= 0.2 ? 'partial' : 'open'
        occ_results << { eid: r[:entity_id], name: dname, sf: sf.round(1), status: status, included: (status != 'blocked') }

        if status == 'blocked'
          debug_paint_entity(e, mat_blocked)
          blocked_sf += sf; blocked_count += 1
        elsif status == 'partial'
          debug_paint_entity(e, mat_partial)
          partial_sf += sf; partial_count += 1
        else
          debug_paint_entity(e, mat_open)
          open_sf += sf; open_count += 1
        end

        # Progress every 50 entities
        if (ei + 1) % 50 == 0
          puts "  ... processed #{ei + 1}/#{entries.length} entities"
        end
      end

      m.commit_operation

      total_sf = open_sf + partial_sf + blocked_sf
      puts ""
      puts "───────────────────────────────────────────────"
      puts "  GREEN  (open):    #{open_count} entities, #{open_sf.round(1)} SF"
      puts "  YELLOW (partial): #{partial_count} entities, #{partial_sf.round(1)} SF"
      puts "  RED    (blocked): #{blocked_count} entities, #{blocked_sf.round(1)} SF"
      puts "  TOTAL:            #{entries.length} entities, #{total_sf.round(1)} SF"
      puts "───────────────────────────────────────────────"

      if blocker_tally.any?
        # Group by category (part before the colon)
        cat_hits = {}
        blocker_tally.each do |bname, count|
          bcat = bname.split(':').first.strip
          cat_hits[bcat] = (cat_hits[bcat] || 0) + count
        end

        puts ""
        puts "  Blocking categories:"
        cat_hits.sort_by { |_k, v| -v }.each do |bcat, count|
          puts "    %-40s %d hits" % [bcat, count]
        end

        puts ""
        puts "  Top individual blockers:"
        blocker_tally.sort_by { |_k, v| -v }.first(15).each do |bname, count|
          label = bname.length > 55 ? bname[0..52] + '...' : bname
          puts "    %-58s %d hits" % [label, count]
        end
      end

      puts ""
      puts "═══════════════════════════════════════════════════════════"
      puts "[FF Occlusion] Green=open, Yellow=partial, Red=blocked"
      puts "═══════════════════════════════════════════════════════════"

      # Store results and open review dialog
      @occ_results = occ_results
      @occ_category = category
      show_occ_review
    end

    # ═══════════════════════════════════════════════════════════
    # OCC Review Dialog
    # ═══════════════════════════════════════════════════════════

    @occ_dialog = nil
    @occ_results = []
    @occ_category = ''
    @occ_pick_active = false
    @occ_original_sf = {}  # eid => original area_sf, for undo

    # ── OCC Pick Tool ──────────────────────────────────────────
    # Activated from OCC Review dialog. Click an entity in the
    # viewport to highlight its row in the dialog and toggle it.
    class OccPickTool
      def activate
        Sketchup.status_text = "OCC PICK | Click entity to select in review dialog | ESC to exit"
        @hover_eid = nil
      end

      def deactivate(view)
        Scanner.instance_variable_set(:@occ_pick_active, false)
        dlg = Scanner.instance_variable_get(:@occ_dialog)
        dlg.execute_script("setPickMode(false)") if dlg && dlg.visible?
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        best = ph.best_picked
        eid = nil
        if best.is_a?(Sketchup::ComponentInstance) || best.is_a?(Sketchup::Group)
          eid = best.entityID
        elsif ph.path_at(0)
          ph.path_at(0).reverse_each do |pe|
            if pe.is_a?(Sketchup::ComponentInstance) || pe.is_a?(Sketchup::Group)
              eid = pe.entityID
              break
            end
          end
        end
        if eid != @hover_eid
          @hover_eid = eid
          Sketchup.status_text = if eid
            item = Scanner.occ_item_by_eid(eid)
            item ? "OCC PICK | #{item[:name]} (#{item[:sf]} SF) — click to toggle" : "OCC PICK | Not in OCC results"
          else
            "OCC PICK | Click entity to select in review dialog | ESC to exit"
          end
        end
        true
      end

      def onLButtonDown(_flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        eid = nil
        best = ph.best_picked
        if best.is_a?(Sketchup::ComponentInstance) || best.is_a?(Sketchup::Group)
          eid = best.entityID
        elsif ph.path_at(0)
          ph.path_at(0).reverse_each do |pe|
            if pe.is_a?(Sketchup::ComponentInstance) || pe.is_a?(Sketchup::Group)
              eid = pe.entityID
              break
            end
          end
        end
        return true unless eid
        Scanner.occ_pick_entity(eid)
        true
      end

      def onKeyDown(key, _repeat, _flags, _view)
        if key == 0x1B # ESC
          Sketchup.active_model.select_tool(nil)
          return true
        end
        false
      end

      def getMenu(menu)
        menu.add_item("Exit Pick Mode") { Sketchup.active_model.select_tool(nil) }
      end
    end

    def self.occ_item_by_eid(eid)
      @occ_results&.find { |r| r[:eid] == eid }
    end

    def self.occ_pick_entity(eid)
      item = occ_item_by_eid(eid)
      unless item
        puts "[FF OCC Pick] Entity #{eid} not in OCC results"
        return
      end

      # Toggle included
      item[:included] = !item[:included]

      # Repaint
      m = Sketchup.active_model
      if m
        e = TakeoffTool.find_entity(eid)
        if e && e.valid?
          mat_name = item[:included] ? 'FF_DEBUG_OPEN' : 'FF_DEBUG_BLOCKED'
          mat = m.materials[mat_name]
          if mat
            m.start_operation('OCC Pick Toggle', true)
            debug_paint_entity(e, mat)
            m.commit_operation
          end
        end
      end

      # Update dialog — send data + highlight the row
      send_occ_data
      if @occ_dialog && @occ_dialog.visible?
        @occ_dialog.execute_script("highlightRow(#{eid})")
      end
    end

    def self.show_occ_review
      return unless @occ_results && @occ_results.any?

      if @occ_dialog && @occ_dialog.visible?
        send_occ_data
        @occ_dialog.bring_to_front
        return
      end

      @occ_dialog = UI::HtmlDialog.new(
        dialog_title: "OCC Review — #{@occ_category}",
        preferences_key: "OCCReview",
        width: 480, height: 580,
        left: 200, top: 150,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      require 'json'
      data_json = JSON.generate({ category: @occ_category, items: @occ_results })
      @occ_dialog.set_html(occ_review_html(data_json))

      @occ_dialog.add_action_callback('occToggle') do |_ctx, eid_str|
        eid = eid_str.to_i
        item = @occ_results.find { |r| r[:eid] == eid }
        if item
          item[:included] = !item[:included]
          # Repaint entity
          m = Sketchup.active_model
          if m
            e = TakeoffTool.find_entity(eid)
            if e && e.valid?
              mat_name = item[:included] ? 'FF_DEBUG_OPEN' : 'FF_DEBUG_BLOCKED'
              mat = m.materials[mat_name]
              if mat
                m.start_operation('OCC Toggle', true)
                debug_paint_entity(e, mat)
                m.commit_operation
              end
            end
          end
          send_occ_data
        end
      end

      @occ_dialog.add_action_callback('occZoom') do |_ctx, eid_str|
        eid = eid_str.to_i
        e = TakeoffTool.find_entity(eid)
        if e && e.valid?
          m = Sketchup.active_model
          bb = Geom::BoundingBox.new
          bb.add(e.bounds)
          m.active_view.zoom(bb) unless bb.empty?
        end
      end

      @occ_dialog.add_action_callback('occPick') do |_ctx|
        if @occ_pick_active
          @occ_pick_active = false
          Sketchup.active_model.select_tool(nil)
          @occ_dialog.execute_script("setPickMode(false)") if @occ_dialog&.visible?
        else
          @occ_pick_active = true
          Sketchup.active_model.select_tool(OccPickTool.new)
          @occ_dialog.execute_script("setPickMode(true)") if @occ_dialog&.visible?
        end
      end

      @occ_dialog.add_action_callback('occHide') do |_ctx, status|
        m = Sketchup.active_model
        next unless m
        m.start_operation('OCC Hide', true)
        @occ_results.each do |r|
          next unless r[:status] == status
          e = TakeoffTool.find_entity(r[:eid])
          next unless e && e.valid?
          e.hidden = true
        end
        m.commit_operation
      end

      @occ_dialog.add_action_callback('occShow') do |_ctx, status|
        m = Sketchup.active_model
        next unless m
        m.start_operation('OCC Show', true)
        @occ_results.each do |r|
          next unless status == 'all' || r[:status] == status
          e = TakeoffTool.find_entity(r[:eid])
          next unless e && e.valid?
          e.hidden = false
        end
        m.commit_operation
      end

      @occ_dialog.add_action_callback('occSolo') do |_ctx, status|
        m = Sketchup.active_model
        next unless m
        m.start_operation('OCC Solo', true)
        @occ_results.each do |r|
          e = TakeoffTool.find_entity(r[:eid])
          next unless e && e.valid?
          e.hidden = (r[:status] != status)
        end
        m.commit_operation
      end

      @occ_dialog.add_action_callback('occApply') do |_ctx|
        sr = TakeoffTool.instance_variable_get(:@scan_results) || []
        applied = 0
        restored = 0
        @occ_results.each do |item|
          match = sr.find { |r| r[:entity_id] == item[:eid] }
          next unless match
          # Save original if not already saved
          unless @occ_original_sf.key?(item[:eid])
            @occ_original_sf[item[:eid]] = match[:area_sf]
          end
          if item[:included]
            # Restore original value
            match[:area_sf] = @occ_original_sf[item[:eid]]
            restored += 1
          else
            # Zero out excluded
            match[:area_sf] = 0
            applied += 1
          end
        end
        puts "[FF OCC] Applied: #{applied} excluded (zeroed), #{restored} included (restored)"
        # Refresh dashboard
        Dashboard.send_live_data if defined?(Dashboard)
        # Notify dialog
        @occ_dialog.execute_script("showApplied(#{applied},#{restored})") if @occ_dialog&.visible?
      end

      @occ_dialog.add_action_callback('occClear') do |_ctx|
        # Deactivate pick tool if active
        if @occ_pick_active
          @occ_pick_active = false
          Sketchup.active_model.select_tool(nil)
        end
        # Restore original SF values
        if @occ_original_sf.any?
          sr = TakeoffTool.instance_variable_get(:@scan_results) || []
          @occ_original_sf.each do |eid, orig_sf|
            match = sr.find { |r| r[:entity_id] == eid }
            match[:area_sf] = orig_sf if match
          end
          @occ_original_sf = {}
          Dashboard.send_live_data if defined?(Dashboard)
        end
        clear_debug
        # Restore visibility
        m = Sketchup.active_model
        if m
          m.start_operation('OCC Clear', true)
          @occ_results.each do |r|
            e = TakeoffTool.find_entity(r[:eid])
            e.hidden = false if e && e.valid?
          end
          m.commit_operation
        end
        @occ_results = []
        @occ_dialog.close if @occ_dialog&.visible?
      end

      @occ_dialog.set_on_closed do
        @occ_dialog = nil
      end

      @occ_dialog.show
    end

    def self.send_occ_data
      return unless @occ_dialog && @occ_dialog.visible? && @occ_results
      begin
        require 'json'
        payload = { category: @occ_category, items: @occ_results }
        js = JSON.generate(payload).gsub('</') { '<\\/' }
        @occ_dialog.execute_script("receiveOccData(#{js})")
      rescue => e
        puts "[FF OCC] send_occ_data error: #{e.message}"
      end
    end

    def self.occ_review_html(data_json)
      # Embed JSON directly as JS object literal — no string escaping needed
      # Only guard against </script> breaking the HTML
      safe_json = data_json.gsub('</') { '<\\/' }
      <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
      <meta charset="utf-8">
      <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{background:#1e1e2e;color:#cdd6f4;font-family:'Segoe UI',sans-serif;font-size:12px;padding:10px}
        .hdr{font-size:14px;font-weight:600;color:#a6e3a1;margin-bottom:8px}
        .summary{display:flex;gap:12px;margin-bottom:10px;padding:8px;background:#313244;border-radius:6px}
        .sum-item{text-align:center;flex:1}
        .sum-val{font-size:18px;font-weight:700}
        .sum-lbl{font-size:10px;color:#a6adc8;margin-top:2px}
        .s-open .sum-val{color:#a6e3a1}
        .s-partial .sum-val{color:#f9e2af}
        .s-blocked .sum-val{color:#f38ba8}
        .s-revised .sum-val{color:#89b4fa}
        .list{max-height:240px;overflow-y:auto;border:1px solid #45475a;border-radius:4px}
        .row{display:flex;align-items:center;padding:5px 8px;border-bottom:1px solid #313244;gap:6px}
        .row:hover{background:#313244}
        .row.excluded{opacity:0.4;text-decoration:line-through}
        .dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
        .dot-open{background:#a6e3a1}
        .dot-partial{background:#f9e2af}
        .dot-blocked{background:#f38ba8}
        .name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px}
        .sf{color:#a6adc8;font-size:11px;min-width:60px;text-align:right}
        .btn{background:none;border:1px solid #585b70;color:#cdd6f4;border-radius:4px;cursor:pointer;padding:2px 8px;font-size:11px}
        .btn:hover{background:#45475a}
        .btn.inc{border-color:#a6e3a1;color:#a6e3a1}
        .btn.exc{border-color:#f38ba8;color:#f38ba8}
        .zoom-btn{background:none;border:none;cursor:pointer;color:#89b4fa;font-size:12px;padding:2px}
        .zoom-btn:hover{color:#b4befe}
        .toolbar{display:flex;gap:8px;margin-top:10px;justify-content:flex-end}
        .toolbar .btn{padding:4px 14px;font-size:12px}
        .toolbar .btn.clr{border-color:#f38ba8;color:#f38ba8}
        .filter{display:flex;gap:6px;margin-bottom:8px;align-items:center}
        .filter label{color:#a6adc8;font-size:11px}
        .filter select{background:#313244;color:#cdd6f4;border:1px solid #585b70;border-radius:4px;padding:2px 6px;font-size:11px}
        .vis{display:flex;gap:4px;margin-bottom:8px;flex-wrap:wrap}
        .vis .vb{padding:3px 10px;font-size:11px;border-radius:4px;cursor:pointer;border:1px solid #585b70;background:none;color:#cdd6f4}
        .vis .vb:hover{background:#45475a}
        .vis .vb.g{border-color:#a6e3a1;color:#a6e3a1}
        .vis .vb.y{border-color:#f9e2af;color:#f9e2af}
        .vis .vb.r{border-color:#f38ba8;color:#f38ba8}
        .vis .vb.solo{background:#45475a;font-weight:600}
        .vis .lbl{color:#a6adc8;font-size:10px;align-self:center;margin-right:2px}
        .pick-bar{display:flex;gap:6px;margin-bottom:8px;align-items:center}
        .pick-btn{padding:4px 14px;font-size:12px;border-radius:4px;cursor:pointer;border:2px solid #89b4fa;background:none;color:#89b4fa;font-weight:600}
        .pick-btn:hover{background:#313244}
        .pick-btn.active{background:#89b4fa;color:#1e1e2e}
        .pick-lbl{color:#a6adc8;font-size:10px}
        .row.highlight{background:#45475a;outline:1px solid #89b4fa}
      </style>
      </head>
      <body>
      <div class="hdr" id="title">OCC Review</div>
      <div class="summary">
        <div class="sum-item s-open"><div class="sum-val" id="sOpen">-</div><div class="sum-lbl">Open SF</div></div>
        <div class="sum-item s-partial"><div class="sum-val" id="sPartial">-</div><div class="sum-lbl">Partial SF</div></div>
        <div class="sum-item s-blocked"><div class="sum-val" id="sBlocked">-</div><div class="sum-lbl">Blocked SF</div></div>
        <div class="sum-item s-revised"><div class="sum-val" id="sRevised">-</div><div class="sum-lbl">Revised Total</div></div>
      </div>
      <div class="filter">
        <label>Show:</label>
        <select id="filterSel" onchange="applyFilter()">
          <option value="all">All</option>
          <option value="partial">Yellow + Red</option>
          <option value="blocked">Red only</option>
        </select>
      </div>
      <div class="vis">
        <span class="lbl">Visibility:</span>
        <button class="vb g" data-action="occHide" data-eid="open">Hide Green</button>
        <button class="vb y" data-action="occHide" data-eid="partial">Hide Yellow</button>
        <button class="vb r" data-action="occHide" data-eid="blocked">Hide Red</button>
        <button class="vb g" data-action="occSolo" data-eid="open">Solo Green</button>
        <button class="vb y" data-action="occSolo" data-eid="partial">Solo Yellow</button>
        <button class="vb r" data-action="occSolo" data-eid="blocked">Solo Red</button>
        <button class="vb" data-action="occShow" data-eid="all">Show All</button>
      </div>
      <div class="pick-bar">
        <button class="pick-btn" id="pickBtn" data-action="occPick">Pick Mode</button>
        <span class="pick-lbl" id="pickLbl">Click to activate, then click walls in model to toggle</span>
      </div>
      <div class="list" id="list"></div>
      <div class="toolbar">
        <button class="btn" data-action="occApply" style="border-color:#89b4fa;color:#89b4fa">Apply to Dashboard</button>
        <button class="btn clr" data-action="occClear">Clear &amp; Close</button>
      </div>
      <div id="applyMsg" style="display:none;text-align:center;padding:4px;margin-top:4px;font-size:11px;color:#a6e3a1;background:#313244;border-radius:4px"></div>
      <script>
      var ITEMS=[];
      var FILTER='all';
      function skCall(a,b){if(window.sketchup&&window.sketchup[a])window.sketchup[a](b||'');}
      function receiveOccData(d){
        if(typeof d==='string') d=JSON.parse(d);
        document.getElementById('title').textContent='OCC Review \\u2014 '+d.category;
        ITEMS=d.items;
        render();
      }
      function render(){
        var openSf=0,partSf=0,blockSf=0,revisedSf=0;
        for(var i=0;i<ITEMS.length;i++){
          var it=ITEMS[i];
          if(it.status==='open')openSf+=it.sf;
          else if(it.status==='partial')partSf+=it.sf;
          else blockSf+=it.sf;
          if(it.included)revisedSf+=it.sf;
        }
        document.getElementById('sOpen').textContent=openSf.toFixed(0);
        document.getElementById('sPartial').textContent=partSf.toFixed(0);
        document.getElementById('sBlocked').textContent=blockSf.toFixed(0);
        document.getElementById('sRevised').textContent=revisedSf.toFixed(0);

        var h='';
        for(var i=0;i<ITEMS.length;i++){
          var it=ITEMS[i];
          if(FILTER==='partial'&&it.status==='open')continue;
          if(FILTER==='blocked'&&it.status!=='blocked')continue;
          var cls=it.included?'':'excluded';
          var dot='dot-'+it.status;
          var esc=it.name.replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;');
          h+='<div class="row '+cls+'" id="row-'+it.eid+'">';
          h+='<div class="dot '+dot+'"></div>';
          h+='<button class="zoom-btn" data-action="occZoom" data-eid="'+it.eid+'" title="Zoom">&#8982;</button>';
          h+='<span class="name" title="'+esc+'">'+esc+'</span>';
          h+='<span class="sf">'+it.sf.toFixed(1)+' SF</span>';
          h+='<button class="btn '+(it.included?'exc':'inc')+'" data-action="occToggle" data-eid="'+it.eid+'">'+(it.included?'\\u2212':'+')+'</button>';
          h+='</div>';
        }
        document.getElementById('list').innerHTML=h;
      }
      function applyFilter(){FILTER=document.getElementById('filterSel').value;render();}
      function setPickMode(active){
        var btn=document.getElementById('pickBtn');
        var lbl=document.getElementById('pickLbl');
        if(active){btn.classList.add('active');lbl.textContent='ACTIVE — click walls in model to toggle';}
        else{btn.classList.remove('active');lbl.textContent='Click to activate, then click walls in model to toggle';}
      }
      var _hlTimer=null;
      function highlightRow(eid){
        if(_hlTimer){clearTimeout(_hlTimer);_hlTimer=null;}
        var prev=document.querySelectorAll('.row.highlight');
        for(var i=0;i<prev.length;i++)prev[i].classList.remove('highlight');
        var el=document.getElementById('row-'+eid);
        if(!el)return;
        el.classList.add('highlight');
        el.scrollIntoView({block:'center',behavior:'smooth'});
        _hlTimer=setTimeout(function(){el.classList.remove('highlight');_hlTimer=null;},3000);
      }
      function showApplied(exc,inc){
        var el=document.getElementById('applyMsg');
        el.textContent='Applied: '+exc+' excluded, '+inc+' included — dashboard updated';
        el.style.display='block';
        setTimeout(function(){el.style.display='none';},4000);
      }
      document.addEventListener('click',function(e){
        var btn=e.target.closest('[data-action]');
        if(!btn)return;
        skCall(btn.dataset.action,btn.dataset.eid);
      });
      receiveOccData(#{safe_json});
      </script>
      </body>
      </html>
      HTML
    end

    # ═══════════════════════════════════════════════════════════
    # debug_occlusion_single — Verbose per-ray occlusion for one entity
    # ═══════════════════════════════════════════════════════════

    def self.debug_occlusion_single(eid, threshold_in = 18.0)
      e = TakeoffTool.find_entity(eid)
      unless e && e.valid?
        puts "[FF OCC Single] Entity #{eid} not found"
        return
      end

      defn = e.respond_to?(:definition) ? e.definition : nil
      unless defn
        puts "[FF OCC Single] Entity #{eid} has no definition"
        return
      end

      m = Sketchup.active_model
      return unless m

      xform = e.transformation
      faces = defn.entities.grep(Sketchup::Face)
      return if faces.empty?

      # Lookup for blocker names
      sr = TakeoffTool.filtered_scan_results
      ca = TakeoffTool.category_assignments
      blocker_lookup = {}
      if sr
        sr.each do |r|
          bcat = ca[r[:entity_id]] || r[:parsed][:auto_category] || '?'
          bdn = r[:display_name] || r[:definition_name] || ''
          bdn = r[:parsed][:element_type] || r[:parsed][:function] || bdn[0..20] + '...' if bdn.length > 36 && bdn.include?('-')
          blocker_lookup[r[:entity_id]] = "#{bcat}: #{bdn}"
        end
      end

      match = sr&.find { |r| r[:entity_id] == eid }
      cat = match ? (ca[eid] || match[:parsed][:auto_category]) : nil
      dname = match ? (match[:display_name] || defn.name) : defn.name

      # Find measured faces
      measured = []
      cat_re = cat || ''
      if cat_re =~ SHEET_GOOD_RE
        groups = {}
        faces.each do |f|
          n = f.normal
          key = "#{n.x.round(1)},#{n.y.round(1)},#{n.z.round(1)}"
          groups[key] ||= { faces: [], area: 0.0 }
          groups[key][:faces] << f
          groups[key][:area] += world_face_area(f, xform)
        end
        dom_key = groups.max_by { |_k, v| v[:area] }&.first
        measured = dom_key ? groups[dom_key][:faces] : []
      elsif enclosed_3d?(faces)
        largest = faces.max_by { |f| world_face_area(f, xform) }
        measured = [largest] if largest
      else
        measured = faces
      end

      sf = measured.sum { |f| world_face_area(f, xform) } / 144.0

      puts ""
      puts "═══════════════════════════════════════════════════════════"
      puts "[FF OCC Single] Entity #{eid}: '#{dname}'"
      puts "  Category: #{cat || '?'}"
      puts "  Measured faces: #{measured.length}, #{sf.round(2)} SF"
      puts "  Threshold: #{threshold_in}\""
      puts "───────────────────────────────────────────────"

      # Use more samples for single-entity debug
      num_samples = 12

      mat_open = m.materials['FF_DEBUG_OPEN'] || m.materials.add('FF_DEBUG_OPEN')
      mat_open.color = Sketchup::Color.new(0, 200, 0, 180)
      mat_partial = m.materials['FF_DEBUG_PARTIAL'] || m.materials.add('FF_DEBUG_PARTIAL')
      mat_partial.color = Sketchup::Color.new(240, 200, 0, 180)
      mat_blocked = m.materials['FF_DEBUG_BLOCKED'] || m.materials.add('FF_DEBUG_BLOCKED')
      mat_blocked.color = Sketchup::Color.new(200, 0, 0, 180)

      total_rays = 0
      total_hits = 0
      total_assembly = 0
      total_open = 0

      m.start_operation('OCC Single Debug', true)

      measured.each_with_index do |face, fi|
        normal_world = (xform * face.normal).normalize rescue face.normal
        samples = face_sample_points(face, xform, num_samples)
        next if samples.empty?

        # Determine room side
        test_pt = samples.first
        pt_fwd = Geom::Point3d.new(
          test_pt.x + normal_world.x * DEBUG_OCC_OFFSET,
          test_pt.y + normal_world.y * DEBUG_OCC_OFFSET,
          test_pt.z + normal_world.z * DEBUG_OCC_OFFSET
        )
        rev = Geom::Vector3d.new(-normal_world.x, -normal_world.y, -normal_world.z)
        pt_rev = Geom::Point3d.new(
          test_pt.x + rev.x * DEBUG_OCC_OFFSET,
          test_pt.y + rev.y * DEBUG_OCC_OFFSET,
          test_pt.z + rev.z * DEBUG_OCC_OFFSET
        )
        hit_fwd = m.raytest([pt_fwd, normal_world])
        hit_rev = m.raytest([pt_rev, rev])
        dist_fwd = hit_fwd ? pt_fwd.distance(hit_fwd[0]) : 99999
        dist_rev = hit_rev ? pt_rev.distance(hit_rev[0]) : 99999
        room_dir = normal_world
        if dist_rev < dist_fwd && dist_rev < 6.0
          room_dir = normal_world
        elsif dist_fwd < dist_rev && dist_fwd < 6.0
          room_dir = rev
        end

        n = face.normal
        face_sf = world_face_area(face, xform) / 144.0
        puts "  Face #{fi+1}: normal=(#{n.x.round(2)},#{n.y.round(2)},#{n.z.round(2)}), #{face_sf.round(2)} SF, #{samples.length} rays"

        face_hits = 0
        samples.each_with_index do |pt, ri|
          ray_origin = Geom::Point3d.new(
            pt.x + room_dir.x * DEBUG_OCC_OFFSET,
            pt.y + room_dir.y * DEBUG_OCC_OFFSET,
            pt.z + room_dir.z * DEBUG_OCC_OFFSET
          )
          result = m.raytest([ray_origin, room_dir])
          total_rays += 1

          if result
            hit_pt = result[0]
            dist = ray_origin.distance(hit_pt)
            hit_path = result[1]

            # Find containing component
            hit_inst = nil
            if hit_path.is_a?(Array)
              hit_path.reverse_each do |pe|
                if pe.is_a?(Sketchup::ComponentInstance) || pe.is_a?(Sketchup::Group)
                  hit_inst = pe
                  break
                end
              end
            end

            # Self check
            is_self = false
            if hit_inst
              is_self = (hit_inst == e) || (hit_inst.respond_to?(:definition) && hit_inst.definition == defn)
            else
              is_self = true
            end

            if is_self
              puts "    Ray #{ri+1}: SELF at #{dist.round(1)}\""
              next
            end

            if dist < DEBUG_OCC_MIN || dist > threshold_in
              puts "    Ray #{ri+1}: out of range (#{dist.round(1)}\")"
              total_open += 1
              next
            end

            # Get blocker info
            hit_eid = hit_inst.respond_to?(:entityID) ? hit_inst.entityID : 0
            hit_cat = blocker_lookup[hit_eid]&.split(':')&.first&.strip || ''
            hit_tag = hit_inst.respond_to?(:layer) ? hit_inst.layer.name : ''
            bname = blocker_lookup[hit_eid] || "#{hit_tag}: #{hit_inst.respond_to?(:definition) ? hit_inst.definition.name[0..30] : '?'}"

            # Assembly filter check
            is_assembly = (hit_cat =~ OCC_ASSEMBLY_RE) || (hit_tag =~ OCC_ASSEMBLY_RE)
            if is_assembly
              puts "    Ray #{ri+1}: ASSEMBLY at #{dist.round(1)}\" → #{bname} (ignored)"
              total_assembly += 1
            else
              puts "    Ray #{ri+1}: BLOCKED at #{dist.round(1)}\" → #{bname}"
              face_hits += 1
              total_hits += 1
            end
          else
            puts "    Ray #{ri+1}: OPEN (no hit)"
            total_open += 1
          end
        end
      end

      # Paint the entity based on result
      ratio = total_rays > 0 ? total_hits.to_f / total_rays : 0
      color_mat = ratio >= 0.6 ? mat_blocked : ratio >= 0.2 ? mat_partial : mat_open
      debug_paint_entity(e, color_mat)
      m.commit_operation

      # Zoom
      begin
        bb = Geom::BoundingBox.new
        bb.add(e.bounds)
        m.active_view.zoom(bb) unless bb.empty?
      rescue; end

      label = ratio >= 0.6 ? 'RED (blocked)' : ratio >= 0.2 ? 'YELLOW (partial)' : 'GREEN (open)'
      puts "───────────────────────────────────────────────"
      puts "  Total rays: #{total_rays}"
      puts "  Blocked:    #{total_hits} (real occlusion)"
      puts "  Assembly:   #{total_assembly} (filtered out)"
      puts "  Open/self:  #{total_rays - total_hits - total_assembly}"
      puts "  Result:     #{label} (#{(ratio * 100).round(0)}%)"
      puts "═══════════════════════════════════════════════════════════"
    end

    # Get sample points on a face in world coordinates
    def self.face_sample_points(face, xform, max_samples)
      points = []
      begin
        mesh = face.mesh(0)
        n_polys = mesh.count_polygons
        return points if n_polys == 0

        step = [n_polys / max_samples, 1].max
        (1..n_polys).step(step) do |pi|
          tri = mesh.polygon_points_at(pi)
          next unless tri && tri.length >= 3
          cx = (tri[0].x + tri[1].x + tri[2].x) / 3.0
          cy = (tri[0].y + tri[1].y + tri[2].y) / 3.0
          cz = (tri[0].z + tri[1].z + tri[2].z) / 3.0
          points << (xform * Geom::Point3d.new(cx, cy, cz))
          break if points.length >= max_samples
        end
      rescue => e
        puts "[FF Occlusion] face_sample_points error: #{e.message}"
      end
      points
    end

    # Faces on 3+ distinct normal directions = enclosed 3D object
    def self.enclosed_3d?(faces)
      normals = {}
      faces.first(20).each do |f|
        n = f.normal
        key = "#{n.x.round(1)},#{n.y.round(1)},#{n.z.round(1)}"
        normals[key] = true
      end
      normals.length >= 3
    end

    # Convert actual inches to closest nominal lumber size (within 0.5" tolerance)
    def self.to_nominal(actual_in)
      best = nil; best_diff = 999.0
      NOMINAL_SIZES.each do |actual, nominal|
        diff = (actual_in - actual).abs
        if diff < best_diff
          best_diff = diff; best = nominal
        end
      end
      best_diff <= 0.5 ? best : nil
    end

    # ═══════════════════════════════════════════════════════════
    # filter_ea_children — Remove nested sub-components from EA categories
    #
    # If a can light has 5 sub-components (bulb, trim, housing, bracket, junction box)
    # all categorized as "Lighting Fixtures", we only want the top-level can light.
    # Walk up each EA entity's parent chain; if an ancestor is also in the results
    # with the same EA category, the entity is a child and gets removed.
    # ═══════════════════════════════════════════════════════════

    def self.filter_ea_children(results, reg)
      # Build lookup: entity_id → auto_category (only for EA-measured categories)
      ea_cats = {}
      results.each do |r|
        cat = r[:parsed][:auto_category]
        mt = r[:parsed][:measurement_type] || Parser.measurement_for(cat)
        ea_cats[r[:entity_id]] = cat if mt && mt.start_with?('ea')
      end
      return if ea_cats.empty?

      children = Set.new

      ea_cats.each do |eid, cat|
        entity = reg[eid]
        next unless entity && entity.valid?

        # Walk up the parent chain
        cursor = entity.parent
        while cursor
          break if cursor.is_a?(Sketchup::Model)

          if cursor.is_a?(Sketchup::ComponentDefinition)
            # Check if any instance of this parent definition is in the same EA category
            cursor.instances.each do |pinst|
              next unless pinst.valid?
              if ea_cats[pinst.entityID] == cat
                children.add(eid)
                break
              end
            end
            break if children.include?(eid)
            # Move up: pick any instance's parent to continue walking
            pinst = cursor.instances.first
            cursor = pinst ? pinst.parent : nil
          else
            cursor = cursor.respond_to?(:parent) ? cursor.parent : nil
          end
        end
      end

      if children.any?
        before = results.length
        results.reject! { |r| children.include?(r[:entity_id]) }
        puts "[FF Scanner] EA dedup: removed #{children.size} nested children (#{before} → #{results.length})"
      end
    end

    # ═══════════════════════════════════════════════════════════
    # detect_overcounts — Post-scan safety net for EA categories
    #
    # Even after filter_ea_children, some models may have non-standard nesting.
    # This pass detects suspicious count ratios and flags them for user review.
    # ═══════════════════════════════════════════════════════════

    def self.detect_overcounts(results, reg)
      warnings = []

      # Group by category
      by_cat = {}
      results.each do |r|
        cat = r[:parsed][:auto_category]
        by_cat[cat] ||= []
        by_cat[cat] << r
      end

      by_cat.each do |cat, cat_results|
        mt = cat_results.first&.dig(:parsed, :measurement_type) || Parser.measurement_for(cat)
        next unless mt && mt.start_with?('ea')

        # Count entities that HAVE children in the same category in their definition
        parent_count = 0
        child_like = 0

        cat_eids = Set.new(cat_results.map { |r| r[:entity_id] })

        cat_results.each do |r|
          entity = reg[r[:entity_id]]
          next unless entity && entity.valid?

          # Check if this entity has children in the same category
          if entity.respond_to?(:definition)
            has_cat_children = entity.definition.entities.any? do |child|
              child.respond_to?(:entityID) && cat_eids.include?(child.entityID)
            end
            parent_count += 1 if has_cat_children
          end

          # Check if this entity IS inside a parent (not at model root)
          p = entity.parent
          child_like += 1 if p.is_a?(Sketchup::ComponentDefinition)
        end

        total = cat_results.length
        # Flag if >30% of entities appear to be nested children
        if child_like > parent_count && parent_count > 0
          ratio = child_like.to_f / total
          if ratio > 0.3
            probable = total - child_like + parent_count
            warnings << {
              category: cat,
              total_counted: total,
              probable_real_count: probable,
              child_count: child_like,
              overcount_ratio: ratio.round(2),
              message: "#{cat}: #{total} counted but likely ~#{probable} real items (#{child_like} may be nested children)"
            }
          end
        end
      end

      warnings
    end
  end
end
