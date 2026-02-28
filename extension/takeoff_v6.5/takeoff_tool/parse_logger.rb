module TakeoffTool
  module ParseLogger

    def self.generate(scan_results, entity_registry, category_assignments, cost_code_assignments)
      require 'json'

      # Load cost code mappings
      ccm = {}
      begin
        p = File.join(PLUGIN_DIR, 'config', 'cost_codes.json')
        if File.exist?(p)
          d = JSON.parse(File.read(p))
          ccm = d['category_to_cost_code'] || {}
        end
      rescue => e
        puts "ParseLogger: cost code load error: #{e.message}"
      end

      model = Sketchup.active_model
      model_name = model ? (model.path.empty? ? 'Untitled' : File.basename(model.path)) : 'No model'

      entries = []
      scan_results.each do |r|
        eid = r[:entity_id]
        e = entity_registry[eid]
        entries << build_entry(r, e, category_assignments, cost_code_assignments, ccm)
      end

      summary = build_summary(entries, scan_results, model_name)

      desktop = File.join(ENV['USERPROFILE'] || Dir.home, 'Desktop')
      unless File.directory?(desktop)
        desktop = Dir.home
      end
      puts "ParseLogger: Writing to #{desktop}"
      write_json(desktop, entries, summary)
      write_text(desktop, entries, summary)
      entries.length
    rescue => e
      puts "ParseLogger: generate error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      0
    end

    private

    def self.build_entry(r, entity, ca, cca, ccm)
      eid = r[:entity_id]
      parsed = r[:parsed]

      # Effective category (user override or auto-parsed)
      user_cat = ca[eid]
      auto_cat = parsed[:auto_category] || 'Uncategorized'
      effective_cat = user_cat || auto_cat

      # Cost code suggestion
      suggested_codes = ccm[effective_cat] || []
      assigned_code = cca[eid]

      # Attribute dictionaries from instance and definition
      inst_dicts = dump_dictionaries(entity)
      defn_dicts = {}
      defn = nil
      if entity && entity.respond_to?(:definition)
        defn = entity.definition
        defn_dicts = dump_dictionaries(defn)
      end

      # Geometry stats from definition
      geo = geometry_stats(defn)

      # Subcategory and category source
      auto_subcategory = parsed[:auto_subcategory]
      category_source = parsed[:category_source]

      # Category reason
      cat_reason = derive_category_reason(parsed, r[:display_name], r[:tag])

      # Measurement reason
      mt = parsed[:measurement_type]
      mt_reason = if Parser::CATEGORY_MEASUREMENTS[effective_cat]
        "Category '#{effective_cat}' maps to '#{mt}' in CATEGORY_MEASUREMENTS"
      else
        "No mapping for '#{effective_cat}' in CATEGORY_MEASUREMENTS, defaulting to 'volume'"
      end

      # Cost code reason
      cc_reason = if assigned_code
        "User-assigned cost code: #{assigned_code}"
      elsif suggested_codes.any?
        "Category '#{effective_cat}' maps to #{suggested_codes.inspect} in cost_codes.json"
      else
        "No cost code mapping for category '#{effective_cat}'"
      end

      {
        entity_id: eid,
        entity_type: r[:entity_type],
        definition_name: r[:definition_name],
        instance_name: r[:instance_name],
        display_name: r[:display_name],
        tag: r[:tag],
        material: r[:material],

        # Category decision
        auto_category: auto_cat,
        auto_subcategory: auto_subcategory,
        category_source: category_source,
        user_category: user_cat,
        effective_category: effective_cat,
        category_reason: cat_reason,

        # Measurement decision
        measurement_type: mt,
        measurement_reason: mt_reason,

        # Cost code decision
        suggested_cost_codes: suggested_codes,
        assigned_cost_code: assigned_code,
        cost_code_reason: cc_reason,

        # Parser output
        element_type: parsed[:element_type],
        function: parsed[:function],
        parser_material: parsed[:material],
        thickness: parsed[:thickness],
        size_nominal: parsed[:size_nominal],
        revit_id: parsed[:revit_id],
        raw_name: parsed[:raw],

        # Geometry
        is_solid: r[:is_solid],
        volume_in3: r[:volume_in3],
        volume_ft3: r[:volume_ft3],
        volume_bf: r[:volume_bf],
        bb_width_in: r[:bb_width_in],
        bb_height_in: r[:bb_height_in],
        bb_depth_in: r[:bb_depth_in],
        bb_width_ft: r[:bb_width_in] ? (r[:bb_width_in] / 12.0).round(4) : nil,
        bb_height_ft: r[:bb_height_in] ? (r[:bb_height_in] / 12.0).round(4) : nil,
        bb_depth_ft: r[:bb_depth_in] ? (r[:bb_depth_in] / 12.0).round(4) : nil,
        linear_ft: r[:linear_ft],
        area_sf: r[:area_sf],
        instance_count: r[:instance_count],
        ifc_type: r[:ifc_type],

        # Raw geometry stats
        face_count: geo[:faces],
        edge_count: geo[:edges],
        vertex_count: geo[:vertices],

        # Warnings
        warnings: r[:warnings] || [],

        # All attribute dictionaries (raw dump)
        instance_dictionaries: inst_dicts,
        definition_dictionaries: defn_dicts
      }
    end

    def self.dump_dictionaries(entity)
      result = {}
      return result unless entity
      begin
        dicts = entity.attribute_dictionaries
        return result unless dicts
        dicts.each do |dict|
          pairs = {}
          dict.each_pair do |k, v|
            pairs[k.to_s] = safe_value(v)
          end
          result[dict.name] = pairs
        end
      rescue => e
        result['_error'] = e.message
      end
      result
    end

    def self.safe_value(v)
      case v
      when String, Numeric, TrueClass, FalseClass, NilClass
        v
      when Array
        v.map { |x| safe_value(x) }
      when Hash
        v.transform_values { |x| safe_value(x) }
      when Geom::Point3d
        "Point3d(#{v.x}, #{v.y}, #{v.z})"
      when Geom::Vector3d
        "Vector3d(#{v.x}, #{v.y}, #{v.z})"
      when Length
        "#{v.to_f}\" (#{(v.to_f / 12.0).round(4)}')"
      else
        v.to_s
      end
    end

    def self.geometry_stats(defn)
      r = { faces: 0, edges: 0, vertices: 0 }
      return r unless defn
      begin
        ents = defn.entities
        r[:faces] = ents.grep(Sketchup::Face).length
        r[:edges] = ents.grep(Sketchup::Edge).length
        verts = {}
        ents.grep(Sketchup::Edge).each do |e|
          verts[e.start.position.to_a] = true
          verts[e.end.position.to_a] = true
        end
        r[:vertices] = verts.length
      rescue => e
        r[:error] = e.message
      end
      r
    end

    def self.derive_category_reason(parsed, display_name, tag)
      et = parsed[:element_type]
      fn = parsed[:function]
      cat = parsed[:auto_category]
      src = parsed[:category_source]
      name = parsed[:raw] || display_name || ''

      # Empty name → tag fallback
      if name.empty?
        return "Empty definition name, fell back to tag '#{tag}' → TAG_CATEGORY_MAP → '#{cat}'"
      end

      # _IGNORE
      return "Name matches datum/ignore pattern (T.O./B.O./Level/Datum/S.F.)" if cat == '_IGNORE'

      # Material or IFC reclassification
      suffix = ''
      if src == 'material'
        suffix = " (reclassified by entity material)"
      elsif src == 'ifc'
        suffix = " (reclassified by IFC type)"
      end

      reason = case et
      when 'Basic Wall'
        base = "Name starts with 'Basic Wall'"
        case fn
        when 'Framing'
          "#{base}, detail contains 'Framing' keyword → Wall Framing"
        when 'Finish'
          case cat
          when 'Drywall'
            "#{base}, Finish function, detail matches Gypsum/GYP/Drywall keyword → Drywall"
          when 'Stucco'
            "#{base}, Finish function, detail matches Stucco keyword → Stucco"
          when 'Decorative Metal'
            "#{base}, Finish function, detail matches Metal Panel keyword → Decorative Metal"
          when 'Glass/Glazing'
            "#{base}, Finish function, detail matches Glass keyword → Glass/Glazing"
          when 'Wood Paneling'
            "#{base}, Finish function, detail matches Wood Panel keyword → Wood Paneling"
          when 'Masonry / Veneer'
            "#{base}, Finish function, detail matches Stone/Veneer/Brick/Masonry/CMU keyword → Masonry / Veneer"
          when 'Siding'
            "#{base}, Finish function, detail matches Siding/Lap/Hardie keyword → Siding"
          when 'Soffit'
            "#{base}, Finish function, detail matches Soffit keyword → Soffit"
          when 'Exterior Finish'
            "#{base}, Finish function, detail contains 'Exterior' keyword → Exterior Finish"
          when 'Wall Finish'
            "#{base}, Finish function, no specific material match → Wall Finish"
          else
            "#{base}, Finish function → #{cat}"
          end
        when 'Foundation'
          "#{base}, Foundation function → #{cat}"
        when 'Structure', 'Core'
          "#{base}, #{fn} function → Wall Structure"
        when 'Sheathing'
          "#{base}, matches Sheathing/Plywood/OSB keyword → Wall Sheathing"
        when 'Insulation'
          "#{base}, matches Insulation keyword → Insulation"
        when 'Membrane'
          "#{base}, matches Membrane/Substrate keyword → Membrane"
        else
          "#{base}, no specific function match → #{cat}"
        end

      when 'Basic Roof'
        base = "Name starts with 'Basic Roof'"
        case fn
        when 'Finish'
          case cat
          when 'Metal Roofing'
            "#{base}, Finish function, detail matches Standing Seam/Metal → Metal Roofing"
          when 'Shingle Roofing'
            "#{base}, Finish function, detail matches Shingle/Asphalt → Shingle Roofing"
          else
            "#{base}, Finish function, no specific match → #{cat}"
          end
        when 'Sheathing'
          "#{base}, matches Sheathing/Plywood/OSB → Roof Sheathing"
        when 'Framing'
          "#{base}, matches Framing/Structure → Roof Framing"
        else
          "#{base}, no specific function match → #{cat}"
        end

      when 'Ceiling'
        case cat
        when 'Drywall'
          "Name matches 'Compound Ceiling', detail matches Gypsum/GYP/Drywall → Drywall (Ceiling Drywall)"
        when 'Ceiling Framing'
          "Name matches 'Compound Ceiling', detail matches Framing → Ceiling Framing"
        when 'Decorative Metal'
          "Name matches 'Compound Ceiling', detail matches Metal Panel → Decorative Metal"
        when 'Sheathing'
          "Name matches 'Compound Ceiling', detail matches Sheathing/Plywood → Sheathing"
        when 'Wood Paneling'
          "Name matches 'Compound Ceiling', detail matches WD/Wood Board → Wood Paneling"
        when 'Tile'
          "Name matches 'Compound Ceiling', detail matches Tile → Tile (Ceiling Tile)"
        when 'Masonry / Veneer'
          "Name matches 'Compound Ceiling', detail matches Stone Veneer → Masonry / Veneer"
        else
          "Name matches 'Compound Ceiling' → #{cat}"
        end

      when 'Foundation Slab'
        "Name matches 'Foundation Slab' → Foundation Slabs"
      when 'Wall Foundation'
        "Name matches 'Wall Foundation' → Foundation Footings"
      when 'Basic Floor'
        if cat == 'Concrete'
          "Name matches Floor, detail contains Concrete/Slab → Concrete"
        else
          "Name matches Floor → Flooring"
        end
      when 'Lumber'
        "Name matches Rough Sawn/Dimensional Lumber keyword → Structural Lumber"
      when 'Structural Member'
        "Name matches structural keyword (Brace/Beam/Joist/Rafter/Purlin/Girder/Truss) → Structural Lumber"
      when 'Countertop'
        "Name matches Counter Top/Countertop keyword → Countertops"
      when 'Casework'
        "Name matches Cabinet/Casework/Vanity keyword → Casework"
      when 'Door'
        reason = "Name starts with 'Door'"
        reason = "Tag is 'Doors'" if tag == 'Doors' && !(name =~ /^Door/i)
        "#{reason} → #{cat}"
      when 'Window'
        reason = "Name starts with 'Window'"
        reason = "Tag is 'Windows'" if tag == 'Windows' && !(name =~ /^Window/i)
        "#{reason} → Windows"
      when 'Plumbing Fixture'
        if tag == 'Plumbing Fixtures' && !(name =~ /Toilet|Sink|Faucet|Shower|Tub|Lavatory|Urinal/i)
          "Tag is 'Plumbing Fixtures' → Plumbing"
        else
          "Name matches plumbing keyword (Toilet/Sink/Faucet/Shower/Tub/Lavatory/Urinal) → Plumbing"
        end
      when 'Fascia'
        "Name matches Fascia keyword or tag is 'Fascias' → Fascia"
      when 'Soffit'
        "Name matches Soffit keyword → Soffit"
      when 'Trim'
        "Name matches Trim/Molding/Baseboard/Crown/Casing keyword → Trim"
      when 'Tile'
        "Name matches Tile keyword → Tile"
      when 'Unknown'
        "No name pattern match, fell back to #{src == 'tag' ? "tag '#{tag}'" : (src || 'tag')} → '#{cat}'"
      else
        "Parser assigned category '#{cat}' (element_type: #{et || 'nil'}, function: #{fn || 'nil'})"
      end

      reason + suffix
    end

    # ── Summary ──────────────────────────────────────────

    def self.build_summary(entries, scan_results, model_name)
      cat_counts = Hash.new(0)
      mt_counts = Hash.new(0)
      warning_count = 0
      zero_measurement_count = 0
      dict_names = Hash.new(0)

      entries.each do |e|
        cat_counts[e[:effective_category]] += 1
        mt_counts[e[:measurement_type] || 'nil'] += 1
        warning_count += 1 if e[:warnings] && !e[:warnings].empty?

        has_measurement = (e[:area_sf] && e[:area_sf] > 0) ||
                          (e[:linear_ft] && e[:linear_ft] > 0) ||
                          (e[:volume_ft3] && e[:volume_ft3] > 0)
        zero_measurement_count += 1 unless has_measurement

        (e[:instance_dictionaries] || {}).each_key { |k| dict_names["instance:#{k}"] += 1 }
        (e[:definition_dictionaries] || {}).each_key { |k| dict_names["definition:#{k}"] += 1 }
      end

      unique_defs = scan_results.map { |r| r[:definition_name] }.uniq.length

      {
        model_name: model_name,
        generated_at: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        total_entities: entries.length,
        total_definitions: unique_defs,
        category_counts: cat_counts.sort_by { |k, v| [-v, k] }.to_h,
        uncategorized_count: cat_counts['Uncategorized'] || 0,
        measurement_type_counts: mt_counts.sort_by { |k, v| [-v, k] }.to_h,
        entities_with_warnings: warning_count,
        entities_with_zero_measurements: zero_measurement_count,
        dictionary_names_found: dict_names.sort_by { |k, v| [-v, k] }.to_h
      }
    end

    # ── JSON Output ──────────────────────────────────────

    def self.write_json(desktop, entries, summary)
      require 'json'
      json_path = File.join(desktop, 'FormAndField_ParseLog.json')
      puts "ParseLogger: JSON path: #{json_path}"
      begin
        data = { summary: summary, entities: entries }
        File.open(json_path, 'w:UTF-8') { |f| f.write(JSON.pretty_generate(data)) }
        puts "ParseLogger: JSON saved to #{json_path}"
      rescue => e
        puts "ParseLogger: JSON write error: #{e.message}"
        puts "  #{e.backtrace.first(3).join("\n  ")}"
      end
    end

    # ── Text Output ──────────────────────────────────────

    def self.write_text(desktop, entries, summary)
      txt_path = File.join(desktop, 'FormAndField_ParseLog.txt')
      puts "ParseLogger: Text path: #{txt_path}"
      begin
        File.open(txt_path, 'w:UTF-8') do |f|
          write_text_header(f, summary)
          entries.each_with_index do |e, i|
            write_text_entry(f, e, i + 1)
          end
        end
        puts "ParseLogger: Text saved to #{txt_path}"
      rescue => e
        puts "ParseLogger: Text write error: #{e.message}"
        puts "  #{e.backtrace.first(3).join("\n  ")}"
      end
    end

    def self.write_text_header(f, s)
      f.puts '=' * 72
      f.puts 'FORM AND FIELD - PARSE DIAGNOSTIC LOG'
      f.puts "Generated: #{s[:generated_at]}"
      f.puts "Model: #{s[:model_name]}"
      f.puts '=' * 72
      f.puts
      f.puts '── MODEL SUMMARY ' + '─' * 54
      f.puts
      f.puts "  Total entities scanned:          #{s[:total_entities]}"
      f.puts "  Total definitions found:         #{s[:total_definitions]}"
      f.puts "  Entities with warnings:          #{s[:entities_with_warnings]}"
      f.puts "  Entities with zero measurements: #{s[:entities_with_zero_measurements]}"
      f.puts

      f.puts '  Categories assigned:'
      s[:category_counts].each do |cat, count|
        f.puts "    %-35s %d" % [cat, count]
      end
      f.puts

      f.puts '  Measurement types detected:'
      s[:measurement_type_counts].each do |mt, count|
        f.puts "    %-20s %d" % [mt, count]
      end
      f.puts

      f.puts '  Attribute dictionary names found across all entities:'
      s[:dictionary_names_found].each do |name, count|
        f.puts "    %-45s %d entities" % [name, count]
      end

      f.puts
      f.puts '=' * 72
      f.puts
    end

    def self.write_text_entry(f, e, num)
      pad = [0, 57 - num.to_s.length].max
      f.puts "── ENTITY ##{num} " + '─' * pad
      f.puts
      f.puts "  Entity ID:          #{e[:entity_id]}"
      f.puts "  Entity Type:        #{e[:entity_type]}"
      f.puts "  Definition Name:    #{e[:definition_name]}"
      f.puts "  Instance Name:      #{e[:instance_name] || '(none)'}"
      f.puts "  Display Name:       #{e[:display_name]}"
      f.puts "  Raw Parser Input:   #{e[:raw_name]}"
      f.puts "  Layer/Tag:          #{e[:tag]}"
      f.puts "  Material:           #{e[:material] || '(none)'}"
      f.puts "  IFC Type:           #{e[:ifc_type] || '(none)'}"
      f.puts

      f.puts '  CATEGORY DECISION:'
      f.puts "    Auto-parsed:      #{e[:auto_category]}"
      f.puts "    Auto-subcategory: #{e[:auto_subcategory] || '(none)'}"
      f.puts "    Category source:  #{e[:category_source] || '(none)'}"
      f.puts "    User override:    #{e[:user_category] || '(none)'}"
      f.puts "    Effective:        #{e[:effective_category]}"
      f.puts "    Reason:           #{e[:category_reason]}"
      f.puts

      f.puts '  MEASUREMENT DECISION:'
      f.puts "    Type:             #{e[:measurement_type]}"
      f.puts "    Reason:           #{e[:measurement_reason]}"
      f.puts

      f.puts '  COST CODE DECISION:'
      f.puts "    Suggested:        #{e[:suggested_cost_codes].empty? ? '(none)' : e[:suggested_cost_codes].join(', ')}"
      f.puts "    Assigned:         #{e[:assigned_cost_code] || '(none)'}"
      f.puts "    Reason:           #{e[:cost_code_reason]}"
      f.puts

      f.puts '  PARSER OUTPUT:'
      f.puts "    Element Type:     #{e[:element_type] || '(none)'}"
      f.puts "    Function:         #{e[:function] || '(none)'}"
      f.puts "    Parser Material:  #{e[:parser_material] || '(none)'}"
      f.puts "    Thickness:        #{e[:thickness] || '(none)'}"
      f.puts "    Size Nominal:     #{e[:size_nominal] || '(none)'}"
      f.puts "    Revit ID:         #{e[:revit_id] || '(none)'}"
      f.puts

      f.puts '  GEOMETRY:'
      f.puts "    Is Solid:         #{e[:is_solid]}"
      f.puts "    Volume:           #{e[:volume_in3]} in\u00B3 / #{e[:volume_ft3]} ft\u00B3 / #{e[:volume_bf]} BF"
      w_ft = e[:bb_width_ft] ? "%.2f'" % e[:bb_width_ft] : '?'
      h_ft = e[:bb_height_ft] ? "%.2f'" % e[:bb_height_ft] : '?'
      d_ft = e[:bb_depth_ft] ? "%.2f'" % e[:bb_depth_ft] : '?'
      f.puts "    Bounding Box:     %.2f\" x %.2f\" x %.2f\" (%s x %s x %s)" %
        [e[:bb_width_in] || 0, e[:bb_height_in] || 0, e[:bb_depth_in] || 0, w_ft, h_ft, d_ft]
      f.puts "    Linear Feet:      #{e[:linear_ft]}"
      f.puts "    Area SF:          #{e[:area_sf] || '(not computed)'}"
      f.puts "    Instance Count:   #{e[:instance_count]}"
      f.puts

      f.puts '  RAW GEOMETRY (definition):'
      f.puts "    Face Count:       #{e[:face_count]}"
      f.puts "    Edge Count:       #{e[:edge_count]}"
      f.puts "    Vertex Count:     #{e[:vertex_count]}"
      f.puts

      if e[:warnings] && !e[:warnings].empty?
        f.puts '  WARNINGS:'
        e[:warnings].each { |w| f.puts "    - #{w}" }
        f.puts
      end

      f.puts '  ATTRIBUTE DICTIONARIES (instance):'
      if e[:instance_dictionaries].empty?
        f.puts '    (none)'
      else
        e[:instance_dictionaries].each do |dict_name, pairs|
          f.puts "    [#{dict_name}]"
          if pairs.empty?
            f.puts '      (empty)'
          else
            pairs.each { |k, v| f.puts "      %-30s = %s" % [k, v.inspect] }
          end
        end
      end
      f.puts

      f.puts '  ATTRIBUTE DICTIONARIES (definition):'
      if e[:definition_dictionaries].empty?
        f.puts '    (none)'
      else
        e[:definition_dictionaries].each do |dict_name, pairs|
          f.puts "    [#{dict_name}]"
          if pairs.empty?
            f.puts '      (empty)'
          else
            pairs.each { |k, v| f.puts "      %-30s = %s" % [k, v.inspect] }
          end
        end
      end

      f.puts
    end
  end
end
