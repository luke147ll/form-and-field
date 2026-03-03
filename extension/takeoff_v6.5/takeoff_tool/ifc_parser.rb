module TakeoffTool
  module IFCParser

    unless defined?(MEMBER_TYPE_MAP)
    # ─── Framing/structural member type keywords ───
    # Single-word keywords checked with rightmost-match logic.
    # Map: keyword → subcategory for grouping.
    MEMBER_TYPE_MAP = {
      'Valley' => 'Rafter', 'Hip' => 'Rafter', 'Ridge' => 'Ridge',
      'Gable' => 'Rafter', 'Strut' => 'Brace', 'Brace' => 'Brace',
      'Purlin' => 'Purlin', 'Rafter' => 'Rafter', 'Joist' => 'Joist',
      'Post' => 'Post', 'Beam' => 'Beam', 'Crown' => 'Crown',
      'Chord' => 'Chord', 'Ring' => 'Ring', 'Girt' => 'Beam',
      'Plate' => 'Plate', 'Tie' => 'Tie', 'Collar' => 'Tie',
    }.freeze

    # Fractional sizes: "2 5/8"t x10 Crown", "3 5/8"t x10 Post"
    TIMBER_FRAC_RE  = /^(\d+\s+\d+\/\d+[""″]?t?\s*x\s*\d+[""″]?t?)\s+(.+)/i

    # Simple NxN with optional quote-t suffix: "18x18 Post", "16x24"t Post"
    TIMBER_SIMPLE_RE = /^(\d+\s*x\s*\d+[""″]?t?)\s+(.+)/i

    # ─── Engineered lumber → always Structural Lumber ───
    ENGINEERED_RE = /\b(LVL|TJI|I-?Joist|Truss|Engineered|Microlam|Parallam|LSL|PSL|Rim\s*Board|Rim\s*Joist)\b/i

    # ─── Wood species that indicate timber ───
    TIMBER_SPECIES_RE = /\b(Oak|White\s*Oak|Red\s*Oak|Cedar|Douglas\s*Fir|Fir|Pine|Walnut|Cherry|Maple|Glulam|Timber|Reclaimed)\b/i

    # ─── Structural IFC tags (for bounding-box classification) ───
    STRUCTURAL_IFC_TAGS = %w[IfcBeam IfcColumn IfcMember].freeze

    # ─── Timber keywords found anywhere in name (room-prefixed patterns) ───
    # Catches "Living Rafter", "Dining Jack Rafter", "Living Top Chord", etc.
    TIMBER_KEYWORDS = %w[Beam Brace Chord Crown Joist Post Purlin Rafter Ridge Ring].freeze
    TIMBER_KEYWORD_TAGS = %w[IfcBeam IfcColumn IfcMember IfcBuildingElementProxy].freeze

    # ─── Hardware / Fastener patterns ───
    HARDWARE_RE = /\u00D8|\bBolt\b|\bDowel\b|\bLag\b|\bAnchor\b|\bScrew\b|\bNail\b|\bWasher\b|\bNut\b|H\.A\.S\.|ATR\b|\bFastener\b/i

    # ─── Material override: skip these non-structural tags ───
    NON_STRUCTURAL_TAGS = %w[IfcDoor IfcWindow IfcStair IfcStairFlight IfcRailing
      IfcSlab IfcWall IfcWallStandardCase IfcRoof IfcCovering IfcSpace
      IfcCurtainWall IfcFooting IfcPile].freeze
    STEEL_OVERRIDE_RE = /\b(Steel|Iron|Galvanized)\b/i
    REBAR_MAT_RE      = /\bConcrete\s*Steel\b|\bRebar\b|\bReinforc(?:ing\s*Steel|ement)\b/i
    CONCRETE_MAT_RE   = /^Concrete|\bCMU\b|\bBlock\b|\bMasonry\b|\bGrout\b/i

    # ─── Foundation / concrete keywords: [regex, category, subcategory] ───
    FOUNDATION_KW = [
      [/\bSlab\s+on\s+Grade\b|\bSOG\b/i, 'Concrete', 'Slab on Grade'],
      [/\bGrade\s*Beam\b/i,  'Concrete', 'Grade Beam'],
      [/\bPier\b/i,          'Concrete', 'Piers'],
      [/\bColumn\b/i,        'Concrete', 'Piers'],
      [/\bPiling\b/i,        'Concrete', 'Footings'],
      [/\bFooting\b|\bFTG\b/i, 'Concrete', 'Footings'],
      [/\bCaisson\b/i,       'Concrete', 'Footings'],
      [/\bFoundation\b/i,    'Concrete', 'Foundation'],
      [/\bSlab\b/i,          'Concrete', 'Slabs'],
    ].freeze

    # ─── Steel designation patterns ───
    STEEL_W_RE   = /^(W\d+[xX]\d+\.?\d*)/
    STEEL_HSS_RE = /^(HSS[\d\.]+[xX][\d\.]+[xX][\d\/\.]+)/i
    STEEL_L_RE   = /^(L[\d\.]+[xX][\d\.]+[xX][\d\/\.]+)/
    STEEL_C_RE   = /^(C\d+[xX]\d+\.?\d*)/
    STEEL_WT_RE  = /^(WT\d+[xX]\d+\.?\d*)/
    STEEL_PL_RE  = /^(PL\s*[\d\/]+)/i

    # ─── Building material keyword patterns (checked BEFORE dimension patterns) ───
    SIDING_RE      = /\b(Siding|Lap\s*Siding|Board\s*and\s*Batten|Hardie(?!backer))\b/i
    SHEATHING_RE   = /\b(Sheathing|OSB|Plywood|CDX)\b/i
    CEMENT_BOARD_RE = /\b(Durock|Hardiebacker|Cement\s*Board|CBU)\b/i
    TNG_RE         = /\b(T&G|T\s*&\s*G|Tongue\s*and\s*Groove)\b/i
    DRYWALL_RE     = /\b(Drywall|Gypsum|GWB|Sheetrock)\b/i
    INSULATION_RE  = /\b(Insulation|Batt|Rigid\b|Foam)\b/i

    # Thickness extraction: "1 1/4" thick", "1/2"", "3/4\" CDX", "5/8" Drywall"
    THICKNESS_FRAC_RE  = /(\d+\s+\d+\/\d+)\s*[""″]/       # "1 1/4""
    THICKNESS_SIMPLE_RE = /(\d+\/\d+)\s*[""″]/              # "1/2""
    THICKNESS_WHOLE_RE  = /(\d+)\s*[""″]\s*(?:thick\b)?/i   # "2" thick"

    # ─── Concrete pattern ───
    CONCRETE_RE = /(\d+)\s*[""″]?\s*(Concrete|CMU|Block)/i

    # ─── IFC tag → category fallback (used when name parsing didn't match) ───
    IFC_TAG_MAP = {
      'IfcSlab'              => 'Flooring',
      'IfcWall'              => 'Walls',
      'IfcWallStandardCase'  => 'Walls',
      'IfcRoof'              => 'Roofing',
      'IfcDoor'              => 'Doors',
      'IfcWindow'            => 'Windows',
      'IfcStair'             => 'Stairs',
      'IfcStairFlight'       => 'Stairs',
      'IfcRailing'           => 'Railings',
      'IfcCovering'          => 'Wall Finish',
      'IfcFooting'           => 'Concrete',
      'IfcPile'              => 'Concrete',
      'IfcCurtainWall'       => 'Glass/Glazing',
      'IfcSpace'             => 'Rooms',
      'IfcBeam'              => 'Structural Lumber',
      'IfcColumn'            => 'Structural Lumber',
      'IfcMember'            => 'Structural Lumber',
      'IfcPlate'             => 'Structural Steel',
      'IfcMechanicalFastener' => 'Hardware',
    }.freeze
    end # unless defined?(MEMBER_TYPE_MAP)

    # ═══════════════════════════════════════════════════════════════════
    # Detection: does this model have IFC-style tags/layers?
    # ═══════════════════════════════════════════════════════════════════

    def self.ifc_model?(model)
      return false unless model
      count = 0
      model.layers.each do |layer|
        count += 1 if layer.name =~ /^Ifc[A-Z]/
        return true if count >= 2  # At least 2 IFC tags = IFC model
      end
      false
    end

    # ═══════════════════════════════════════════════════════════════════
    # Per-entity parse: accepts a SketchUp ComponentInstance/Group.
    #
    # Extracts name, tag, material, and bounding box from the entity
    # for full timber vs lumber classification.
    #
    # Result format matches Parser.parse_definition output so scanner.rb
    # can use it as a drop-in replacement.  Extra :ifc_parsed key carries
    # material_type, dimensions, and confidence for downstream use.
    # ═══════════════════════════════════════════════════════════════════

    def self.parse_ifc(inst)
      # Extract attributes from entity
      name = ''
      if inst.respond_to?(:name) && inst.name && !inst.name.empty?
        name = inst.name.to_s.strip
      end
      defn = inst.respond_to?(:definition) ? inst.definition : nil
      defn_name = defn ? defn.name.to_s.strip : ''
      display = name.empty? ? defn_name : name
      tag = (inst.respond_to?(:layer) && inst.layer) ? inst.layer.name : 'Untagged'

      # Material: instance material → face material fallback
      mat = nil
      if inst.respond_to?(:material) && inst.material
        mat = inst.material.display_name
      elsif defn
        begin
          f = defn.entities.grep(Sketchup::Face).first
          mat = f.material.display_name if f && f.material
        rescue; end
      end

      bb = inst.respond_to?(:bounds) ? inst.bounds : nil

      return nil if display.empty? && tag.empty?

      # 1. Hardware / Fasteners (Ø, Bolt, H.A.S. — before timber confuses them)
      result = try_hardware(display, tag)
      return result if result

      # 2. Building material keywords (siding, sheathing, drywall, insulation)
      result = try_building_materials(display)
      return result if result

      # 3. Material override (Steel mat → Steel, before NxN timber grabs it)
      result = try_material_override(display, tag, mat, bb)
      return result if result

      # 4. Engineered lumber (always Structural Lumber)
      result = try_engineered_lumber(display, mat)
      return result if result

      # 5. Timber/Lumber with NxN size (species override: hardwood = always Timber)
      result = try_timber(display, mat, tag)
      return result if result

      # 6. Steel name patterns (W, HSS, L, C, WT, PL)
      result = try_steel(display)
      return result if result

      # 7. Concrete patterns
      result = try_concrete(display)
      return result if result

      # 8. Room-prefixed timber keywords ("Living Rafter", "Dining Jack Rafter")
      result = try_keyword_timber(display, tag, mat, bb)
      return result if result

      # 9. Structural wood by IFC tag + material + bounding box
      result = try_structural_wood(display, tag, mat, bb)
      return result if result

      # 10. IFC tag fallback (medium confidence)
      result = try_ifc_tag(display, tag)
      return result if result

      # No match — return nil, let existing parser handle this entity
      nil
    end

    # ═══════════════════════════════════════════════════════════════════
    # Bulk parse: iterate model, return results + summary
    # ═══════════════════════════════════════════════════════════════════

    def self.parse_model(model)
      return { results: [], summary: {}, ifc_tags: [] } unless model && ifc_model?(model)

      results = []
      ifc_tags = []
      model.layers.each { |l| ifc_tags << l.name if l.name =~ /^Ifc[A-Z]/ }

      model.definitions.each do |defn|
        next if defn.image?
        defn.instances.each do |inst|
          parsed = parse_ifc(inst)
          next unless parsed

          bb = inst.bounds
          tag = inst.layer ? inst.layer.name : 'Untagged'
          longest_ft = [bb.width, bb.height, bb.depth].max / 12.0

          parsed[:entity_id]  = inst.entityID
          parsed[:tag]        = tag
          parsed[:linear_ft]  = longest_ft.round(2)

          # Board feet for timber
          if parsed[:ifc_parsed][:material_type] == 'wood' && parsed[:ifc_parsed][:dimensions]
            dims = parsed[:ifc_parsed][:dimensions]
            w = dims[:width] || 0; h = dims[:height] || 0
            bf = (w * h * longest_ft) / 12.0  # BF = (w_in * h_in * L_ft) / 12
            parsed[:board_feet] = bf.round(2)
          end

          results << parsed
        end
      end

      # Build summary grouped by category → subcategory
      summary = {}
      results.each do |r|
        cat = r[:auto_category]
        sub = r[:auto_subcategory] || 'Other'
        summary[cat] ||= { count: 0, subcategories: {} }
        summary[cat][:count] += 1
        summary[cat][:subcategories][sub] ||= { count: 0 }
        summary[cat][:subcategories][sub][:count] += 1

        if r[:board_feet]
          summary[cat][:subcategories][sub][:total_bf] ||= 0.0
          summary[cat][:subcategories][sub][:total_bf] += r[:board_feet]
        end
        if r[:linear_ft] && cat == 'Structural Steel'
          summary[cat][:subcategories][sub][:total_lf] ||= 0.0
          summary[cat][:subcategories][sub][:total_lf] += r[:linear_ft]
        end
      end

      { results: results, summary: summary, ifc_tags: ifc_tags }
    end

    # ═══════════════════════════════════════════════════════════════════
    # Private parsers
    # ═══════════════════════════════════════════════════════════════════

    private

    # ─── Hardware / Fasteners ─────────────────────────────────────────
    # Catches "5/8"Ø x4" H.A.S.", bolts, dowels, anchors, etc.
    # Runs first because hardware names contain dimension-like patterns
    # that confuse the timber parser.

    def self.try_hardware(name, tag)
      is_hardware = (name =~ HARDWARE_RE) || tag == 'IfcMechanicalFastener'
      return nil unless is_hardware

      {
        raw: name,
        element_type: 'Hardware',
        function: nil,
        material: nil,
        thickness: nil,
        size_nominal: nil,
        revit_id: nil,
        auto_category: 'Hardware',
        auto_subcategory: 'Fasteners',
        measurement_type: 'ea',
        category_source: 'ifc_name',
        ifc_parsed: {
          material_type: 'unknown',
          dimensions: nil,
          confidence: :high
        }
      }
    end

    # ─── Building Materials (keyword scan — runs before dimension patterns) ──

    def self.try_building_materials(name)
      cat = nil
      subcat = nil

      if name =~ SIDING_RE
        cat = 'Siding'
      elsif name =~ CEMENT_BOARD_RE
        cat = 'Sheathing'
        subcat = 'Cement Board'
      elsif name =~ SHEATHING_RE
        cat = 'Sheathing'
      elsif name =~ TNG_RE
        cat = name =~ /Deck/i ? 'Flooring' : 'Siding'
        subcat = 'T&G'
      elsif name =~ DRYWALL_RE
        cat = 'Drywall'
      elsif name =~ INSULATION_RE
        cat = 'Insulation'
      end

      return nil unless cat

      thickness = extract_thickness(name)
      mt = Parser.measurement_for(cat)

      {
        raw: name,
        element_type: cat,
        function: nil,
        material: nil,
        thickness: thickness,
        size_nominal: thickness,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: subcat,
        measurement_type: mt,
        category_source: 'ifc_name',
        ifc_parsed: {
          material_type: 'unknown',
          dimensions: thickness ? { thickness: parse_frac(thickness) } : nil,
          confidence: :high
        }
      }
    end

    # Extract thickness string from name
    def self.extract_thickness(name)
      if name =~ THICKNESS_FRAC_RE
        "#{$1}\""
      elsif name =~ THICKNESS_SIMPLE_RE
        "#{$1}\""
      elsif name =~ THICKNESS_WHOLE_RE
        "#{$1}\""
      else
        nil
      end
    end

    # Parse a fractional string to float inches: "1 1/4" → 1.25, "1/2" → 0.5
    def self.parse_frac(s)
      return 0.0 unless s
      s = s.gsub(/[""″]/, '').strip
      if s =~ /^(\d+)\s+(\d+)\/(\d+)$/
        $1.to_f + ($2.to_f / $3.to_f)
      elsif s =~ /^(\d+)\/(\d+)$/
        $1.to_f / $2.to_f
      else
        s.to_f
      end
    end

    # ─── Material Override (Concrete / Steel) ────────────────────────
    # Concrete: fires on ANY tag (piers on IfcColumn, slabs on IfcSlab, etc.)
    # Steel: skips non-structural tags to avoid grabbing doors/windows.

    def self.try_material_override(name, tag, mat, bb)
      return nil unless mat

      # Rebar / Reinforcement (check before generic concrete)
      if mat =~ REBAR_MAT_RE
        return {
          raw: name,
          element_type: 'Reinforcement',
          function: 'Rebar',
          material: mat,
          thickness: nil,
          size_nominal: nil,
          revit_id: nil,
          auto_category: 'Concrete',
          auto_subcategory: 'Rebar/Reinforcement',
          measurement_type: 'lf',
          category_source: 'material',
          ifc_parsed: {
            material_type: 'steel',
            dimensions: nil,
            confidence: :high
          }
        }
      end

      # Concrete material → Concrete / Foundation (any tag)
      if mat =~ CONCRETE_MAT_RE
        cat = 'Concrete'
        subcat = nil
        FOUNDATION_KW.each do |re, kw_cat, kw_sub|
          if name =~ re
            cat = kw_cat
            subcat = kw_sub
            break
          end
        end
        mt = Parser.measurement_for(cat)

        return {
          raw: name,
          element_type: 'Concrete',
          function: subcat,
          material: mat,
          thickness: nil,
          size_nominal: nil,
          revit_id: nil,
          auto_category: cat,
          auto_subcategory: subcat,
          measurement_type: mt,
          category_source: 'material',
          ifc_parsed: {
            material_type: 'concrete',
            dimensions: nil,
            confidence: :high
          }
        }
      end

      # Steel: skip non-structural tags to avoid grabbing doors/windows
      return nil if NON_STRUCTURAL_TAGS.include?(tag)

      # Steel material → Structural Steel
      if mat =~ STEEL_OVERRIDE_RE
        size_str = nil
        if name =~ TIMBER_FRAC_RE
          size_str = $1.strip
        elsif name =~ TIMBER_SIMPLE_RE
          size_str = $1.strip
        end
        subcat = find_member_type(name)

        return {
          raw: name,
          element_type: 'Steel Member',
          function: subcat,
          material: mat,
          thickness: nil,
          size_nominal: size_str,
          revit_id: nil,
          auto_category: 'Structural Steel',
          auto_subcategory: subcat,
          measurement_type: 'lf',
          category_source: 'material',
          ifc_parsed: {
            material_type: 'steel',
            dimensions: nil,
            confidence: :high
          }
        }
      end

      nil
    end

    # ─── Engineered Lumber (always Structural Lumber) ────────────────

    def self.try_engineered_lumber(name, mat)
      return nil unless name =~ ENGINEERED_RE
      eng_type = $1

      subcat = find_member_type(name) || eng_type

      {
        raw: name,
        element_type: 'Engineered Lumber',
        function: eng_type,
        material: mat,
        thickness: nil,
        size_nominal: nil,
        revit_id: nil,
        auto_category: 'Structural Lumber',
        auto_subcategory: subcat,
        measurement_type: 'ea',
        category_source: 'ifc_name',
        ifc_parsed: {
          material_type: 'wood',
          dimensions: nil,
          confidence: :high
        }
      }
    end

    # ─── Timber / Structural Lumber (NxN size pattern) ───────────────

    # IFC tag → member type fallback when name has no keyword
    IFC_MEMBER_TYPE = {
      'IfcBeam'   => ['Beam', 'Beam'],
      'IfcColumn' => ['Post', 'Post'],
      'IfcMember' => ['Member', 'Beam'],
    }.freeze

    def self.try_timber(name, mat, tag = nil)
      size = nil
      remainder = nil

      # Try fractional pattern first (more specific) — anchored at start
      if name =~ TIMBER_FRAC_RE
        size = $1.strip
        remainder = $2.strip
      elsif name =~ TIMBER_SIMPLE_RE
        size = $1.strip
        remainder = $2.strip
      end

      # If no start-anchored match, try NxN anywhere in name
      # Catches "Dimension Lumber, 8x12", "Rough Sawn Lumber, 10x12", etc.
      if !size && name =~ /(\d+\s*x\s*\d+)/i
        size = $1.strip
        remainder = name.dup
      end

      return nil unless size

      # Multi-word keywords first (highest priority)
      # Search full name (not just remainder) for member type keywords
      search_text = remainder || name
      member_type = nil
      subcat = nil
      if search_text =~ /\bCollar\s*Tie\b/i
        member_type = 'Collar Tie'; subcat = 'Tie'
      elsif search_text =~ /\bRim\s*Board\b/i
        member_type = 'Rim Board'; subcat = 'Joist'
      elsif search_text =~ /\bRim\s*Joist\b/i
        member_type = 'Rim Joist'; subcat = 'Joist'
      else
        # Single-word: find rightmost match in full name
        match_pos = -1
        MEMBER_TYPE_MAP.each do |kw, sub|
          pos = search_text =~ /\b#{kw}\b/i
          if pos && pos >= match_pos
            match_pos = pos
            member_type = kw
            subcat = sub
          end
        end
      end

      # No keyword in name — derive member type from IFC tag
      if !member_type && tag && IFC_MEMBER_TYPE[tag]
        member_type, subcat = IFC_MEMBER_TYPE[tag]
      end

      # Must have either a keyword or IFC tag to classify
      return nil unless member_type

      # "Plate" with known non-wood material → let steel handle it
      if subcat == 'Plate' && mat && mat !~ TIMBER_SPECIES_RE && mat =~ /steel|metal|iron/i
        return nil
      end

      dims = parse_timber_dims(size)
      cat = classify_wood_category(dims, mat)
      mt = cat == 'Timber Frame' ? 'ea_bf' : 'ea'

      {
        raw: name,
        element_type: cat == 'Timber Frame' ? 'Timber Member' : 'Lumber',
        function: member_type,
        material: mat,
        thickness: nil,
        size_nominal: size,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: subcat,
        measurement_type: mt,
        category_source: 'ifc_name',
        ifc_parsed: {
          material_type: 'wood',
          dimensions: dims,
          confidence: :high
        }
      }
    end

    # ─── Steel ────────────────────────────────────────────────────────

    def self.try_steel(name)
      size = nil
      subcat = nil

      case name
      when STEEL_W_RE   then size = $1; subcat = 'W-Shape'
      when STEEL_HSS_RE then size = $1; subcat = 'HSS'
      when STEEL_L_RE   then size = $1; subcat = 'Angle'
      when STEEL_C_RE   then size = $1; subcat = 'Channel'
      when STEEL_WT_RE  then size = $1; subcat = 'Tee'
      when STEEL_PL_RE  then size = $1; subcat = 'Plate'
      end

      return nil unless size

      {
        raw: name,
        element_type: 'Steel Member',
        function: subcat,
        material: nil,
        thickness: nil,
        size_nominal: size.strip,
        revit_id: nil,
        auto_category: 'Structural Steel',
        auto_subcategory: subcat,
        measurement_type: 'lf',
        category_source: 'ifc_name',
        ifc_parsed: {
          material_type: 'steel',
          dimensions: nil,
          confidence: :high
        }
      }
    end

    # ─── Concrete ─────────────────────────────────────────────────────

    def self.try_concrete(name)
      return nil unless name =~ CONCRETE_RE

      thickness = $1
      type_word = $2

      cat = type_word =~ /CMU|Block/i ? 'Masonry / Veneer' : 'Concrete'

      {
        raw: name,
        element_type: 'Concrete',
        function: nil,
        material: type_word,
        thickness: "#{thickness}\"",
        size_nominal: nil,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: nil,
        measurement_type: 'sf_cy',
        category_source: 'ifc_name',
        ifc_parsed: {
          material_type: 'concrete',
          dimensions: { thickness: thickness.to_i },
          confidence: :high
        }
      }
    end

    # ─── Timber keywords anywhere in name (room-prefixed patterns) ────
    # Catches names like "Living Rafter", "Lounge Rafter", "Dining Jack Rafter",
    # "Living Top Chord" where a room/space name precedes a member type keyword.
    # Requires qualifying context: IFC tag, wood material, or wood-sized BB.

    def self.try_keyword_timber(name, tag, mat, bb)
      # Scan name for any timber keyword
      matched_kw = nil
      TIMBER_KEYWORDS.each do |kw|
        if name =~ /\b#{kw}\b/i
          matched_kw = kw
          break
        end
      end
      return nil unless matched_kw

      # At least one qualifying condition must hold
      has_ifc_tag = TIMBER_KEYWORD_TAGS.include?(tag)
      has_wood_mat = mat && mat =~ TIMBER_SPECIES_RE
      has_wood_bb = false
      if bb
        sorted = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort
        # Elongated with reasonable cross-section = likely a structural member
        has_wood_bb = sorted[0] >= 1.0 && sorted[1] >= 1.0 && sorted[2] > sorted[1] * 2
      end

      return nil unless has_ifc_tag || has_wood_mat || has_wood_bb

      # Use find_member_type for richer subcategory (handles Valley, Hip, etc.)
      subcat = find_member_type(name) || matched_kw

      # Classify timber vs lumber using bounding box cross-section
      cat = 'Timber Frame'  # default for keyword-matched timber
      dims = nil
      size_str = nil

      if bb
        sorted = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort
        cross_w = sorted[0]
        cross_h = sorted[1]
        dims = { width: cross_w.round(3), height: cross_h.round(3) }
        size_str = "~#{cross_w.round(1)}x#{cross_h.round(1)}"

        # Hardwood species = ALWAYS Timber Frame regardless of size
        if has_wood_mat
          cat = 'Timber Frame'
        elsif cross_w >= 5.5 && cross_h >= 5.5
          cat = 'Timber Frame'
        elsif cross_w >= 1.0
          cat = 'Structural Lumber'
        end
      end

      mt = cat == 'Timber Frame' ? 'ea_bf' : 'ea'

      {
        raw: name,
        element_type: cat == 'Timber Frame' ? 'Timber Member' : 'Lumber',
        function: matched_kw,
        material: mat,
        thickness: nil,
        size_nominal: size_str,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: subcat,
        measurement_type: mt,
        category_source: has_ifc_tag ? 'ifc_name' : 'ifc_tag',
        ifc_parsed: {
          material_type: 'wood',
          dimensions: dims,
          confidence: has_ifc_tag ? :high : :medium
        }
      }
    end

    # ─── Structural Wood (IFC tag + material + bounding box) ─────────
    # For names without NxN size prefix (e.g. "Living Valley", "Hip Rafter")
    # that are on structural IFC tags with wood material.

    def self.try_structural_wood(name, tag, mat, bb)
      return nil unless STRUCTURAL_IFC_TAGS.include?(tag)
      return nil unless mat && mat =~ TIMBER_SPECIES_RE

      subcat = find_member_type(name) || tag.sub(/^Ifc/, '')

      # Material already confirmed as timber species — ALWAYS Timber Frame
      cat = 'Timber Frame'
      dims = nil
      size_str = nil

      if bb
        sorted = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort
        cross_w = sorted[0]
        cross_h = sorted[1]
        dims = { width: cross_w.round(3), height: cross_h.round(3) }
        size_str = "~#{cross_w.round(1)}x#{cross_h.round(1)}"
      end

      mt = cat == 'Timber Frame' ? 'ea_bf' : 'ea'

      {
        raw: name,
        element_type: cat == 'Timber Frame' ? 'Timber Member' : 'Lumber',
        function: subcat,
        material: mat,
        thickness: nil,
        size_nominal: size_str,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: subcat,
        measurement_type: mt,
        category_source: 'ifc_tag',
        ifc_parsed: {
          material_type: 'wood',
          dimensions: dims,
          confidence: :medium
        }
      }
    end

    # ─── IFC tag fallback ─────────────────────────────────────────────

    def self.try_ifc_tag(name, tag)
      return nil unless tag =~ /^Ifc[A-Z]/

      cat = IFC_TAG_MAP[tag]
      return nil unless cat

      mt = Parser.measurement_for(cat)

      {
        raw: name,
        element_type: tag.sub(/^Ifc/, ''),
        function: nil,
        material: nil,
        thickness: nil,
        size_nominal: nil,
        revit_id: nil,
        auto_category: cat,
        auto_subcategory: nil,
        measurement_type: mt,
        category_source: 'ifc_tag',
        ifc_parsed: {
          material_type: 'unknown',
          dimensions: nil,
          confidence: :medium
        }
      }
    end

    # ─── Helpers ─────────────────────────────────────────────────────

    # Find a structural member type keyword in text.
    # Checks multi-word patterns first, then single-word (rightmost match).
    # Returns the subcategory string, or nil.
    def self.find_member_type(text)
      # Multi-word patterns (highest priority)
      return 'Tie'   if text =~ /\bCollar\s*Tie\b/i
      return 'Joist' if text =~ /\bRim\s*Board\b/i
      return 'Joist' if text =~ /\bRim\s*Joist\b/i

      # Single-word: rightmost match wins
      best_sub = nil
      best_pos = -1
      MEMBER_TYPE_MAP.each do |kw, sub|
        pos = text =~ /\b#{kw}\b/i
        if pos && pos >= best_pos
          best_pos = pos
          best_sub = sub
        end
      end
      best_sub
    end

    # Classify as "Timber Frame" or "Structural Lumber" based on material + dims.
    #   Hardwood species (Oak, Cedar, etc.) → ALWAYS Timber Frame regardless of size
    #   Both dims >= 6"  → Timber Frame
    #   Everything else  → Structural Lumber
    def self.classify_wood_category(dims, mat)
      # Hardwood species = ALWAYS Timber, even 2x4 Oak is timber
      return 'Timber Frame' if mat && mat =~ TIMBER_SPECIES_RE

      return 'Structural Lumber' unless dims

      w = dims[:width] || 0
      h = dims[:height] || 0
      min_d = [w, h].min

      # Both >= 6" → Timber
      return 'Timber Frame' if min_d >= 6

      # Everything else → Structural Lumber
      'Structural Lumber'
    end

    def self.parse_timber_dims(size_str)
      # Fractional: "2 5/8"t x10"
      if size_str =~ /^(\d+)\s+(\d+)\/(\d+)[""″]?t?\s*x\s*(\d+)/i
        w = $1.to_f + ($2.to_f / $3.to_f)
        h = $4.to_f
        return { width: w.round(3), height: h }
      end

      # Simple: "18x18", "16x24"t"
      if size_str =~ /^(\d+)\s*x\s*(\d+)/i
        return { width: $1.to_f, height: $2.to_f }
      end

      nil
    end

  end
end
