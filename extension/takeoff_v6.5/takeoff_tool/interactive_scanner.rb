module TakeoffTool
  module InteractiveScanner

    @dialog = nil

    # Confidence thresholds
    HIGH_CONFIDENCE = 85
    MEDIUM_CONFIDENCE = 50

    # ═══════════════════════════════════════════════════════════
    # analyze — Called after scan completes
    #
    # Returns summary hash with counts and flagged items.
    # Shows interactive dialog if low-confidence groups exist.
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

      # Show interactive dialog if low-confidence groups exist
      if groups.length > 0
        show_dialog(groups, scan_results, category_assignments)
      end

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

      # Step 2: Try grouping by definition name
      groups = build_groups(low_conf) { |r| (r[:definition_name] || '').strip }

      # Step 3: If too many groups, re-group by stripped pattern
      if groups.length > MAX_GROUPS
        groups = build_groups(low_conf) { |r| strip_revit_id(r[:display_name] || r[:definition_name] || '') }
      end

      # Step 4: If STILL too many, group by aggressive pattern stripping
      if groups.length > MAX_GROUPS
        groups = build_groups(low_conf) { |r| extract_base_pattern(r[:display_name] || r[:definition_name] || '') }
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
          groups[key] = {
            name: key,
            display_name: r[:display_name] || key,
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
      s = strip_revit_id(name)
      s = s.sub(/,\s*\(?\d+\)?\s*\d+\s*x\s*\d+.*$/i, '').strip
      s = s.sub(/,\s*\d+['"'-].*$/i, '').strip
      s = s.sub(/,\s*\d+\/?\d*\s*["″]?\s*$/, '').strip
      s = strip_revit_id(name) if s.empty?
      s
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
        when 'learned' then 70
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
          confidence: 60,
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
    # Show the interactive classification dialog
    # ═══════════════════════════════════════════════════════════

    def self.show_dialog(groups, scan_results, category_assignments)
      @dialog.close if @dialog && @dialog.visible? rescue nil

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Scanner needs your help — #{groups.length} groups to classify",
        preferences_key: "TakeoffInteractiveScanner",
        width: 700, height: 550,
        left: 200, top: 120,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      html = build_dialog_html(groups)
      @dialog.set_html(html)

      @dialog.add_action_callback('applyGroup') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          group_idx = data['groupIdx'].to_i
          category = data['category'].to_s.strip
          subcategory = (data['subcategory'] || '').to_s.strip
          cost_code = (data['costCode'] || '').to_s.strip

          next if category.empty? || group_idx < 0 || group_idx >= groups.length

          group = groups[group_idx]
          apply_to_group(group, category, subcategory, cost_code, scan_results, category_assignments)

          # Mark this group as done
          group[:applied] = true
          group[:applied_category] = category
          # Mark all sub-groups as applied too
          (group[:sub_groups] || []).each { |sg| sg[:applied] = true }

          # Learn from this answer
          LearningSystem.capture(
            group[:entity_ids].first, 'Uncategorized', category,
            new_subcategory: subcategory.empty? ? nil : subcategory,
            new_cost_code: cost_code.empty? ? nil : cost_code
          )

          # Update dialog
          remaining = groups.count { |g| !g[:applied] }
          if remaining == 0
            @dialog.execute_script("allDone()")
          else
            @dialog.execute_script("groupApplied(#{group_idx})")
          end
        rescue => e
          puts "InteractiveScanner applyGroup error: #{e.message}"
        end
      end

      @dialog.add_action_callback('skipGroup') do |_ctx, idx_str|
        idx = idx_str.to_s.to_i
        if idx >= 0 && idx < groups.length
          groups[idx][:applied] = true
          groups[idx][:skipped] = true
          @dialog.execute_script("groupApplied(#{idx})")
        end
      end

      @dialog.add_action_callback('applyBulk') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          indices = data['groupIndices'] || []
          category = data['category'].to_s.strip
          subcategory = (data['subcategory'] || '').to_s.strip

          next if category.empty? || indices.empty?

          indices.each do |idx|
            idx = idx.to_i
            next if idx < 0 || idx >= groups.length
            group = groups[idx]
            next if group[:applied]

            apply_to_group(group, category, subcategory, '', scan_results, category_assignments)
            group[:applied] = true
            group[:applied_category] = category
            (group[:sub_groups] || []).each { |sg| sg[:applied] = true }

            LearningSystem.capture(
              group[:entity_ids].first, 'Uncategorized', category,
              new_subcategory: subcategory.empty? ? nil : subcategory
            )
          end

          # Update dialog
          remaining = groups.count { |g| !g[:applied] }
          if remaining == 0
            @dialog.execute_script("allDone()")
          else
            indices.each { |i| @dialog.execute_script("groupApplied(#{i})") }
            @dialog.execute_script("deselectAll()")
          end
        rescue => e
          puts "InteractiveScanner applyBulk error: #{e.message}"
        end
      end

      @dialog.add_action_callback('applySubGroups') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          group_idx = data['groupIdx'].to_i
          assignments = data['assignments'] || []

          next if group_idx < 0 || group_idx >= groups.length
          group = groups[group_idx]
          subs = group[:sub_groups] || []
          next if subs.empty?

          applied_indices = []
          assignments.each do |a|
            sub_idx = a['subIdx'].to_i
            category = a['category'].to_s.strip
            subcategory = (a['subcategory'] || '').to_s.strip
            next if category.empty? || sub_idx < 0 || sub_idx >= subs.length

            sg = subs[sub_idx]
            next if sg[:applied]

            # Apply to this sub-group's entity_ids
            apply_to_group(sg, category, subcategory, '', scan_results, category_assignments)
            sg[:applied] = true

            # Learn per-variant pattern
            LearningSystem.capture(
              sg[:entity_ids].first, 'Uncategorized', category,
              new_subcategory: subcategory.empty? ? nil : subcategory
            )
            applied_indices << sub_idx
          end

          # Check if all sub-groups are now applied
          all_done = subs.all? { |sg| sg[:applied] }
          if all_done
            group[:applied] = true
            group[:applied_category] = 'Mixed'
            remaining = groups.count { |g| !g[:applied] }
            if remaining == 0
              @dialog.execute_script("allDone()")
            else
              @dialog.execute_script("groupApplied(#{group_idx})")
            end
          else
            js_indices = JSON.generate(applied_indices)
            @dialog.execute_script("subGroupsApplied(#{group_idx}, #{js_indices})")
          end
        rescue => e
          puts "InteractiveScanner applySubGroups error: #{e.message}"
        end
      end

      @dialog.add_action_callback('finishAll') do |_ctx|
        # Close dialog, send remaining to Uncategorized
        applied = groups.count { |g| g[:applied] && !g[:skipped] }
        skipped = groups.count { |g| g[:skipped] }
        remaining = groups.count { |g| !g[:applied] }

        # Count auto-classified
        auto = 0
        scan_results.each do |r|
          pct = confidence_pct(r)
          auto += 1 if pct >= MEDIUM_CONFIDENCE
        end

        user_helped = 0
        groups.each do |g|
          user_helped += g[:count] if g[:applied] && !g[:skipped]
        end

        uncategorized = 0
        groups.each do |g|
          uncategorized += g[:count] if !g[:applied] || g[:skipped]
        end

        @dialog.close rescue nil

        # Show summary
        summary = "Scan Complete!\n\n"
        summary += "Auto-classified: #{auto}\n"
        summary += "You helped classify: #{user_helped}\n"
        summary += "Uncategorized: #{uncategorized}"
        UI.messagebox(summary)

        # Refresh dashboard
        if Dashboard.visible?
          Dashboard.send_data(scan_results, category_assignments, TakeoffTool.cost_code_assignments)
        end
        TakeoffTool.trigger_backup
      end

      @dialog.add_action_callback('requestCategories') do |_ctx|
        require 'json'
        cats = TakeoffTool.master_categories
        msub = TakeoffTool.master_subcategories
        js = JSON.generate({ categories: cats, subcategories: msub })
        esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
        @dialog.execute_script("receiveCategories('#{esc}')")
      end

      @dialog.show
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
    # Build the interactive dialog HTML
    # ═══════════════════════════════════════════════════════════

    def self.build_dialog_html(groups)
      require 'json'
      total_items = groups.inject(0) { |sum, g| sum + g[:count] }
      groups_json = groups.map.with_index do |g, idx|
        {
          idx: idx,
          name: g[:name],
          variants: g[:variants] || [],
          material: g[:material] || '-',
          ifcType: g[:ifc_type] || '-',
          size: g[:size] || '-',
          count: g[:count],
          guesses: g[:guesses],
          subGroups: (g[:sub_groups] || []).map.with_index { |sg, si|
            {
              idx: si,
              variantLabel: sg[:variant_label] || sg[:name],
              count: sg[:count],
              guesses: sg[:guesses]
            }
          }
        }
      end

      <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
      <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { font-family:-apple-system,'Segoe UI',Arial,sans-serif; font-size:12px; color:#e0e0e0; background:#1e1e1e; }
        .header { padding:12px 16px; background:#252525; border-bottom:1px solid #333; display:flex; justify-content:space-between; align-items:center; }
        .header h2 { font-size:14px; color:#fff; }
        .header .count { color:#7cc; font-size:13px; }
        .bulk-bar { padding:8px 12px; background:#2a2a3a; border-bottom:1px solid #444; display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
        .bulk-left { display:flex; gap:6px; align-items:center; }
        .bulk-right { display:flex; gap:6px; align-items:center; margin-left:auto; }
        .bulk-bar select { background:#333; color:#e0e0e0; border:1px solid #555; padding:4px 8px; border-radius:3px; font-size:11px; min-width:140px; }
        .btn-sel { padding:3px 8px; border:1px solid #555; background:#333; color:#ccc; border-radius:3px; cursor:pointer; font-size:10px; }
        .btn-sel:hover { background:#444; }
        .btn-bulk { background:#4a9eff; color:#fff; padding:5px 14px; border:none; border-radius:3px; cursor:pointer; font-size:11px; font-weight:600; }
        .btn-bulk:hover { background:#5ab; }
        .btn-bulk:disabled { opacity:0.4; cursor:default; }
        .content { padding:16px; height:calc(100vh - 140px); overflow-y:auto; }
        .group-card { background:#252525; border:1px solid #333; border-radius:6px; padding:12px; margin-bottom:10px; }
        .group-card.applied { opacity:0.4; pointer-events:none; }
        .group-card.current { border-color:#4a9eff; }
        .group-header { display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:8px; }
        .group-left { display:flex; align-items:flex-start; gap:6px; max-width:70%; }
        .group-check { width:16px; height:16px; cursor:pointer; accent-color:#4a9eff; margin-top:1px; flex-shrink:0; }
        .expand-btn { background:none; border:none; color:#888; cursor:pointer; font-size:13px; padding:0 2px; flex-shrink:0; margin-top:0; line-height:18px; transition:transform 0.15s; }
        .expand-btn:hover { color:#fff; }
        .expand-btn.expanded { transform:rotate(90deg); }
        .group-name { font-size:13px; font-weight:600; color:#fff; word-break:break-all; }
        .group-count { background:#4a3800; padding:3px 10px; border-radius:10px; font-size:12px; color:#fc8; font-weight:700; white-space:nowrap; }
        .variant-tags { display:inline-flex; flex-wrap:wrap; gap:3px; margin-left:6px; vertical-align:middle; }
        .variant-tag { background:#3a3a2a; color:#cc8; padding:1px 5px; border-radius:3px; font-size:10px; }
        .group-meta { display:flex; gap:12px; margin-bottom:10px; font-size:11px; color:#888; padding-left:24px; }
        .group-meta span { background:#2a2a2a; padding:2px 6px; border-radius:3px; }
        .guesses { margin-bottom:10px; padding-left:24px; }
        .guess { display:flex; align-items:center; gap:8px; padding:4px 0; }
        .guess input[type=radio] { margin:0; }
        .guess-label { flex:1; }
        .guess-cat { color:#8f8; font-weight:600; }
        .guess-conf { color:#fc8; font-size:10px; }
        .guess-source { color:#888; font-size:10px; }
        .custom-row { display:flex; gap:6px; align-items:center; margin-top:4px; }
        .custom-row select, .custom-row input { background:#333; color:#e0e0e0; border:1px solid #555; padding:3px 6px; border-radius:3px; font-size:11px; }
        .custom-row select { min-width:150px; }
        .group-actions { display:flex; gap:6px; justify-content:flex-end; padding-left:24px; }
        .btn { padding:4px 12px; border:none; border-radius:3px; cursor:pointer; font-size:11px; }
        .btn-apply { background:#2d7d46; color:#fff; }
        .btn-apply:hover { background:#3a9; }
        .btn-skip { background:#555; color:#ccc; }
        .btn-skip:hover { background:#666; }
        .footer { padding:8px 16px; background:#252525; border-top:1px solid #333; display:flex; justify-content:space-between; align-items:center; }
        .btn-finish { background:#4a9eff; color:#fff; padding:6px 16px; border:none; border-radius:4px; cursor:pointer; font-size:12px; }
        .btn-finish:hover { background:#5ab; }
        .progress { color:#888; font-size:11px; }
        .done-msg { text-align:center; padding:40px; color:#8f8; font-size:14px; display:none; }

        /* Expandable sub-groups */
        .sub-groups { display:none; margin:8px 0 10px 24px; border-left:2px solid #444; padding-left:10px; }
        .sub-groups.visible { display:block; }
        .sub-row { display:flex; align-items:center; gap:8px; padding:5px 4px; border-bottom:1px solid #2a2a2a; font-size:11px; }
        .sub-row:last-child { border-bottom:none; }
        .sub-row.applied { opacity:0.35; pointer-events:none; }
        .sub-check { width:14px; height:14px; cursor:pointer; accent-color:#4a9eff; flex-shrink:0; }
        .sub-name { color:#cc8; font-weight:600; min-width:100px; white-space:nowrap; }
        .sub-count { color:#888; font-size:10px; min-width:55px; white-space:nowrap; }
        .sub-cat-sel { background:#333; color:#e0e0e0; border:1px solid #555; padding:2px 4px; border-radius:3px; font-size:10px; min-width:120px; max-width:170px; }
        .sub-sub-sel { background:#333; color:#e0e0e0; border:1px solid #555; padding:2px 4px; border-radius:3px; font-size:10px; min-width:90px; max-width:130px; }
        .sub-actions { display:flex; gap:6px; align-items:center; padding:6px 0 2px; flex-wrap:wrap; }
        .sub-actions .btn { font-size:10px; padding:3px 10px; }
        .sub-info { color:#888; font-size:10px; margin-left:auto; }
      </style>
      </head>
      <body>
      <div class="header">
        <div>
          <h2>Scanner needs your help</h2>
          <div style="color:#888;font-size:11px;margin-top:2px">#{total_items} items in #{groups.length} groups &mdash; one answer classifies the whole group</div>
        </div>
        <span class="count" id="remaining">#{groups.length} groups to classify</span>
      </div>
      <div class="bulk-bar" id="bulkBar">
        <div class="bulk-left">
          <button class="btn-sel" onclick="selectAll()">Select All</button>
          <button class="btn-sel" onclick="deselectAll()">Deselect All</button>
          <span style="color:#888;font-size:11px" id="bulkInfo">0 groups checked</span>
        </div>
        <div class="bulk-right">
          <select id="bulkCatSel" onchange="onBulkCatChange()">
            <option value="">-- Category --</option>
          </select>
          <select id="bulkSubSel">
            <option value="">No subcategory</option>
          </select>
          <button class="btn-bulk" id="bulkApplyBtn" onclick="applyBulk()" disabled>Apply to checked</button>
        </div>
      </div>
      <div class="content" id="content">
        <div id="groups"></div>
        <div class="done-msg" id="doneMsg">All groups classified! Click Finish to continue.</div>
      </div>
      <div class="footer">
        <span class="progress" id="progress">0 of #{groups.length} classified</span>
        <button class="btn-finish" onclick="finish()">Finish &mdash; send remaining to Uncategorized</button>
      </div>

      <script>
      var GROUPS = #{JSON.generate(groups_json)};
      var allCategories = [];
      var allSubcategories = {};
      var classified = 0;
      var total = GROUPS.length;
      var checkedGroups = {};
      var expandedGroups = {};

      function init() {
        sketchup.requestCategories();
        renderGroups();
      }

      function receiveCategories(jsonStr) {
        try {
          var d = JSON.parse(jsonStr);
          allCategories = d.categories || [];
          allSubcategories = d.subcategories || {};
          renderGroups();
          // Populate bulk category dropdown
          var bulkSel = document.getElementById('bulkCatSel');
          if (bulkSel) {
            bulkSel.innerHTML = '<option value="">-- Category --</option>';
            allCategories.forEach(function(c) {
              if (c !== '_IGNORE') bulkSel.innerHTML += '<option value="'+esc(c)+'">'+esc(c)+'</option>';
            });
          }
        } catch(e) {}
      }

      function catOptions(selectedCat) {
        var h = '<option value="">-- Select --</option>';
        allCategories.forEach(function(c) {
          if (c !== '_IGNORE') {
            h += '<option value="'+esc(c)+'"'+(c===selectedCat?' selected':'')+'>'+esc(c)+'</option>';
          }
        });
        return h;
      }

      function subOptions(cat, selectedSub) {
        var h = '<option value="">No subcategory</option>';
        var subs = allSubcategories[cat] || [];
        subs.forEach(function(s) {
          h += '<option value="'+esc(s)+'"'+(s===selectedSub?' selected':'')+'>'+esc(s)+'</option>';
        });
        return h;
      }

      function renderGroups() {
        var html = '';
        GROUPS.forEach(function(g, i) {
          var cls = g.applied ? 'group-card applied' : 'group-card';
          var hasSubs = g.subGroups && g.subGroups.length > 1;
          var isExp = !!expandedGroups[i];
          html += '<div class="'+cls+'" id="group-'+i+'">';

          // Header with checkbox and optional expand arrow
          html += '<div class="group-header">';
          html += '<div class="group-left">';
          html += '<input type="checkbox" class="group-check" id="check-'+i+'" onchange="updateBulkBar()"'+(g.applied?' disabled':'')+' />';
          if (hasSubs) {
            html += '<button class="expand-btn'+(isExp?' expanded':'')+'" id="expBtn-'+i+'" onclick="toggleExpand('+i+')" title="Expand to classify variants individually">&#9654;</button>';
          }
          var nameHtml = esc(g.name);
          if (g.variants && g.variants.length > 0) {
            nameHtml += ' <span class="variant-tags">';
            g.variants.forEach(function(v) { nameHtml += '<span class="variant-tag">'+esc(v)+'</span>'; });
            nameHtml += '</span>';
          }
          html += '<span class="group-name">'+nameHtml+'</span>';
          html += '</div>';
          html += '<span class="group-count">'+g.count+' item'+(g.count!==1?'s':'')+'</span>';
          html += '</div>';

          html += '<div class="group-meta">';
          html += '<span>Material: '+esc(g.material)+'</span>';
          if (g.ifcType && g.ifcType !== '-') html += '<span>IFC: '+esc(g.ifcType)+'</span>';
          if (g.size && g.size !== '-') html += '<span>Size: '+esc(g.size)+'</span>';
          html += '</div>';

          // Guesses (collapsed view)
          html += '<div class="guesses" id="guesses-'+i+'"'+(isExp?' style="display:none"':'')+'>';
          if (g.guesses && g.guesses.length > 0) {
            g.guesses.forEach(function(guess, gi) {
              html += '<div class="guess">';
              html += '<input type="radio" name="guess-'+i+'" value="'+gi+'" id="g-'+i+'-'+gi+'"'+(gi===0?' checked':'')+' />';
              html += '<label class="guess-label" for="g-'+i+'-'+gi+'">';
              html += '<span class="guess-cat">'+esc(guess.category)+'</span> ';
              html += '<span class="guess-conf">'+guess.confidence+'%</span> ';
              html += '<span class="guess-source">('+esc(guess.source)+')</span>';
              html += '</label>';
              html += '</div>';
            });
          }
          // Other category option
          html += '<div class="guess">';
          html += '<input type="radio" name="guess-'+i+'" value="other" id="g-'+i+'-other" />';
          html += '<label for="g-'+i+'-other">+ Other category...</label>';
          html += '</div>';
          html += '<div class="custom-row" id="custom-'+i+'" style="display:none">';
          html += '<select id="catSel-'+i+'" onchange="onCatChange('+i+')">';
          html += '<option value="">-- Select --</option>';
          allCategories.forEach(function(c) {
            if (c !== '_IGNORE') html += '<option value="'+esc(c)+'">'+esc(c)+'</option>';
          });
          html += '</select>';
          html += '<select id="subSel-'+i+'"><option value="">No subcategory</option></select>';
          html += '</div>';
          html += '</div>';

          // Expandable sub-groups (for groups with 2+ variants)
          if (hasSubs) {
            html += '<div class="sub-groups'+(isExp?' visible':'')+'" id="subs-'+i+'">';
            g.subGroups.forEach(function(sg, j) {
              var bestGuess = (sg.guesses && sg.guesses.length > 0) ? sg.guesses[0] : null;
              var preCat = bestGuess ? (bestGuess.category || '') : '';
              var preSub = bestGuess ? (bestGuess.subcategory || '') : '';
              var subApplied = sg.applied ? ' applied' : '';
              html += '<div class="sub-row'+subApplied+'" id="sub-'+i+'-'+j+'">';
              html += '<input type="checkbox" class="sub-check" id="subChk-'+i+'-'+j+'"'+(sg.applied?' disabled':'')+' />';
              html += '<span class="sub-name">'+esc(sg.variantLabel)+'</span>';
              html += '<span class="sub-count">'+sg.count+' item'+(sg.count!==1?'s':'')+'</span>';
              html += '<select class="sub-cat-sel" id="subCat-'+i+'-'+j+'" onchange="onSubCatChange('+i+','+j+')">';
              html += catOptions(preCat);
              html += '</select>';
              html += '<select class="sub-sub-sel" id="subSub-'+i+'-'+j+'">';
              html += subOptions(preCat, preSub);
              html += '</select>';
              html += '</div>';
            });
            // Sub-group actions
            html += '<div class="sub-actions">';
            html += '<button class="btn-sel" onclick="selectAllSubs('+i+')">All</button>';
            html += '<button class="btn-sel" onclick="deselectAllSubs('+i+')">None</button>';
            html += '<button class="btn btn-apply" onclick="applyCheckedSubs('+i+')">Apply checked subs</button>';
            html += '<button class="btn btn-skip" onclick="applyGroup('+i+')">Apply all same</button>';
            html += '<span class="sub-info" id="subInfo-'+i+'">'+g.subGroups.length+' variants</span>';
            html += '</div>';
            html += '</div>';
          }

          // Actions (collapsed view)
          html += '<div class="group-actions" id="actions-'+i+'"'+(isExp && hasSubs?' style="display:none"':'')+'>';
          html += '<button class="btn btn-skip" onclick="skipGroup('+i+')">Skip</button>';
          html += '<button class="btn btn-apply" onclick="applyGroup('+i+')">Apply to all '+g.count+' item'+(g.count!==1?'s':'')+'</button>';
          html += '</div>';
          html += '</div>';
        });
        document.getElementById('groups').innerHTML = html;

        // Wire up "other" radio toggles
        GROUPS.forEach(function(g, i) {
          var radios = document.querySelectorAll('input[name="guess-'+i+'"]');
          radios.forEach(function(r) {
            r.addEventListener('change', function() {
              document.getElementById('custom-'+i).style.display = (this.value === 'other') ? 'flex' : 'none';
            });
          });
        });
      }

      function toggleExpand(i) {
        expandedGroups[i] = !expandedGroups[i];
        var isExp = expandedGroups[i];
        var subsEl = document.getElementById('subs-'+i);
        var guessEl = document.getElementById('guesses-'+i);
        var actEl = document.getElementById('actions-'+i);
        var btnEl = document.getElementById('expBtn-'+i);
        if (subsEl) subsEl.className = isExp ? 'sub-groups visible' : 'sub-groups';
        if (guessEl) guessEl.style.display = isExp ? 'none' : '';
        if (actEl) actEl.style.display = isExp ? 'none' : '';
        if (btnEl) btnEl.className = isExp ? 'expand-btn expanded' : 'expand-btn';
      }

      function onCatChange(i) {
        var cat = document.getElementById('catSel-'+i).value;
        var subSel = document.getElementById('subSel-'+i);
        subSel.innerHTML = '<option value="">No subcategory</option>';
        var subs = allSubcategories[cat] || [];
        subs.forEach(function(s) {
          subSel.innerHTML += '<option value="'+esc(s)+'">'+esc(s)+'</option>';
        });
      }

      function onSubCatChange(i, j) {
        var cat = document.getElementById('subCat-'+i+'-'+j).value;
        var subSel = document.getElementById('subSub-'+i+'-'+j);
        subSel.innerHTML = subOptions(cat, '');
      }

      function applyGroup(i) {
        var g = GROUPS[i];
        // If expanded, use the first sub-group's selected category as the "all same"
        if (expandedGroups[i] && g.subGroups && g.subGroups.length > 1) {
          var firstCat = document.getElementById('subCat-'+i+'-0');
          var firstSub = document.getElementById('subSub-'+i+'-0');
          var category = firstCat ? firstCat.value : '';
          var subcategory = firstSub ? firstSub.value : '';
          if (!category) { alert('Select a category in the first variant row'); return; }
          sketchup.applyGroup(JSON.stringify({
            groupIdx: i, category: category, subcategory: subcategory, costCode: ''
          }));
          return;
        }
        // Collapsed: use radio selection
        var selected = document.querySelector('input[name="guess-'+i+'"]:checked');
        if (!selected) return;

        var category = '', subcategory = '', costCode = '';
        if (selected.value === 'other') {
          category = document.getElementById('catSel-'+i).value;
          subcategory = document.getElementById('subSel-'+i).value;
        } else {
          var gi = parseInt(selected.value);
          var guess = g.guesses[gi];
          if (guess) {
            category = guess.category;
            subcategory = guess.subcategory || '';
            costCode = guess.cost_code || '';
          }
        }
        if (!category) { alert('Please select a category'); return; }

        sketchup.applyGroup(JSON.stringify({
          groupIdx: i, category: category, subcategory: subcategory, costCode: costCode
        }));
      }

      function skipGroup(i) {
        sketchup.skipGroup(i.toString());
      }

      function groupApplied(i) {
        GROUPS[i].applied = true;
        checkedGroups[i] = false;
        var el = document.getElementById('group-'+i);
        if (el) el.className = 'group-card applied';
        var cb = document.getElementById('check-'+i);
        if (cb) { cb.checked = false; cb.disabled = true; }
        classified++;
        updateProgress();
        updateBulkBar();
      }

      function updateProgress() {
        var remaining = total - classified;
        document.getElementById('remaining').textContent = remaining + ' groups remaining';
        document.getElementById('progress').textContent = classified + ' of ' + total + ' classified';
        if (remaining === 0) {
          document.getElementById('doneMsg').style.display = 'block';
        }
      }

      // ── Sub-group actions ──

      function selectAllSubs(i) {
        var g = GROUPS[i];
        if (!g.subGroups) return;
        g.subGroups.forEach(function(sg, j) {
          if (!sg.applied) {
            var cb = document.getElementById('subChk-'+i+'-'+j);
            if (cb) cb.checked = true;
          }
        });
      }

      function deselectAllSubs(i) {
        var g = GROUPS[i];
        if (!g.subGroups) return;
        g.subGroups.forEach(function(sg, j) {
          var cb = document.getElementById('subChk-'+i+'-'+j);
          if (cb) cb.checked = false;
        });
      }

      function applyCheckedSubs(i) {
        var g = GROUPS[i];
        if (!g.subGroups) return;
        var assignments = [];
        g.subGroups.forEach(function(sg, j) {
          if (sg.applied) return;
          var cb = document.getElementById('subChk-'+i+'-'+j);
          if (!cb || !cb.checked) return;
          var cat = document.getElementById('subCat-'+i+'-'+j).value;
          var sub = document.getElementById('subSub-'+i+'-'+j).value;
          if (!cat) return;
          assignments.push({ subIdx: j, category: cat, subcategory: sub || '' });
        });
        if (assignments.length === 0) { alert('Check sub-groups and select categories first'); return; }
        sketchup.applySubGroups(JSON.stringify({ groupIdx: i, assignments: assignments }));
      }

      function subGroupsApplied(i, appliedIndices) {
        var g = GROUPS[i];
        if (!g.subGroups) return;
        appliedIndices.forEach(function(j) {
          g.subGroups[j].applied = true;
          var row = document.getElementById('sub-'+i+'-'+j);
          if (row) row.className = 'sub-row applied';
          var cb = document.getElementById('subChk-'+i+'-'+j);
          if (cb) { cb.checked = false; cb.disabled = true; }
        });
        // Update info
        var remaining = g.subGroups.filter(function(sg) { return !sg.applied; }).length;
        var info = document.getElementById('subInfo-'+i);
        if (info) info.textContent = remaining + ' of ' + g.subGroups.length + ' remaining';
        // If all done, mark whole group
        if (remaining === 0) {
          groupApplied(i);
        }
      }

      // ── Bulk selection ──

      function selectAll() {
        GROUPS.forEach(function(g, i) {
          if (!g.applied) {
            var cb = document.getElementById('check-'+i);
            if (cb) { cb.checked = true; checkedGroups[i] = true; }
          }
        });
        updateBulkBar();
      }

      function deselectAll() {
        GROUPS.forEach(function(g, i) {
          var cb = document.getElementById('check-'+i);
          if (cb) { cb.checked = false; }
          checkedGroups[i] = false;
        });
        updateBulkBar();
      }

      function updateBulkBar() {
        var checkedCount = 0, itemCount = 0;
        GROUPS.forEach(function(g, i) {
          var cb = document.getElementById('check-'+i);
          checkedGroups[i] = (cb && cb.checked && !g.applied);
          if (checkedGroups[i]) {
            checkedCount++;
            itemCount += g.count;
          }
        });
        document.getElementById('bulkInfo').textContent =
          checkedCount + ' group' + (checkedCount !== 1 ? 's' : '') + ' checked (' + itemCount + ' items)';
        var btn = document.getElementById('bulkApplyBtn');
        var hasCat = !!document.getElementById('bulkCatSel').value;
        btn.disabled = (checkedCount === 0 || !hasCat);
        btn.textContent = checkedCount > 0
          ? 'Apply to ' + checkedCount + ' group' + (checkedCount !== 1 ? 's' : '') + ' (' + itemCount + ' items)'
          : 'Apply to checked';
      }

      function onBulkCatChange() {
        var cat = document.getElementById('bulkCatSel').value;
        var subSel = document.getElementById('bulkSubSel');
        subSel.innerHTML = '<option value="">No subcategory</option>';
        var subs = allSubcategories[cat] || [];
        subs.forEach(function(s) {
          subSel.innerHTML += '<option value="'+esc(s)+'">'+esc(s)+'</option>';
        });
        updateBulkBar();
      }

      function applyBulk() {
        var cat = document.getElementById('bulkCatSel').value;
        if (!cat) { alert('Select a category first'); return; }
        var sub = document.getElementById('bulkSubSel').value;
        var indices = [];
        GROUPS.forEach(function(g, i) {
          if (checkedGroups[i] && !g.applied) indices.push(i);
        });
        if (indices.length === 0) return;

        sketchup.applyBulk(JSON.stringify({
          groupIndices: indices,
          category: cat,
          subcategory: sub || ''
        }));
      }

      function allDone() {
        document.getElementById('doneMsg').style.display = 'block';
      }

      function finish() {
        sketchup.finishAll();
      }

      function esc(s) {
        if (!s) return '';
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
      }

      init();
      </script>
      </body>
      </html>
      HTML
    end
  end
end
