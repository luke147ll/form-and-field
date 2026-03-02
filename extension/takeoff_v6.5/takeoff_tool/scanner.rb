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
      [/\bSheathing\b|\bOSB\b|\bPlywood\b/i, 'Sheathing'],
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

    # ═══════════════════════════════════════════════════════════
    # scan_model — Main entry point
    # ═══════════════════════════════════════════════════════════

    def self.scan_model(model, &progress)
      results = []; reg = {}; seen = {}
      @is_ifc_model = IFCParser.ifc_model?(model)

      # Auto-detection summary
      has_revit = model.definitions.any? { |d| !d.image? && d.name =~ /^Basic Wall|^Basic Roof|^Compound Ceiling/i }
      if @is_ifc_model
        progress.call("IFC model detected — IFC + material + keyword parsers active") if progress
      elsif has_revit
        progress.call("Revit model detected — name + material + keyword parsers active") if progress
      else
        progress.call("Generic model — material + keyword parsers active") if progress
      end

      defs = model.definitions.select { |d| !d.image? }
      total_defs = defs.length
      progress.call("Found #{total_defs} definitions to process") if progress

      defs.each_with_index do |defn, idx|
        inst_count = defn.instances.length
        progress.call("Definition #{idx+1}/#{total_defs}: #{defn.name} (#{inst_count} instances)") if progress && inst_count > 0
        defn.instances.each do |inst|
          next if seen[inst.entityID]; seen[inst.entityID] = true
          reg[inst.entityID] = inst
          process(inst, defn, results)
        end
      end

      progress.call("Processing warnings...") if progress
      check_warnings(results)
      progress.call("Sorting #{results.length} results") if progress
      [results.sort_by{|r|[r[:tag]||'zzz',r[:display_name]||'']}, reg]
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

      # Compute material
      mat = nil
      if inst.material
        mat = inst.material.display_name
      else
        f = defn.entities.grep(Sketchup::Face).first
        mat = f.material.display_name if f && f.material
      end

      # Compute IFC type
      ifc = nil
      if defn.attribute_dictionaries
        a = defn.attribute_dictionaries['AppliedSchemaTypes']
        ifc = a['IFC 4'] if a
      end

      # Skip IFC organizational containers
      return if @is_ifc_model && %w[IfcBuilding IfcBuildingStorey IfcSite IfcProject].include?(tag)

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

      # Count same-name instances
      cnt = 0
      if iname
        Sketchup.active_model.definitions.each{|df| df.instances.each{|i| cnt+=1 if i.name==iname}}
      end
      cnt = [cnt, 1].max

      vi3 = vol.to_f; vf3 = vi3/1728.0; vbf = vi3/144.0

      area = nil
      if parsed[:thickness] && is_solid
        tin = Parser.dim_to_in(parsed[:thickness])
        area = vi3/tin/144.0 if tin && tin > 0
      end

      # Compute LF from longest bounding box dimension
      longest_in = [w, h, d].max
      linear_ft = longest_in / 12.0

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

    def self.scan_entity(inst, defn, display, tag, mat, ifc_type)
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
  end
end
