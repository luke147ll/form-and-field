module TakeoffTool
  module Parser

    TAG_CATEGORY_MAP = {
      'Walls' => 'Walls', 'Roofs' => 'Roofing', 'Structural Framing' => 'Structural Lumber',
      'Structural Columns' => 'Structural Lumber', 'Floors' => 'Flooring',
      'Windows' => 'Windows', 'Doors' => 'Doors', 'Casework' => 'Casework',
      'Ceilings' => 'Ceilings', 'Fascias' => 'Fascia', 'Generic Models' => 'Generic Models',
      'Plumbing Fixtures' => 'Plumbing',
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
    }

    def self.measurement_for(category)
      CATEGORY_MEASUREMENTS[category] || 'volume'
    end

    def self.parse_definition(name, tag = nil)
      r = { raw: name || '', element_type: nil, function: nil, material: nil,
            thickness: nil, size_nominal: nil, revit_id: nil,
            auto_category: nil, measurement_type: nil }

      if name.nil? || name.empty?
        cat = tag_fb(tag)
        return r.merge(auto_category: cat, measurement_type: measurement_for(cat))
      end

      parts = name.split(',').map(&:strip)
      r[:revit_id] = parts.pop if parts.last && parts.last.match?(/^[0-9A-Fa-f]+$/)
      rem = parts.join(', ')

      # ─── Basic Wall ───
      if rem =~ /^Basic Wall,?\s*(.*)/i
        r[:element_type] = 'Basic Wall'
        d = $1.strip
        if d =~ /^Framing\s*-\s*(.*)/i
          r[:function]='Framing'; r[:thickness]=xdim($1)
          r[:auto_category]='Wall Framing'
        elsif d =~ /^Finish\s*-\s*(.*)/i
          r[:function]='Finish'; det=$1.strip
          if det =~ /Gypsum|GYP|Drywall/i
            r[:material]=xmat(det); r[:thickness]=xdim(det); r[:auto_category]='Drywall'
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
          r[:auto_category] = d =~ /Concrete/i ? 'Concrete' : 'Wall Structure'
        elsif d =~ /^(Structure|Core)\s*-\s*(.*)/i
          r[:function]=$1; r[:material]=xmat($2); r[:thickness]=xdim($2); r[:auto_category]='Wall Structure'
        elsif d =~ /^Sheathing|^Substrate.*Plywood|^Substrate.*OSB/i
          r[:function]='Sheathing'; r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Wall Sheathing'
        elsif d =~ /^Insulation/i
          r[:function]='Insulation'; r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Insulation'
        elsif d =~ /^Membrane|^Substrate/i
          r[:function]='Membrane'; r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Membrane'
        else
          r[:material]=d; r[:auto_category]='Walls'
        end

      # ─── Basic Roof ───
      elsif rem =~ /^Basic Roof,?\s*(.*)/i
        r[:element_type]='Basic Roof'; d=$1.strip
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
        r[:material]=xmat(d); r[:thickness]=xdim(d); r[:auto_category]='Ceilings'

      # ─── Floor ───
      elsif rem =~ /^Basic Floor|^Floor/i
        r[:element_type]='Basic Floor'; d=rem.sub(/^Basic Floor,?\s*|^Floor,?\s*/i,'')
        r[:material]=xmat(d); r[:thickness]=xdim(d)
        r[:auto_category] = d=~/Concrete|Slab/i ? 'Concrete' : 'Flooring'

      # ─── Lumber ───
      elsif rem =~ /Rough Sawn Lumber|Dimensional Lumber|Lumber/i
        r[:element_type]='Lumber'; r[:material]=xmat(rem); r[:size_nominal]=xlum(rem)
        r[:auto_category]='Structural Lumber'

      # ─── Structural Members ───
      elsif rem =~ /^Brace|^Beam|^Joist|^Rafter|^Purlin|^Girder|^Truss/i
        r[:element_type]='Structural Member'; r[:material]=xmat(rem); r[:size_nominal]=xlum(rem)
        r[:auto_category]='Structural Lumber'

      # ─── Casework/Countertops ───
      elsif rem =~ /Counter\s*Top|Countertop/i
        r[:element_type]='Countertop'; r[:material]=xmat(rem); r[:auto_category]='Countertops'
      elsif rem =~ /Cabinet|Cab\s|Casework|Vanit/i
        r[:element_type]='Casework'; r[:material]=xmat(rem); r[:auto_category]='Casework'

      # ─── Doors ───
      elsif rem =~ /^Door/i || tag == 'Doors'
        r[:element_type]='Door'; r[:material]=xmat(rem)
        r[:size_nominal]=xdoor_size(rem)
        r[:auto_category]='Doors'

      # ─── Windows ───
      elsif rem =~ /^Window/i || tag == 'Windows'
        r[:element_type]='Window'; r[:material]=xmat(rem)
        r[:size_nominal]=xwin_size(rem)
        r[:auto_category]='Windows'

      # ─── Plumbing Fixtures ───
      elsif rem =~ /Toilet|Sink|Faucet|Shower|Tub|Lavatory|Urinal/i || tag == 'Plumbing Fixtures'
        r[:element_type]='Plumbing Fixture'; r[:material]=xmat(rem)
        r[:auto_category]='Plumbing'

      # ─── Fascia ───
      elsif rem =~ /Fascia/i || tag == 'Fascias'
        r[:element_type]='Fascia'; r[:material]=xmat(rem); r[:auto_category]='Fascia'

      # ─── Soffit ───
      elsif rem =~ /Soffit/i
        r[:element_type]='Soffit'; r[:material]=xmat(rem); r[:auto_category]='Soffit'

      # ─── Trim ───
      elsif rem =~ /Trim|Molding|Moulding|Baseboard|Crown|Casing/i
        r[:element_type]='Trim'; r[:material]=xmat(rem); r[:auto_category]='Trim'

      # ─── Datum/Ignore ───
      elsif rem =~ /^T\.O\.|^B\.O\.|^Level|^Datum|S\.F\./i
        r[:auto_category]='_IGNORE'; r[:measurement_type]='none'; return r

      # ─── Fallback ───
      else
        r[:element_type]='Unknown'; r[:material]=rem; r[:auto_category]=tag_fb(tag)
      end

      r[:auto_category] ||= tag_fb(tag)
      r[:measurement_type] = measurement_for(r[:auto_category])
      r
    end

    def self.tag_fb(tag)
      return 'Uncategorized' unless tag
      TAG_CATEGORY_MAP[tag] || tag
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
      # Try to extract door dimensions like 3'-0" x 6'-8" or 36x80
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
