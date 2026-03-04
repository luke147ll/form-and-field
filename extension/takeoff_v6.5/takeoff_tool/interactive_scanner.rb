module TakeoffTool
  module InteractiveScanner

    @current_groups = []
    @current_sr = nil
    @current_ca = nil

    def self.current_groups; @current_groups; end
    def self.current_sr; @current_sr; end
    def self.current_ca; @current_ca; end

    # Confidence thresholds
    HIGH_CONFIDENCE = 85
    MEDIUM_CONFIDENCE = 50

    # ═══════════════════════════════════════════════════════════
    # analyze — Called after scan completes
    #
    # Returns summary hash with counts and flagged items.
    # Stores groups for dashboard scanner mode.
    # ═══════════════════════════════════════════════════════════

    def self.analyze(scan_results, category_assignments)
      groups = group_low_confidence(scan_results, category_assignments)

      auto_count = 0
      flagged_count = 0
      low_count = 0

      scan_results.each do |r|
        pct = confidence_pct(r)
        if pct >= HIGH_CONFIDENCE
          auto_count += 1
        elsif pct >= MEDIUM_CONFIDENCE
          flagged_count += 1
          r[:flagged] = true
        else
          low_count += 1
        end
      end

      summary = {
        auto_classified: auto_count,
        flagged: flagged_count,
        low_confidence_groups: groups.length,
        low_confidence_items: low_count
      }

      # Store groups for dashboard scanner mode
      @current_groups = groups
      @current_sr = scan_results
      @current_ca = category_assignments

      summary
    end

    # ═══════════════════════════════════════════════════════════
    # Group low-confidence entities by definition name / pattern
    #
    # Strategy:
    #   1. Collect all low-confidence, unassigned entities
    #   2. Group by definition name first
    #   3. If too many groups (>50), re-group by stripped pattern
    #   4. If still too many, aggressive pattern stripping
    #   5. Merge size variants ("Header, H8" + "Header, H10" → "Header")
    # ═══════════════════════════════════════════════════════════

    MAX_GROUPS = 50

    def self.group_low_confidence(scan_results, category_assignments)
      # Step 1: Collect low-confidence unassigned entities
      low_conf = []
      scan_results.each do |r|
        next if category_assignments[r[:entity_id]]
        pct = confidence_pct(r)
        next if pct >= MEDIUM_CONFIDENCE
        low_conf << r
      end

      return [] if low_conf.empty?

      # Step 2: Group by cleaned display name (instance name preferred, hex IDs stripped)
      # Uses display_name (instance name > definition name), never raw GUIDs
      groups = build_groups(low_conf) { |r| clean_display_name(r) }

      # Step 3: If too many groups, re-group by aggressive pattern stripping
      if groups.length > MAX_GROUPS
        groups = build_groups(low_conf) { |r| extract_base_pattern(clean_display_name(r)) }
      end

      # Generate top guesses for each group
      groups.each do |_key, group|
        group[:guesses] = generate_guesses(group)
      end

      # Sort by count descending (most impactful first)
      sorted = groups.values.sort_by { |g| -g[:count] }

      # Step 5: Merge size variants ("Header, H8" + "Header, H10" → "Header")
      merge_size_variants(sorted)
    end

    # Build groups from a list of scan results using a key extraction block
    def self.build_groups(items)
      groups = {}
      items.each do |r|
        key = yield(r)
        key = key.to_s.strip
        next if key.empty?

        unless groups.key?(key)
          # Use clean_display_name for user-facing name (never GUIDs)
          clean = clean_display_name(r)
          groups[key] = {
            name: clean,
            display_name: clean,
            material: r[:material],
            ifc_type: r[:ifc_type],
            size: r[:parsed][:size_nominal],
            count: 0,
            entity_ids: [],
            guesses: [],
            confidence: confidence_pct(r)
          }
        end
        groups[key][:count] += 1
        groups[key][:entity_ids] << r[:entity_id]
      end
      groups
    end

    # Strip trailing Revit hex IDs from names
    # "Dimension Lumber-Column, (3) 2x6, 370757" → "Dimension Lumber-Column, (3) 2x6"
    # "Basic Wall, Finish - GYP, 3EF083"          → "Basic Wall, Finish - GYP"
    def self.strip_revit_id(name)
      s = name.to_s.strip
      loop do
        stripped = s.sub(/,\s*[0-9A-Fa-f]+\s*$/, '').strip
        break if stripped == s
        s = stripped
      end
      s
    end

    # Aggressive pattern extraction: strip ALL trailing identifiers,
    # dimensions, and specifics to find the base component type.
    def self.extract_base_pattern(name)
      s = strip_revit_id(name.to_s)
      s = s.sub(/,\s*\(?\d+\)?\s*\d+\s*x\s*\d+.*$/i, '').strip
      s = s.sub(/,\s*\d+['"'-].*$/i, '').strip
      s = s.sub(/,\s*\d+\/?\d*\s*["″]?\s*$/, '').strip
      s = strip_revit_id(name.to_s) if s.empty?
      s
    end

    # Check if a string looks like a GUID or raw hex identifier
    # Matches patterns like "cb416e21-3be6-4ff8-9536-ec6d7779a761-0035b8f6"
    def self.guid?(name)
      s = name.to_s.strip
      return true if s =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
      # Also match GUID with extra suffix like "-0035b8f6"
      return true if s =~ /^[0-9a-f]{8}(-[0-9a-f]{4}){3,}/i
      # Mostly hex with hyphens, no readable words
      return true if s =~ /^[0-9a-f-]{20,}$/i
      false
    end

    # Get the best human-readable name for a scan result.
    # Prefers instance name (display_name) over definition_name.
    # Strips Revit hex IDs. Falls back to material/IFC type if name is a GUID.
    def self.clean_display_name(r)
      # Prefer display_name (instance name if set, else definition name)
      raw = (r[:display_name] || r[:definition_name] || '').to_s.strip

      # If the raw name is a GUID, try alternatives
      if guid?(raw)
        # Try instance_name explicitly
        iname = r[:instance_name].to_s.strip
        raw = iname unless iname.empty? || guid?(iname)
      end

      # If still a GUID, build a readable name from attributes
      if guid?(raw)
        parts = []
        parts << r[:ifc_type].to_s.sub(/^Ifc/i, '') unless r[:ifc_type].to_s.empty?
        parts << r[:material].to_s unless r[:material].to_s.empty?
        tag = r[:tag].to_s
        parts << tag unless tag.empty? || tag == 'Untagged' || tag == 'Layer0'
        raw = parts.empty? ? 'Unknown Component' : parts.join(' — ')
      end

      # Strip trailing Revit hex IDs
      strip_revit_id(raw)
    end

    # ═══════════════════════════════════════════════════════════
    # Size variant merging
    # "Header, H8" + "Header, H10" → "Header" with variants [H8, H10]
    # Preserves sub-groups for expandable per-variant classification
    # ═══════════════════════════════════════════════════════════

    # Strip the last comma-separated segment if it looks like a size/dimension
    # Returns [base_name, variant_label] or [original, nil]
    def self.strip_size_for_merge(name)
      s = name.to_s.strip
      if s =~ /^(.+),\s*(.{1,30})$/
        base = $1.strip
        variant = $2.strip
        # Variant looks like a size if it contains a digit
        return [base, variant] if variant =~ /\d/
      end
      [s, nil]
    end

    # Merge groups that share the same base name after stripping sizes
    def self.merge_size_variants(groups_array)
      return groups_array if groups_array.length <= 1

      base_map = {}
      groups_array.each do |g|
        base, variant = strip_size_for_merge(g[:name])
        g[:variant_label] = variant
        base_map[base] ||= []
        base_map[base] << g
      end

      merged = []
      base_map.each do |base, sub_groups|
        if sub_groups.length == 1
          g = sub_groups.first
          g[:variants] = g[:variant_label] ? [g[:variant_label]] : []
          g[:sub_groups] = []
          merged << g
        else
          # Merge: largest sub-group first, combine all entity_ids
          sub_groups.sort_by! { |g| -g[:count] }
          primary = sub_groups.first.dup
          primary[:name] = base
          primary[:display_name] = base
          primary[:variants] = sub_groups.map { |g| g[:variant_label] }.compact.uniq.sort
          primary[:entity_ids] = sub_groups.flat_map { |g| g[:entity_ids] }
          primary[:count] = primary[:entity_ids].length
          primary[:guesses] = generate_guesses(primary)
          # Preserve sub-groups for expandable per-variant classification
          primary[:sub_groups] = sub_groups.map do |sg|
            {
              name: sg[:name],
              variant_label: sg[:variant_label] || sg[:name],
              entity_ids: sg[:entity_ids],
              count: sg[:count],
              guesses: sg[:guesses],
              material: sg[:material],
              ifc_type: sg[:ifc_type],
              applied: false
            }
          end
          merged << primary
        end
      end

      merged.sort_by { |g| -g[:count] }
    end

    # ═══════════════════════════════════════════════════════════
    # Convert confidence symbol to percentage
    # ═══════════════════════════════════════════════════════════

    def self.confidence_pct(r)
      return 0 unless r && r[:parsed]

      conf = r[:parsed][:confidence]
      score = r[:parsed][:cost_code_score]

      # If we have a numeric score from cost code parser, use it directly
      if score
        return [score, 100].min
      end

      # Otherwise map from symbol
      case conf
      when :high then 90
      when :medium then 65
      when :low then 35
      when :none then 10
      else
        # Infer from category_source
        case r[:parsed][:category_source]
        when 'name', 'cost_code_force' then 90
        when 'cost_code_map' then 75
        when 'ifc_name' then 85
        when 'material_bbox' then 65
        when 'material' then 60
        when 'learned' then 92
        when 'ifc', 'tag' then 40
        when 'keyword' then 30
        when 'material_fallback' then 25
        else 10
        end
      end
    end

    # ═══════════════════════════════════════════════════════════
    # Generate category guesses for a group
    # ═══════════════════════════════════════════════════════════

    def self.generate_guesses(group)
      guesses = []
      text = group[:display_name].to_s
      mat = group[:material].to_s
      ifc = group[:ifc_type].to_s

      # Try cost code parser
      cc_result = CostCodeParser.classify(text, nil, mat, ifc)
      if cc_result
        score = cc_result[:cost_code_score] || 50
        guesses << {
          category: cc_result[:auto_category],
          subcategory: cc_result[:auto_subcategory],
          cost_code: cc_result[:cost_code],
          confidence: [score, 100].min,
          source: 'Cost Code Map'
        }
      end

      # Try learned rules
      learned = LearningSystem.apply(text, mat, ifc)
      if learned
        guesses << {
          category: learned[:auto_category],
          subcategory: learned[:auto_subcategory],
          cost_code: learned[:cost_code],
          confidence: 92,
          source: 'Learned Rule'
        }
      end

      # Try keyword scan
      Scanner::KEYWORD_MAP.each do |re, cat|
        combined = "#{text} #{mat}"
        if combined =~ re
          guesses << {
            category: cat,
            subcategory: nil,
            cost_code: nil,
            confidence: 25,
            source: 'Keyword'
          }
          break
        end
      end

      # Deduplicate by category, keep highest confidence
      seen = {}
      guesses.select! do |g|
        key = g[:category]
        if seen[key]
          false
        else
          seen[key] = true
          true
        end
      end

      # Sort by confidence descending, limit to top 3
      guesses.sort_by { |g| -g[:confidence] }.first(3)
    end

    # ═══════════════════════════════════════════════════════════
    # Apply category to all entities in a group (or sub-group)
    # ═══════════════════════════════════════════════════════════

    def self.apply_to_group(group, category, subcategory, cost_code, scan_results, category_assignments)
      group[:entity_ids].each do |eid|
        category_assignments[eid] = category
        TakeoffTool.save_assignment(eid, 'category', category)
        TakeoffTool.save_assignment(eid, 'subcategory', subcategory) unless subcategory.empty?
        if !cost_code.empty?
          TakeoffTool.cost_code_assignments[eid] = cost_code
          TakeoffTool.save_assignment(eid, 'cost_code', cost_code)
        end
        RecatLog.log_change(eid, category) rescue nil
      end

      # Update scan results
      scan_results.each do |r|
        if group[:entity_ids].include?(r[:entity_id])
          r[:parsed][:auto_category] = category
          r[:parsed][:auto_subcategory] = subcategory unless subcategory.empty?
        end
      end

      # Add to master categories if new
      TakeoffTool.add_category(category)
      TakeoffTool.add_subcategory(category, subcategory) if subcategory && !subcategory.empty?

      puts "InteractiveScanner: Applied '#{category}' to #{group[:entity_ids].length} entities (#{group[:name]})"
    end

    # ═══════════════════════════════════════════════════════════
    # Regroup low-confidence items by a different mode
    # Modes: 'name' (default), 'material', 'volume', 'color'
    # ═══════════════════════════════════════════════════════════

    def self.regroup(mode)
      return [] unless @current_sr && @current_ca
      low_conf = []
      @current_sr.each do |r|
        next if @current_ca[r[:entity_id]]
        pct = confidence_pct(r)
        next if pct >= MEDIUM_CONFIDENCE
        low_conf << r
      end
      return [] if low_conf.empty?

      case mode
      when 'name'
        groups = build_groups(low_conf) { |r| clean_display_name(r) }
        groups = build_groups(low_conf) { |r| extract_base_pattern(clean_display_name(r)) } if groups.length > MAX_GROUPS
      when 'material'
        groups = build_groups(low_conf) { |r| r[:material].to_s.strip.empty? ? 'No Material' : r[:material].to_s.strip }
      when 'volume'
        groups = build_groups(low_conf) { |r| volume_bucket(r) }
      when 'color'
        groups = build_groups(low_conf) { |r| material_color_key(r) }
      else
        groups = build_groups(low_conf) { |r| clean_display_name(r) }
      end

      groups.each { |_k, g| g[:guesses] = generate_guesses(g) }
      sorted = groups.values.sort_by { |g| -g[:count] }
      @current_groups = (mode == 'name') ? merge_size_variants(sorted) : sorted
      @current_groups
    end

    def self.volume_bucket(r)
      vol = r[:parsed][:volume_cf] || 0
      case vol
      when 0..0.5 then 'Tiny (< 0.5 ft\u00B3)'
      when 0.5..5 then 'Small (0.5-5 ft\u00B3)'
      when 5..50 then 'Medium (5-50 ft\u00B3)'
      else 'Large (> 50 ft\u00B3)'
      end
    end

    def self.material_color_key(r)
      eid = r[:entity_id]
      e = TakeoffTool.entity_registry[eid]
      return 'No Material' unless e && e.valid? && e.respond_to?(:material) && e.material
      m = e.material
      c = m.color
      "#{m.display_name} (#{c.red},#{c.green},#{c.blue})"
    end

    # ═══════════════════════════════════════════════════════════
    # Serialize groups for JSON transport to dashboard JS
    # ═══════════════════════════════════════════════════════════

    def self.serialize_groups(groups = nil)
      groups ||= @current_groups
      return [] unless groups
      groups.map.with_index do |g, idx|
        {
          idx: idx,
          name: g[:name] || g[:display_name],
          material: g[:material] || '-',
          ifcType: g[:ifc_type] || '-',
          count: g[:count],
          entityIds: g[:entity_ids],
          confidence: g[:confidence] || 0,
          applied: g[:applied] || false,
          skipped: g[:skipped] || false,
          guesses: (g[:guesses] || []).map { |gg|
            { category: gg[:category], subcategory: gg[:subcategory], confidence: gg[:confidence], source: gg[:source] }
          },
          variants: g[:variants] || [],
          subGroups: (g[:sub_groups] || []).map.with_index { |sg, si|
            { idx: si, variantLabel: sg[:variant_label] || sg[:name], count: sg[:count],
              entityIds: sg[:entity_ids],
              guesses: (sg[:guesses] || []).map { |gg| { category: gg[:category], subcategory: gg[:subcategory], confidence: gg[:confidence], source: gg[:source] } }
            }
          }
        }
      end
    end

    def self.remaining_count
      (@current_groups || []).count { |g| !g[:applied] }
    end

  end
end
