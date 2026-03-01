module TakeoffTool
  module Parser

    TAG_CATEGORY_MAP = {
      'Walls' => 'Walls', 'Roofs' => 'Roofing', 'Structural Framing' => 'Structural Lumber',
      'Structural Columns' => 'Structural Lumber', 'Floors' => 'Flooring',
      'Windows' => 'Windows', 'Doors' => 'Doors', 'Casework' => 'Casework',
      'Ceilings' => 'Ceilings', 'Fascias' => 'Fascia', 'Generic Models' => 'Generic Models',
      'Plumbing Fixtures' => 'Plumbing',
      'Specialty Equipment' => 'Specialty Equipment',
      'Structural Foundations' => 'Concrete',
      'Furniture' => 'Furniture',
      'Lighting Fixtures' => 'Lighting Fixtures',
      'Electrical Fixtures' => 'Electrical Fixtures',
      'Electrical Equipment' => 'Electrical Equipment',
      'Railings' => 'Railings',
      'Stairs' => 'Stairs',
      'Rooms' => 'Rooms',
    }

    # v5 Measurement types:
    #   sf       = square feet (primary only)
    #   cy       = cubic yards
    #   sf_cy    = SF primary + CY secondary
    #   bf       = board feet
    #   ea       = each (count)
    #   ea_bf    = EA primary + BF secondary
    #   ea_sf    = EA primary + SF glass secondary (windows)
    #   lf       = linear feet
    #   sf_sheets = SF primary + sheet count secondary (sheathing)
    #   volume   = ft³ fallback
    CATEGORY_MEASUREMENTS = {
      'Casework'          => 'lf',
      'Countertops'       => 'lf',
      'Concrete'          => 'sf_cy',
      'Ceilings'          => 'sf',
      'Doors'             => 'ea',
      'Windows'           => 'ea_sf',
      'Structural Lumber' => 'ea_bf',
      'Metal Roofing'     => 'sf',
      'Shingle Roofing'   => 'sf',
      'Roofing'           => 'sf',
      'Roof Sheathing'    => 'sf_sheets',
      'Roof Framing'      => 'ea_bf',
      'Drywall'           => 'sf',
      'Trim'              => 'lf',
      'Fascia'            => 'lf',
      'Gutters'           => 'lf',
      'Flashing'          => 'lf',
      'Baseboard'         => 'lf',
      'Crown Mold'        => 'lf',
      'Casing'            => 'lf',
      'Railing'           => 'lf',
      'Drip Edge'         => 'lf',
      'Soffit'            => 'sf',
      'Masonry / Veneer'  => 'sf',
      'Siding'            => 'sf',
      'Exterior Finish'   => 'sf',
      'Wall Framing'      => 'sf',
      'Wall Finish'       => 'sf',
      'Wall Structure'    => 'sf',
      'Wall Sheathing'    => 'sf_sheets',
      'Insulation'        => 'sf',
      'Membrane'          => 'sf',
      'Flooring'          => 'sf',
      'Tile'              => 'sf',
      'Backsplash'        => 'sf',
      'Shower Walls'      => 'sf',
      'Plumbing'          => 'ea',
      'Hardware'          => 'ea',
      'Generic Models'    => 'ea',
      'Uncategorized'     => 'volume',
      'Walls'             => 'sf',
      'Lighting Fixtures'    => 'ea',
      'Furniture'            => 'ea',
      'Appliances'           => 'ea',
      'Electrical Equipment' => 'ea',
      'Electrical Fixtures'  => 'ea',
      'Railings'             => 'lf',
      'Stairs'               => 'ea',
      'Specialty Equipment'  => 'ea',
      'Rooms'                => 'sf',
      'Structural Foundations' => 'sf_cy',
      'Decorative Metal'     => 'lf',
      'Glass/Glazing'        => 'sf',
      'Stucco'               => 'sf',
      'Wood Paneling'        => 'sf',
      'Foundation Slabs'     => 'sf_cy',
      'Foundation Walls'     => 'sf_cy',
      'Foundation Footings'  => 'lf',
      'HVAC'                 => 'ea',
      'Snow Guards'          => 'lf',
      'Bath Accessories'     => 'ea',
      'Outdoor Kitchen'      => 'ea',
      'Chimney'              => 'ea',
      'Structural Steel'     => 'lf',
      'Timber Frame'         => 'ea_bf',
      'Ceiling Framing'      => 'sf',
      'Shower Doors'         => 'ea',
      'Garage Doors'         => 'ea',
      'Sheathing'            => 'sf_sheets',
      'Window Treatments'    => 'ea',
      'Outdoor Features'     => 'ea',
    }

    def self.measurement_for(category)
      CATEGORY_MEASUREMENTS[category] || 'volume'
    end

    def self.parse_definition(name, tag = nil, material: nil, ifc_type: nil)
      r = { raw: name || '', element_type: nil, function: nil, material: nil,
            thickness: nil, size_nominal: nil, revit_id: nil,
            auto_category: nil, auto_subcategory: nil,
            measurement_type: nil, category_source: nil }

      if name.nil? || name.empty?
        cat = tag_fb(tag)
        return r.merge(auto_category: cat, measurement_type: measurement_for(cat), category_source: 'tag')
      end

      parts = name.split(',').map(&:strip)
      r[:revit_id] = parts.pop if parts.last && parts.last.match?(/^[0-9A-Fa-f]+$/)
      rem = parts.join(', ')

      # ─── Basic Wall ───
      if rem =~ /^Basic Wall,?\s*(.*)/i
        r[:element_type] = 'Basic Wall'
        d = $1.strip
        r[:category_source] = 'name'
        if d =~ /^Framing\s*-\s*(.*)/i
          r[:function]='Framing'; r[:thickness]=xdim($1)
          r[:auto_category]='Wall Framing'
          r[:auto_subcategory] = r[:thickness]
        elsif d =~ /^Finish\s*-\s*(.*)/i
          r[:function]='Finish'; det=$1.strip
          if det =~ /Gypsum|GYP|Drywall/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Drywall'
          elsif det =~ /Stucco/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Stucco'
            r[:auto_subcategory]='Exterior'
          elsif det =~ /Metal\s*Panel/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Decorative Metal'
            r[:auto_subcategory]='Wall Panel'
          elsif det =~ /Glass|GLASS/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Glass/Glazing'
            r[:auto_subcategory]='Wall'
          elsif det =~ /Wood\s*Panel|woodl?\s*Panel/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Wood Paneling'
            r[:auto_subcategory]='Wall'
          elsif det =~ /Stone\s*Veneer|Slab\s*Stone/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Masonry / Veneer'
            r[:auto_subcategory] = det =~ /WAINSCOT/i ? 'Wainscot' : 'Exterior'
          elsif det =~ /Stone|Veneer|Brick|Masonry|CMU/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Masonry / Veneer'
          elsif det =~ /Siding|Lap|Hardie/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Siding'
          elsif det =~ /Soffit/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Soffit'
          else
            r[:material]=xmat(det); r[:thickness]=xdim(det)
            r[:auto_category] = det =~ /Exterior/i ? 'Exterior Finish' : 'Wall Finish'
          end
        elsif d =~ /^Foundation\s*-\s*(.*)/i
          r[:function]='Foundation'; r[:material]=xmat($1); r[:thickness]=xdim($1)
          if d =~ /Concrete/i
            r[:auto_category]='Foundation Walls'
            r[:auto_subcategory]='Concrete'
            r[:thickness] ||= xthick_inch(d)
          else
            r[:auto_category]='Wall Structure'
          end
        elsif d =~ /^(Structure|Core)\s*-\s*(.*)/i
          r[:function]=$1; r[:material]=xmat($2); r[:thickness]=xdim($2); r[:auto_category]='Wall Structure'
        elsif d =~ /Sheathing|Plywood|OSB/i
          r[:function]='Sheathing'; r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Wall Sheathing'
        elsif d =~ /^Insulation/i
          r[:function]='Insulation'; r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Insulation'
        elsif d =~ /^Membrane|^Substrate/i
          r[:function]='Membrane'; r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Membrane'
        elsif d =~ /Stucco/i
          r[:material]=xmat(d); r[:auto_category]='Stucco'; r[:auto_subcategory]='Exterior'
        elsif d =~ /Metal\s*Panel/i
          r[:material]=xmat(d); r[:auto_category]='Decorative Metal'; r[:auto_subcategory]='Wall Panel'
        elsif d =~ /Glass|GLASS/i
          r[:material]=xmat(d); r[:auto_category]='Glass/Glazing'; r[:auto_subcategory]='Wall'
        elsif d =~ /Wood\s*Panel|woodl?\s*Panel/i
          r[:material]=xmat(d); r[:auto_category]='Wood Paneling'; r[:auto_subcategory]='Wall'
        elsif d =~ /Stone\s*Veneer|Slab\s*Stone/i
          r[:material]=xmat(d); r[:auto_category]='Masonry / Veneer'
          r[:auto_subcategory] = d =~ /WAINSCOT/i ? 'Wainscot' : 'Exterior'
        elsif d =~ /J-Wall\s+Ext\s+Stone/i
          r[:material]=xmat(d); r[:auto_category]='Masonry / Veneer'; r[:auto_subcategory]='Exterior'
        elsif d =~ /J-Wall\s+Int\s+Stud/i
          r[:material]=xmat(d); r[:auto_category]='Wall Framing'; r[:auto_subcategory]='Interior'
        else
          r[:material]=d; r[:auto_category]='Walls'
        end

      # ─── Basic Roof ───
      elsif rem =~ /^Basic Roof,?\s*(.*)/i
        r[:element_type]='Basic Roof'; d=$1.strip
        r[:category_source] = 'name'
        if d =~ /^Finish\s*-\s*(.*)/i
          r[:function]='Finish'; det=$1.strip; r[:material]=xmat(det); r[:thickness]=xdim(det)
          r[:auto_category] = det=~/Standing Seam|Metal/i ? 'Metal Roofing' : det=~/Shingle|Asphalt/i ? 'Shingle Roofing' : 'Roofing'
        elsif d =~ /Sheathing|Plywood|OSB/i
          r[:function]='Sheathing'; r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Roof Sheathing'
        elsif d =~ /Framing|Structure/i
          r[:function]='Framing'; r[:thickness]=xdim(d); r[:auto_category]='Roof Framing'
        else
          r[:material]=d; r[:auto_category]='Roofing'
        end

      # ─── Compound Ceiling ───
      elsif rem =~ /^Compound Ceiling,?\s*(.*)/i
        r[:element_type]='Ceiling'; d=$1.strip
        r[:category_source] = 'name'
        if d =~ /Gypsum|GYP|Drywall/i
          r[:material]=xmat(d); r[:thickness]=xdim(d)
          r[:auto_category]='Drywall'; r[:auto_subcategory]='Ceiling Drywall'
        elsif d =~ /Framing/i
          r[:thickness]=xdim(d)
          r[:auto_category]='Ceiling Framing'; r[:auto_subcategory]=r[:thickness]
        elsif d =~ /Metal\s*Panel/i
          r[:material]=xmat(d); r[:auto_category]='Decorative Metal'; r[:auto_subcategory]='Ceiling'
        elsif d =~ /Sheathing|Plywood/i
          r[:material]=xmat(d); r[:thickness]=xdim(d)
          r[:auto_category]='Sheathing'; r[:auto_subcategory]='Ceiling'
        elsif d =~ /WD|Wood\s*Board/i
          r[:material]=xmat(d); r[:auto_category]='Wood Paneling'; r[:auto_subcategory]='Ceiling'
        elsif d =~ /TILE|Tile\s+over\s+Cement/i
          r[:material]=xmat(d); r[:auto_category]='Tile'; r[:auto_subcategory]='Ceiling Tile'
        elsif d =~ /STONE\s*VENEER/i
          r[:material]=xmat(d); r[:auto_category]='Masonry / Veneer'; r[:auto_subcategory]='Ceiling'
        elsif d =~ /Dec\.?\s*Finish/i
          r[:material]=xmat(d); r[:auto_category]='Ceilings'; r[:auto_subcategory]='Decorative'
        else
          r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Ceilings'
        end

      # ─── Foundation Slab ───
      elsif rem =~ /Foundation Slab/i
        r[:element_type]='Foundation Slab'; r[:category_source]='name'
        r[:material]=xmat(rem); r[:thickness]=xdim(rem) || xthick_inch(rem)
        r[:auto_category]='Foundation Slabs'

      # ─── Wall Foundation (footings) ───
      elsif rem =~ /Wall Foundation/i
        r[:element_type]='Wall Foundation'; r[:category_source]='name'
        r[:material]=xmat(rem); r[:thickness]=xdim(rem) || xthick_inch(rem)
        r[:auto_category]='Foundation Footings'

      # ─── Floor ───
      elsif rem =~ /^Basic Floor|^Floor/i
        r[:element_type]='Basic Floor'; d=rem.sub(/^Basic Floor,?\s*|^Floor,?\s*/i,'')
        r[:material]=xmat(d); r[:thickness]=xdim(d)
        r[:auto_category] = d=~/Concrete|Slab/i ? 'Concrete' : 'Flooring'
        r[:category_source] = 'name'

      # ─── Lumber ───
      elsif rem =~ /Rough Sawn Lumber|Dimensional Lumber|Lumber/i
        r[:element_type]='Lumber'; r[:material]=xmat(rem); r[:size_nominal]=xlum(rem)
        r[:auto_category]='Structural Lumber'
        r[:category_source] = 'name'

      # ─── Structural Members ───
      elsif rem =~ /^Brace|^Beam|^Joist|^Rafter|^Purlin|^Girder|^Truss/i
        r[:element_type]='Structural Member'; r[:material]=xmat(rem); r[:size_nominal]=xlum(rem)
        r[:auto_category]='Structural Lumber'
        r[:category_source] = 'name'

      # ─── Casework/Countertops ───
      elsif rem =~ /Counter\s*Top|Countertop/i
        r[:element_type]='Countertop'; r[:material]=xmat(rem); r[:auto_category]='Countertops'
        r[:category_source] = 'name'
      elsif rem =~ /Cabinet|Cab\s|Casework|Vanit/i
        r[:element_type]='Casework'; r[:material]=xmat(rem); r[:auto_category]='Casework'
        r[:category_source] = 'name'

      # ─── Doors ───
      elsif rem =~ /^Door/i || tag == 'Doors'
        r[:element_type]='Door'; r[:material]=xmat(rem)
        r[:size_nominal]=xdoor_size(rem)
        r[:auto_category]='Doors'
        r[:category_source] = 'name'
        # Subcategory from keywords
        if rem =~ /Garage/i
          r[:auto_category]='Garage Doors'; r[:auto_subcategory]='Garage'
        elsif rem =~ /Shower/i
          r[:auto_category]='Shower Doors'; r[:auto_subcategory]='Shower'
        elsif rem =~ /Exterior/i
          r[:auto_subcategory]='Exterior'
        elsif rem =~ /Interior/i
          r[:auto_subcategory]='Interior'
        elsif rem =~ /Casement.*DOOR|DOOR.*Casement/i
          r[:auto_subcategory]='Casement'
        elsif rem =~ /Bypass/i
          r[:auto_subcategory]='Bypass'
        elsif rem =~ /Pocket/i
          r[:auto_subcategory]='Pocket'
        elsif rem =~ /Cased\s*Opening/i
          r[:auto_subcategory]='Cased Opening'
        end

      # ─── Windows ───
      elsif rem =~ /^Window/i || tag == 'Windows'
        r[:element_type]='Window'; r[:material]=xmat(rem)
        r[:size_nominal]=xwin_size(rem)
        r[:auto_category]='Windows'
        r[:category_source] = 'name'

      # ─── Plumbing Fixtures ───
      elsif rem =~ /Toilet|Sink|Faucet|Shower|Tub|Lavatory|Urinal/i || tag == 'Plumbing Fixtures'
        r[:element_type]='Plumbing Fixture'; r[:material]=xmat(rem)
        r[:auto_category]='Plumbing'
        r[:category_source] = 'name'

      # ─── Fascia ───
      elsif rem =~ /Fascia/i || tag == 'Fascias'
        r[:element_type]='Fascia'; r[:material]=xmat(rem); r[:auto_category]='Fascia'
        r[:category_source] = 'name'

      # ─── Soffit ───
      elsif rem =~ /Soffit/i
        r[:element_type]='Soffit'; r[:material]=xmat(rem); r[:auto_category]='Soffit'
        r[:category_source] = 'name'

      # ─── Trim ───
      elsif rem =~ /Trim|Molding|Moulding|Baseboard|Crown|Casing/i
        r[:element_type]='Trim'; r[:material]=xmat(rem); r[:auto_category]='Trim'
        r[:category_source] = 'name'

      # ─── Tile (standalone) ───
      elsif rem =~ /\bTile\b/i
        r[:element_type]='Tile'; r[:material]=xmat(rem); r[:auto_category]='Tile'
        r[:auto_subcategory] = tag if tag
        r[:category_source] = 'name'

      # ─── Datum/Ignore ───
      elsif rem =~ /^T\.O\.|^B\.O\.|^Level|^Datum|S\.F\./i
        r[:auto_category]='_IGNORE'; r[:measurement_type]='none'; return r

      # ─── Fallback ───
      else
        r[:element_type]='Unknown'; r[:material]=rem
        tag_cat = tag_fb(tag)

        # Specialty Equipment sub-parsing
        if tag == 'Specialty Equipment'
          r[:category_source] = 'name'
          if rem =~ /Appliance|Range|Refrigerator|Dishwasher|Washer|Dryer|REF\b/i
            r[:auto_category]='Appliances'
          elsif rem =~ /Bath.?Accessor|Towel/i
            r[:auto_category]='Bath Accessories'
          elsif rem =~ /J-App\s+Grill|Hasty.?Bake/i
            r[:auto_category]='Outdoor Kitchen'
          elsif rem =~ /Chimney\s*Cap|Chimney/i
            r[:auto_category]='Chimney'
          else
            r[:auto_category]='Specialty Equipment'
            r[:category_source] = 'tag'
          end

        # Generic Models keyword rescue
        elsif tag == 'Generic Models'
          if rem =~ /AC.?Condenser|Condenser/i
            r[:auto_category]='HVAC'; r[:category_source]='name'
          elsif rem =~ /Snow\s*Guard/i
            r[:auto_category]='Snow Guards'; r[:category_source]='name'
          elsif rem =~ /Pendant\s*Light|PENDANT|Chandelier/i
            r[:auto_category]='Lighting Fixtures'; r[:category_source]='name'
          elsif rem =~ /\bLight\b/i && !(rem =~ /Light\s*Switch/i)
            r[:auto_category]='Lighting Fixtures'; r[:category_source]='name'
          elsif rem =~ /Fire\s*pit|Fire\s*Pit/i
            r[:auto_category]='Outdoor Features'; r[:category_source]='name'
          elsif rem =~ /Ceiling\s*Pocket|Shade|Lutron/i
            r[:auto_category]='Window Treatments'; r[:category_source]='name'
          else
            r[:auto_category]=tag_cat; r[:category_source]='tag'
          end

        # Furniture tag
        elsif tag == 'Furniture'
          r[:auto_category]='Furniture'; r[:category_source]='tag'

        # Lighting Fixtures tag
        elsif tag == 'Lighting Fixtures'
          r[:auto_category]='Lighting Fixtures'; r[:category_source]='tag'

        # Electrical tags
        elsif tag == 'Electrical Fixtures'
          r[:auto_category]='Electrical Fixtures'; r[:category_source]='tag'
        elsif tag == 'Electrical Equipment'
          r[:auto_category]='Electrical Equipment'; r[:category_source]='tag'

        # Railings / Stairs tags
        elsif tag == 'Railings'
          r[:auto_category]='Railings'; r[:category_source]='tag'
        elsif tag == 'Stairs'
          r[:auto_category]='Stairs'; r[:category_source]='tag'

        # Rooms tag
        elsif tag == 'Rooms'
          r[:auto_category]='Rooms'; r[:category_source]='tag'

        else
          r[:auto_category]=tag_cat
          r[:category_source] = tag_cat == 'Uncategorized' ? nil : 'tag'
        end
      end

      r[:auto_category] ||= tag_fb(tag)

      # ─── Material-based secondary classification (priority 3) ───
      if material && generic_category?(r[:auto_category])
        mat_cat, mat_sub = classify_by_material(r[:auto_category], material)
        if mat_cat
          r[:auto_category] = mat_cat
          r[:auto_subcategory] ||= mat_sub
          r[:category_source] = 'material'
        end
      end

      # ─── IFC type-based tertiary classification (priority 4) ───
      if ifc_type && generic_category?(r[:auto_category])
        ifc_cat = classify_by_ifc(ifc_type)
        if ifc_cat
          r[:auto_category] = ifc_cat
          r[:category_source] = 'ifc'
        end
      end

      r[:measurement_type] = measurement_for(r[:auto_category])
      r
    end

    def self.tag_fb(tag)
      return 'Uncategorized' unless tag
      TAG_CATEGORY_MAP[tag] || tag
    end

    # ─── Material-based Classification ───

    GENERIC_CATEGORIES = ['Ceilings', 'Structural Lumber', 'Generic Models', 'Uncategorized', 'Walls'].freeze

    def self.generic_category?(cat)
      GENERIC_CATEGORIES.include?(cat)
    end

    def self.classify_by_material(current_cat, material)
      return nil unless material
      m = material.to_s
      case current_cat
      when 'Structural Lumber'
        if m =~ /Steel|Metal/i && !(m =~ /Metal\s*Siding/i)
          return ['Structural Steel', nil]
        end
      when 'Ceilings'
        if m =~ /Gypsum|Drywall/i
          return ['Drywall', 'Ceiling Drywall']
        elsif m =~ /Framing|Lumber/i
          return ['Ceiling Framing', nil]
        elsif m =~ /Metal/i
          return ['Decorative Metal', 'Ceiling']
        end
      end
      nil
    end

    IFC_CATEGORY_MAP = {
      'IfcSpace' => 'Rooms',
      'IfcSanitaryTerminal' => 'Plumbing',
      'IfcStair' => 'Stairs',
      'IfcRailing' => 'Railings',
      'IfcWindow' => 'Windows',
      'IfcDoor' => 'Doors',
    }

    def self.classify_by_ifc(ifc_type)
      return nil unless ifc_type
      IFC_CATEGORY_MAP[ifc_type.to_s]
    end

    # ─── Extraction Helpers ───

    def self.xdim(s)
      return nil unless s
      s=~/([\d]+[\-\s]?\d*\/?\d*)\s*["″]/ ? $1.strip : s=~/([\d]+'[\s]*-?[\s]*\d*[\-\s]?\d*\/?\d*)\s*["″]?/ ? $1.strip : nil
    end

    def self.xmat(s)
      return nil unless s
      c=s.dup; c.gsub!(/\d+[\-\s]?\d*\/?\d*\s*["″]/,''); c.gsub!(/w\s+\d+.*$/,''); c.gsub!(/\s*-\s*$/,''); c.strip!
      c=~(/^[A-Z]{2,4}\s*-\s*[A-Z0-9]+\s*-\s*(.*)/) ? $1.strip : (c.empty? ? nil : c)
    end

    def self.xlum(s)
      return nil unless s
      s=~/(\d+\s*x\s*\d+)/i ? $1.gsub(/\s/,'') : nil
    end

    def self.xdoor_size(s)
      return nil unless s
      if s =~ /(\d+['-]\s*\d*["-]?\s*x\s*\d+['-]\s*\d*["-]?)/i
        return $1.strip
      end
      nil
    end

    def self.xwin_size(s)
      return nil unless s
      if s =~ /(\d+['-]\s*\d*["-]?\s*x\s*\d+['-]\s*\d*["-]?)/i
        return $1.strip
      end
      nil
    end

    def self.xthick_inch(s)
      return nil unless s
      s =~ /(\d+)\s*inch/i ? "#{$1}\"" : nil
    end

    def self.dim_to_in(d)
      return nil unless d
      return ($1.to_f*12)+frac($2) if d=~/(\d+)'\s*-?\s*(\d+[\-\s]?\d*\/?\d*)/
      frac(d)
    end

    def self.frac(s)
      return 0.0 unless s; s=s.strip
      return $1.to_f+($2.to_f/$3.to_f) if s=~/^(\d+)[\s\-]+(\d+)\/(\d+)$/
      return $1.to_f/$2.to_f if s=~/^(\d+)\/(\d+)$/
      s.to_f
    end
  end
end
