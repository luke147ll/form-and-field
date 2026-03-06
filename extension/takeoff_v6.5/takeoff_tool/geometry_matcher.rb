module TakeoffTool
  module GeometryMatcher

    # ═══════════════════════════════════════════════════════════
    # Constants
    # ═══════════════════════════════════════════════════════════

    TIER_AUTO     = 70   # pct threshold — auto-assign
    TIER_PROBABLE = 42   # pct threshold — flag for review
    TIER_LOW      = 17   # pct threshold — low match
    APPLY_BATCH_SIZE = 50

    @reference_library = {}   # { 'Category' => [{ fingerprint:, material:, ifc_type:, entity_count: }] }
    @review_mr = nil          # match results for active review dialog
    @review_dlg = nil         # HtmlDialog reference
    @accepted_groups = {}     # { "tier|category" => true }

    # ═══════════════════════════════════════════════════════════
    # Fingerprint — geometry signature for a scan result
    # ═══════════════════════════════════════════════════════════

    def self.compute_fingerprint(r)
      w = (r[:bb_width_in] || 0).to_f
      h = (r[:bb_height_in] || 0).to_f
      d = (r[:bb_depth_in] || 0).to_f
      vol = (r[:volume_in3] || 0).to_f

      dims = [w, h, d].sort
      dims = dims.map { |v| v.round(1) }

      d0, d1, d2 = dims
      safe_d0 = [d0, 0.01].max

      aspect_wh = (d1 / safe_d0).round(3)
      aspect_wd = (d2 / safe_d0).round(3)
      aspect_hd = d1 > 0.01 ? (d2 / d1).round(3) : 0.0

      # Shape classification
      ratio_longest_shortest = d2 / safe_d0
      ratio_middle_shortest  = d1 / safe_d0
      shape = if ratio_longest_shortest > 6 && ratio_middle_shortest < 3
                :linear
              elsif ratio_longest_shortest > 4 && ratio_middle_shortest > 3
                :flat
              else
                :cubic
              end

      # Thickness bucket (shortest dim)
      thickness = if d0 <= 1.0
                    :thin
                  elsif d0 <= 4.0
                    :medium_t
                  elsif d0 <= 12.0
                    :thick
                  else
                    :massive
                  end

      {
        dims_sorted: dims,
        volume: vol,
        aspect_wh: aspect_wh,
        aspect_wd: aspect_wd,
        aspect_hd: aspect_hd,
        shape_type: shape,
        thickness_bucket: thickness
      }
    end

    # ═══════════════════════════════════════════════════════════
    # Reference Library — build from Model A categorized entities
    # ═══════════════════════════════════════════════════════════

    def self.build_reference_library(scan_results, category_assignments, entity_registry)
      @reference_library = {}

      # Filter to Model A entities only
      a_results = scan_results.select do |r|
        eid = r[:entity_id]
        ent = entity_registry[eid]
        next false unless ent && ent.valid?
        src = ent.get_attribute('FormAndField', 'model_source') rescue 'model_a'
        src.nil? || src == 'model_a'
      end

      # Group by assigned category
      grouped = {}
      a_results.each do |r|
        eid = r[:entity_id]
        cat = category_assignments[eid] || (r[:parsed] && r[:parsed][:auto_category])
        next if cat.nil? || cat == '_IGNORE' || cat == 'Uncategorized'
        grouped[cat] ||= []
        grouped[cat] << r
      end

      # Build fingerprints per category, deduplicating
      grouped.each do |cat, results|
        seen_keys = {}
        entries = []

        results.each do |r|
          fp = compute_fingerprint(r)
          key = "#{fp[:dims_sorted]}|#{fp[:shape_type]}|#{fp[:thickness_bucket]}"

          if seen_keys[key]
            seen_keys[key][:entity_count] += 1
          else
            entry = {
              fingerprint: fp,
              material: (r[:material] || '').to_s,
              ifc_type: (r[:ifc_type] || '').to_s,
              entity_count: 1
            }
            seen_keys[key] = entry
            entries << entry
          end
        end

        @reference_library[cat] = entries
      end

      total_fps = @reference_library.values.map(&:length).sum
      puts "GeometryMatcher: Reference library built — #{@reference_library.keys.length} categories, #{total_fps} fingerprints"
      @reference_library
    end

    # ═══════════════════════════════════════════════════════════
    # Scoring — compare two fingerprints
    # ═══════════════════════════════════════════════════════════

    def self.compute_score(b_fp, ref_fp, b_mat, ref_mat, b_ifc, ref_ifc)
      score = 0.0

      # Dim similarity (0-3): per dim difference ratio
      b_dims = b_fp[:dims_sorted]
      r_dims = ref_fp[:dims_sorted]
      3.times do |i|
        b_v = b_dims[i].to_f
        r_v = r_dims[i].to_f
        denom = [b_v, r_v, 1.0].max
        score += 1.0 - [((b_v - r_v).abs / denom), 1.0].min
      end

      # Volume similarity (0-2)
      b_vol = b_fp[:volume].to_f
      r_vol = ref_fp[:volume].to_f
      vol_denom = [b_vol, r_vol, 1.0].max
      score += 2.0 * (1.0 - [((b_vol - r_vol).abs / vol_denom), 1.0].min)

      # Aspect ratio match (0-3)
      [:aspect_wh, :aspect_wd, :aspect_hd].each do |key|
        b_a = b_fp[key].to_f
        r_a = ref_fp[key].to_f
        denom = [b_a, r_a, 0.01].max
        score += 1.0 - [((b_a - r_a).abs / denom), 1.0].min
      end

      # Shape type match (0-1)
      score += 1.0 if b_fp[:shape_type] == ref_fp[:shape_type]

      # Thickness bucket (0-1)
      score += 1.0 if b_fp[:thickness_bucket] == ref_fp[:thickness_bucket]

      # Material bonus (0-1): case-insensitive substring overlap
      b_m = (b_mat || '').to_s.downcase.strip
      r_m = (ref_mat || '').to_s.downcase.strip
      if !b_m.empty? && !r_m.empty? && (b_m.include?(r_m) || r_m.include?(b_m))
        score += 1.0
      end

      # IFC type bonus (0-1): exact match, both non-empty
      b_i = (b_ifc || '').to_s.strip
      r_i = (ref_ifc || '').to_s.strip
      if !b_i.empty? && !r_i.empty? && b_i == r_i
        score += 1.0
      end

      score
    end

    def self.score_to_pct(score)
      pct = (score / 12.0 * 100).round(0)
      [[pct, 0].max, 100].min
    end

    def self.tier_for_pct(pct)
      if pct >= TIER_AUTO
        :auto
      elsif pct >= TIER_PROBABLE
        :probable
      elsif pct >= TIER_LOW
        :low
      else
        :no_match
      end
    end

    # ═══════════════════════════════════════════════════════════
    # Match Model B — score all B entities vs reference library
    # ═══════════════════════════════════════════════════════════

    def self.match_model_b(b_results, all_scan_results, category_assignments, entity_registry)
      return nil if @reference_library.empty?

      tiers = { auto: [], probable: [], low: [], no_match: [] }
      skipped = 0

      b_results.each do |r|
        # Skip high-confidence entities
        conf = InteractiveScanner.confidence_pct(r) rescue 0
        if conf >= 85
          skipped += 1
          next
        end

        b_fp = compute_fingerprint(r)
        b_mat = (r[:material] || '').to_s
        b_ifc = (r[:ifc_type] || '').to_s

        best_cat = nil
        best_pct = 0

        @reference_library.each do |cat, entries|
          entries.each do |entry|
            raw = compute_score(b_fp, entry[:fingerprint], b_mat, entry[:material], b_ifc, entry[:ifc_type])
            pct = score_to_pct(raw)
            if pct > best_pct
              best_pct = pct
              best_cat = cat
            end
          end
        end

        tier = best_cat ? tier_for_pct(best_pct) : :no_match

        match_entry = {
          entity_id: r[:entity_id],
          display_name: r[:display_name] || r[:definition_name] || '',
          material: b_mat,
          current_category: (r[:parsed] && r[:parsed][:auto_category]) || 'Uncategorized',
          suggested_category: best_cat,
          score_pct: best_pct,
          tier: tier
        }

        tiers[tier] << match_entry
      end

      # Build grouped tiers (by suggested category)
      grouped = {}
      tiers.each do |tier_key, entries|
        grouped[tier_key] = {}
        entries.each do |e|
          cat = e[:suggested_category] || 'Unknown'
          grouped[tier_key][cat] ||= { count: 0, pct_sum: 0, entity_ids: [], entities: [] }
          g = grouped[tier_key][cat]
          g[:count] += 1
          g[:pct_sum] += e[:score_pct]
          g[:entity_ids] << e[:entity_id]
          g[:entities] << e
        end
        # Compute averages
        grouped[tier_key].each do |_cat, g|
          g[:pct_avg] = g[:count] > 0 ? (g[:pct_sum].to_f / g[:count]).round(0) : 0
          g.delete(:pct_sum)
        end
      end

      total = tiers.values.map(&:length).sum
      {
        total_matched: total,
        auto_count: tiers[:auto].length,
        probable_count: tiers[:probable].length,
        low_count: tiers[:low].length,
        no_match_count: tiers[:no_match].length,
        skipped_count: skipped,
        tiers: tiers,
        grouped_tiers: grouped
      }
    end

    # ═══════════════════════════════════════════════════════════
    # Alignment Review Dialog
    # ═══════════════════════════════════════════════════════════

    def self.show_alignment_review(match_results)
      puts "[FF Align] Step 0: show_alignment_review called — total=#{match_results[:total_matched]} auto=#{match_results[:auto_count]} probable=#{match_results[:probable_count]} low=#{match_results[:low_count]} no_match=#{match_results[:no_match_count]}"
      puts "[FF Align] Step 0: grouped_tiers keys=#{match_results[:grouped_tiers]&.keys&.inspect}"

      @review_mr = match_results
      @accepted_groups = {}

      if @review_dlg && @review_dlg.visible?
        @review_dlg.close
      end

      @review_dlg = UI::HtmlDialog.new(
        dialog_title: "Form and Field — Alignment Review",
        preferences_key: "TakeoffAlignmentReview",
        width: 620, height: 700,
        left: 200, top: 100,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      # Register callbacks BEFORE set_file — HTML may load and fire onload
      # before show() returns, so callbacks must exist first
      register_review_callbacks(@review_dlg)
      puts "[FF Align] Step 0: Callbacks registered"

      html_path = File.join(PLUGIN_DIR, 'ui', 'alignment_review.html')
      puts "[FF Align] Step 0: HTML path=#{html_path} exists=#{File.exist?(html_path)}"
      @review_dlg.set_file(html_path)

      @review_dlg.show
      puts "[FF Align] Step 0: Dialog shown"

      # Backup: proactively inject data after 0.8s in case JS→Ruby callback fails
      UI.start_timer(0.8, false) do
        if @review_dlg && @review_dlg.visible? && @review_mr
          puts "[FF Align] Backup timer fired — injecting data proactively"
          inject_alignment_data
        else
          puts "[FF Align] Backup timer fired — dlg=#{!!@review_dlg} visible=#{@review_dlg&.visible?} mr=#{!!@review_mr}"
        end
      end
    end

    def self.register_review_callbacks(dlg)
      dlg.add_action_callback('jsError') do |_ctx, msg|
        puts "[FF Align] JS ERROR: #{msg}"
      end

      dlg.add_action_callback('requestAlignmentData') do |_ctx|
        puts "[FF Align] Step 1: requestAlignmentData callback triggered"
        puts "[FF Align] Step 1: @review_mr=#{@review_mr.nil? ? 'NIL' : 'present'} @review_dlg=#{@review_dlg.nil? ? 'NIL' : 'present'}"
        inject_alignment_data
      end

      dlg.add_action_callback('acceptAutoMatched') do |_ctx|
        gt = @review_mr[:grouped_tiers][:auto] || {}
        gt.each do |cat, _group|
          @accepted_groups["auto|#{cat}"] = true
        end
        puts "GeometryMatcher: Accepted all auto-matched (#{gt.keys.length} categories)"
        dlg.execute_script("onAutoAccepted()")
      end

      dlg.add_action_callback('acceptGroup') do |_ctx, json_str|
        data = JSON.parse(json_str) rescue {}
        tier = data['tier'].to_s
        cat = data['category'].to_s
        @accepted_groups["#{tier}|#{cat}"] = true
        puts "GeometryMatcher: Accepted #{tier}/#{cat}"
        dlg.execute_script("onGroupAccepted('#{esc_js(tier)}','#{esc_js(cat)}')")
      end

      dlg.add_action_callback('rejectGroup') do |_ctx, json_str|
        data = JSON.parse(json_str) rescue {}
        tier = data['tier'].to_s
        cat = data['category'].to_s
        @accepted_groups.delete("#{tier}|#{cat}")
        puts "GeometryMatcher: Rejected #{tier}/#{cat}"
        dlg.execute_script("onGroupRejected('#{esc_js(tier)}','#{esc_js(cat)}')")
      end

      dlg.add_action_callback('highlightGroup') do |_ctx, json_str|
        eids = JSON.parse(json_str) rescue []
        if eids.is_a?(Array) && eids.any?
          Highlighter.highlight_entities(eids.map(&:to_i))
        end
      end

      dlg.add_action_callback('clearHighlights') do |_ctx|
        Highlighter.show_all
      end

      dlg.add_action_callback('skipReview') do |_ctx|
        puts "GeometryMatcher: Review skipped — parser results unchanged"
        dlg.close
      end

      dlg.add_action_callback('applyAndCompare') do |_ctx|
        dlg.close
        apply_accepted_matches
      end
    end

    # ═══════════════════════════════════════════════════════════
    # Inject data into the dialog as JSON
    # ═══════════════════════════════════════════════════════════

    def self.inject_alignment_data
      puts "[FF Align] Step 2: inject_alignment_data called"

      unless @review_dlg
        puts "[FF Align] ABORT: no dialog ref (@review_dlg is nil)"
        return
      end
      unless @review_mr
        puts "[FF Align] ABORT: no match results (@review_mr is nil)"
        return
      end

      puts "[FF Align] Step 2: @review_mr has #{@review_mr[:total_matched]} total, grouped_tiers=#{@review_mr[:grouped_tiers]&.keys&.inspect}"

      data = {
        total_matched: @review_mr[:total_matched],
        auto_count: @review_mr[:auto_count],
        probable_count: @review_mr[:probable_count],
        low_count: @review_mr[:low_count],
        no_match_count: @review_mr[:no_match_count],
        skipped_count: @review_mr[:skipped_count],
        tiers: {}
      }

      @review_mr[:grouped_tiers].each do |tier_key, groups|
        tier_data = {}
        groups.each do |cat, g|
          tier_data[cat] = {
            count: g[:count],
            pct_avg: g[:pct_avg],
            entity_ids: g[:entity_ids]
          }
        end
        data[:tiers][tier_key.to_s] = tier_data
      end

      puts "[FF Align] Step 3: Data built — #{data[:tiers].keys.length} tiers, categories: #{data[:tiers].map { |k, v| "#{k}(#{v.keys.length})" }.join(', ')}"

      require 'json'
      json = JSON.generate(data)
      puts "[FF Align] Step 4: JSON generated — #{json.length} chars"

      # Pass JSON directly as JS object literal — no JSON.parse wrapping,
      # no single-quote escaping. JSON is valid JavaScript.
      script = "renderAlignmentData(#{json});"
      puts "[FF Align] Step 5: Sending execute_script (#{script.length} chars)"
      @review_dlg.execute_script(script)
      puts "[FF Align] Step 6: execute_script completed"
    rescue => e
      puts "[FF Align] ERROR in inject_alignment_data: #{e.class}: #{e.message}"
      puts e.backtrace.first(5).join("\n") if e.backtrace
    end

    # ═══════════════════════════════════════════════════════════
    # Apply accepted matches — batched via UI.start_timer
    # ═══════════════════════════════════════════════════════════

    def self.apply_accepted_matches
      return unless @review_mr

      # Collect all accepted entity reassignments
      to_apply = []  # [{ entity_id:, category:, tier: }]

      @accepted_groups.each do |key, _|
        tier_str, cat = key.split('|', 2)
        tier_sym = tier_str.to_sym
        group = @review_mr[:grouped_tiers][tier_sym] && @review_mr[:grouped_tiers][tier_sym][cat]
        next unless group

        group[:entity_ids].each do |eid|
          to_apply << { entity_id: eid, category: cat, tier: tier_sym }
        end
      end

      if to_apply.empty?
        puts "GeometryMatcher: No accepted matches to apply"
        refresh_after_apply
        return
      end

      puts "GeometryMatcher: Applying #{to_apply.length} entity reclassifications..."

      batches = to_apply.each_slice(APPLY_BATCH_SIZE).to_a
      process_apply_batch(batches, 0)
    end

    def self.process_apply_batch(batches, idx)
      return finalize_apply if idx >= batches.length

      batch = batches[idx]
      batch.each do |item|
        eid = item[:entity_id]
        cat = item[:category]

        # Update category assignment
        TakeoffTool.category_assignments[eid] = cat

        # Persist to entity attribute
        TakeoffTool.save_assignment(eid, 'category', cat)

        # Log the change
        RecatLog.log_change(eid, cat) rescue nil

        # Update scan result in-place
        sr = TakeoffTool.scan_results.find { |r| r[:entity_id] == eid }
        if sr && sr[:parsed]
          sr[:parsed][:auto_category] = cat
        end
      end

      # Schedule next batch
      UI.start_timer(0.01, false) do
        process_apply_batch(batches, idx + 1)
      end
    end

    def self.finalize_apply
      puts "GeometryMatcher: All matches applied"

      # Capture learning rules per accepted group
      @accepted_groups.each do |key, _|
        tier_str, cat = key.split('|', 2)
        tier_sym = tier_str.to_sym
        group = @review_mr[:grouped_tiers][tier_sym] && @review_mr[:grouped_tiers][tier_sym][cat]
        next unless group

        LearningSystem.capture_geometry_match(
          group[:entity_ids], cat, nil, TakeoffTool.scan_results
        ) rescue nil
      end

      refresh_after_apply
    end

    def self.refresh_after_apply
      # Refresh dashboard
      if Dashboard.visible?
        Dashboard.send_data(
          TakeoffTool.scan_results,
          TakeoffTool.category_assignments,
          TakeoffTool.cost_code_assignments
        )
      end

      # Auto-compare
      compute_quantity_delta rescue nil
    end

    # ═══════════════════════════════════════════════════════════
    # Helpers
    # ═══════════════════════════════════════════════════════════

    def self.esc_js(s)
      s.to_s.gsub('\\', '\\\\').gsub("'", "\\\\'").gsub("\n", "\\n")
    end

  end
end
