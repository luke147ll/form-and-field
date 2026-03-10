module TakeoffTool
  module LearningSystem

    @rules = nil
    @rules_path = File.join(PLUGIN_DIR, 'data', 'learned_rules.json')

    # ═══════════════════════════════════════════════════════════
    # Load / Save
    # ═══════════════════════════════════════════════════════════

    def self.load_rules(force: false)
      return @rules if @rules && !force
      require 'json'
      if File.exist?(@rules_path)
        @rules = JSON.parse(File.read(@rules_path))
        puts "LearningSystem: Loaded #{@rules.length} learned rules"
      else
        @rules = []
      end
      @rules
    rescue => e
      puts "LearningSystem: Error loading rules: #{e.message}"
      @rules = []
    end

    def self.save_rules
      require 'json'
      dir = File.dirname(@rules_path)
      Dir.mkdir(dir) unless File.directory?(dir)
      File.write(@rules_path, JSON.pretty_generate(@rules))
    rescue => e
      puts "LearningSystem: Error saving rules: #{e.message}"
    end

    # ═══════════════════════════════════════════════════════════
    # Capture — called when user reclassifies an entity
    #
    # Parameters:
    #   entity_id    — the entity being reclassified
    #   old_category — previous category
    #   new_category — new category assigned by user
    #   new_subcategory — new subcategory (optional)
    #   new_cost_code   — cost code (optional)
    # ═══════════════════════════════════════════════════════════

    def self.capture(entity_id, old_category, new_category, new_subcategory: nil, new_cost_code: nil, rule_keyword: nil)
      load_rules unless @rules

      # Skip learning from trivial moves (to Uncategorized, from same)
      return if new_category == old_category
      return if new_category == 'Uncategorized' || new_category == '_IGNORE'

      # Find the entity's scan data to extract patterns
      sr = TakeoffTool.scan_results || []
      entity_data = sr.find { |r| r[:entity_id] == entity_id.to_i }
      return unless entity_data

      display_name = entity_data[:display_name] || ''
      material = entity_data[:material] || ''
      ifc_type = entity_data[:ifc_type] || ''
      definition_name = entity_data[:definition_name] || ''

      # Use explicit keyword if provided (from HP trainer), otherwise auto-extract
      keyword = rule_keyword && !rule_keyword.strip.empty? ? rule_keyword.strip : extract_keyword(display_name, definition_name)
      return if keyword.nil? || keyword.empty?

      # Check for existing matching rule — deduplicate
      existing = @rules.find do |r|
        r['keyword'] == keyword &&
        r['to_category'] == new_category &&
        (r['material'].to_s == material.to_s || r['material'].to_s.empty?)
      end

      if existing
        # Increment times_applied
        existing['times_applied'] = (existing['times_applied'] || 1) + 1
        existing['to_subcategory'] = new_subcategory if new_subcategory && !new_subcategory.empty?
        existing['to_cost_code'] = new_cost_code if new_cost_code && !new_cost_code.empty?
        existing['last_applied'] = Time.now.strftime('%Y-%m-%d')
        puts "LearningSystem: Updated rule '#{keyword}' -> '#{new_category}' (#{existing['times_applied']}x)"
      else
        # Create new rule
        rule = {
          'keyword' => keyword,
          'material' => material.to_s,
          'ifc_type' => ifc_type.to_s,
          'size_pattern' => (entity_data[:parsed][:size_nominal] || '').to_s,
          'from_category' => old_category.to_s,
          'to_category' => new_category.to_s,
          'to_subcategory' => (new_subcategory || '').to_s,
          'to_cost_code' => (new_cost_code || '').to_s,
          'times_applied' => 1,
          'created' => Time.now.strftime('%Y-%m-%d'),
          'last_applied' => Time.now.strftime('%Y-%m-%d')
        }
        @rules << rule
        puts "LearningSystem: New rule '#{keyword}' -> '#{new_category}'"
      end

      save_rules
    end

    # ═══════════════════════════════════════════════════════════
    # Apply — check an entity against learned rules during scan
    #
    # Returns a parse result hash or nil
    # ═══════════════════════════════════════════════════════════

    def self.apply(display, mat, ifc_type, definition_name: nil)
      load_rules unless @rules
      return nil if @rules.empty?

      text = display.to_s.downcase
      mat_str = (mat || '').to_s.downcase
      ifc_str = (ifc_type || '').to_s

      best = nil
      best_score = 0

      @rules.each do |rule|
        score = 0

        # Multi-keyword AND matching (keywords array) or single keyword
        keywords = rule['keywords']
        if keywords.is_a?(Array) && !keywords.empty?
          all_match = keywords.all? { |k| text.include?(k.to_s.downcase) }
          next unless all_match
          score += 10 + (keywords.length * 3)  # bonus for more specific rules
        else
          kw = rule['keyword'].to_s.downcase
          next unless !kw.empty? && text.include?(kw)
          score += 10
        end

        # Material bonus
        rule_mat = rule['material'].to_s.downcase
        if !rule_mat.empty? && !mat_str.empty? && mat_str.include?(rule_mat)
          score += 5
        end

        # IFC type bonus
        rule_ifc = rule['ifc_type'].to_s
        if !rule_ifc.empty? && rule_ifc == ifc_str
          score += 3
        end

        # Times applied bonus (more uses = more trusted)
        times = rule['times_applied'] || 1
        score += [times, 10].min

        if score > best_score
          best_score = score
          best = rule
        end
      end

      return nil unless best

      kw_display = best['keywords'].is_a?(Array) ? best['keywords'].join('+') : best['keyword']
      mt = Parser.measurement_for(best['to_category'])
      {
        raw: display.to_s,
        element_type: nil,
        function: nil,
        material: mat,
        thickness: nil,
        size_nominal: nil,
        revit_id: nil,
        auto_category: best['to_category'],
        auto_subcategory: best['to_subcategory'].to_s.empty? ? nil : best['to_subcategory'],
        measurement_type: mt,
        category_source: 'learned',
        confidence: :high,
        cost_code: best['to_cost_code'].to_s.empty? ? nil : best['to_cost_code'],
        learned_keyword: kw_display,
        learned_times: best['times_applied']
      }
    end

    # ═══════════════════════════════════════════════════════════
    # Capture from geometry matching — called per accepted group
    # ═══════════════════════════════════════════════════════════

    def self.capture_geometry_match(entity_ids, to_category, to_subcategory, scan_results)
      load_rules unless @rules
      return if to_category.nil? || to_category.empty?

      entity_data = scan_results.find { |r| entity_ids.include?(r[:entity_id]) }
      return unless entity_data

      display_name = entity_data[:display_name] || ''
      definition_name = entity_data[:definition_name] || ''
      keyword = extract_keyword(display_name, definition_name)
      return if keyword.nil? || keyword.empty?

      existing = @rules.find { |r| r['keyword'] == keyword && r['to_category'] == to_category }
      if existing
        existing['times_applied'] = (existing['times_applied'] || 1) + 1
        existing['last_applied'] = Time.now.strftime('%Y-%m-%d')
        puts "LearningSystem: Updated geometry rule '#{keyword}' -> '#{to_category}' (#{existing['times_applied']}x)"
      else
        @rules << {
          'keyword' => keyword,
          'material' => (entity_data[:material] || '').to_s,
          'ifc_type' => (entity_data[:ifc_type] || '').to_s,
          'source' => 'geometry_match',
          'from_category' => ((entity_data[:parsed] && entity_data[:parsed][:auto_category]) || 'Uncategorized').to_s,
          'to_category' => to_category.to_s,
          'to_subcategory' => (to_subcategory || '').to_s,
          'to_cost_code' => '',
          'times_applied' => 1,
          'created' => Time.now.strftime('%Y-%m-%d'),
          'last_applied' => Time.now.strftime('%Y-%m-%d')
        }
        puts "LearningSystem: New geometry rule '#{keyword}' -> '#{to_category}'"
      end

      save_rules
    end

    # ═══════════════════════════════════════════════════════════
    # Management API
    # ═══════════════════════════════════════════════════════════

    def self.all_rules
      load_rules unless @rules
      @rules.dup
    end

    def self.rule_count
      load_rules unless @rules
      @rules.length
    end

    def self.delete_rule(index)
      load_rules unless @rules
      return false if index < 0 || index >= @rules.length
      removed = @rules.delete_at(index)
      save_rules
      puts "LearningSystem: Deleted rule '#{removed['keyword']}'"
      true
    end

    def self.clear_all
      @rules = []
      save_rules
      puts "LearningSystem: All rules cleared"
    end

    # ═══════════════════════════════════════════════════════════
    # Create custom rule — multi-keyword AND matching
    # ═══════════════════════════════════════════════════════════

    def self.create_custom_rule(keywords_str, to_category, to_subcategory: '', to_cost_code: '', match_field: 'name')
      load_rules unless @rules

      keywords = keywords_str.to_s.split(/[+,]/).map(&:strip).reject(&:empty?).map(&:downcase)
      return { ok: false, error: 'No keywords provided' } if keywords.empty?
      return { ok: false, error: 'No category selected' } if to_category.nil? || to_category.empty?

      # Check for duplicate
      existing = @rules.find do |r|
        r['keywords'].is_a?(Array) && r['keywords'].sort == keywords.sort && r['to_category'] == to_category
      end
      if existing
        return { ok: false, error: "Rule already exists: #{keywords.join('+')} -> #{to_category}" }
      end

      rule = {
        'keywords' => keywords,
        'keyword' => keywords.join('+'),  # backward-compat display
        'match_field' => match_field,
        'material' => '',
        'ifc_type' => '',
        'source' => 'custom_rule',
        'from_category' => '',
        'to_category' => to_category.to_s,
        'to_subcategory' => (to_subcategory || '').to_s,
        'to_cost_code' => (to_cost_code || '').to_s,
        'times_applied' => 0,
        'created' => Time.now.strftime('%Y-%m-%d'),
        'last_applied' => ''
      }
      @rules << rule
      save_rules
      puts "LearningSystem: Custom rule '#{keywords.join('+')}' -> '#{to_category}'"
      { ok: true, rule: rule, index: @rules.length - 1 }
    end

    # Preview which entities match a set of keywords (for live preview)
    def self.preview_matches(keywords_str)
      sr = TakeoffTool.scan_results || []
      return [] if sr.empty?

      keywords = keywords_str.to_s.split(/[+,]/).map(&:strip).reject(&:empty?).map(&:downcase)
      return [] if keywords.empty?

      matches = []
      sr.each do |r|
        text = (r[:display_name] || r[:definition_name] || '').to_s.downcase
        next if text.empty?
        next unless keywords.all? { |kw| text.include?(kw) }

        cat = TakeoffTool.category_assignments[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        matches << {
          eid: r[:entity_id],
          name: (r[:display_name] || r[:definition_name] || '')[0..80],
          current_cat: cat
        }
      end
      matches
    end

    # ═══════════════════════════════════════════════════════════
    # Rule Builder Dialog
    # ═══════════════════════════════════════════════════════════

    @rule_builder_dlg = nil

    def self.show_rule_builder
      load_rules unless @rules

      containers = TakeoffTool.master_containers || []
      subs = TakeoffTool.master_subcategories || {}

      require 'json'
      containers_json = JSON.generate(containers)
      subs_json = JSON.generate(subs)
      rules_json = JSON.generate(@rules)

      html = rule_builder_html(containers_json, subs_json, rules_json)

      if @rule_builder_dlg
        @rule_builder_dlg.close rescue nil
      end

      @rule_builder_dlg = UI::HtmlDialog.new(
        dialog_title: "Form and Field — Rule Builder",
        preferences_key: "TakeoffRuleBuilder",
        width: 800, height: 600,
        left: 100, top: 100,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @rule_builder_dlg.add_action_callback('preview') do |_ctx, keywords_str|
        matches = preview_matches(keywords_str)
        require 'json'
        safe = JSON.generate(matches).gsub('</') { '<\\/' }
        @rule_builder_dlg.execute_script("receivePreview(#{safe})")
      end

      @rule_builder_dlg.add_action_callback('createRule') do |_ctx, json_str|
        require 'json'
        data = JSON.parse(json_str.to_s)
        result = create_custom_rule(
          data['keywords'],
          data['category'],
          to_subcategory: data['subcategory'],
          to_cost_code: data['costCode'],
          match_field: data['matchField'] || 'name'
        )
        safe = JSON.generate(result).gsub('</') { '<\\/' }
        @rule_builder_dlg.execute_script("receiveCreateResult(#{safe})")
        # Refresh rules list
        refresh_rules_in_builder
      end

      @rule_builder_dlg.add_action_callback('deleteRule') do |_ctx, idx_str|
        idx = idx_str.to_s.to_i
        if delete_rule(idx)
          refresh_rules_in_builder
        end
      end

      @rule_builder_dlg.add_action_callback('testRules') do |_ctx|
        sr = TakeoffTool.scan_results || []
        hits = 0
        sr.each do |r|
          display = (r[:display_name] || r[:definition_name] || '').to_s
          mat = (r[:material] || '').to_s
          ifc = (r[:ifc_type] || '').to_s
          result = apply(display, mat, ifc)
          hits += 1 if result
        end
        @rule_builder_dlg.execute_script("receiveTestResult(#{hits}, #{sr.length})")
      end

      @rule_builder_dlg.set_html(html)
      @rule_builder_dlg.show
    end

    def self.refresh_rules_in_builder
      return unless @rule_builder_dlg
      require 'json'
      safe = JSON.generate(@rules).gsub('</') { '<\\/' }
      @rule_builder_dlg.execute_script("receiveRules(#{safe})")
    end

    # ═══════════════════════════════════════════════════════════
    # Show management dialog
    # ═══════════════════════════════════════════════════════════

    def self.show_dialog
      load_rules unless @rules

      if @rules.empty?
        UI.messagebox("No learned rules yet.\n\nRules are created automatically when you reclassify entities.\nThey help the parser learn your preferences for future scans.")
        return
      end

      # Build HTML for the dialog
      html = build_dialog_html
      dlg = UI::HtmlDialog.new(
        dialog_title: "Form and Field — Learned Rules",
        preferences_key: "TakeoffLearnedRules",
        width: 700, height: 500,
        left: 150, top: 150,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      dlg.add_action_callback('deleteRule') do |_ctx, idx_str|
        idx = idx_str.to_s.to_i
        if delete_rule(idx)
          # Refresh
          new_html = build_rules_table_html
          esc = new_html.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\n")
          dlg.execute_script("document.getElementById('rulesTable').innerHTML='#{esc}'")
        end
      end

      dlg.add_action_callback('clearAll') do |_ctx|
        r = UI.messagebox("Delete ALL learned rules?\n\nThis cannot be undone.", MB_YESNO)
        if r == IDYES
          clear_all
          new_html = '<tr><td colspan="7" style="text-align:center;padding:20px;color:#888">All rules cleared</td></tr>'
          esc = new_html.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\n")
          dlg.execute_script("document.getElementById('rulesTable').innerHTML='#{esc}'")
        end
      end

      dlg.set_html(html)
      dlg.show
    end

    private

    # Extract a general keyword from the display/definition name.
    # Goal: broad enough to match similar entities, specific enough to avoid false positives.
    # Examples:
    #   "Bath_Accessory-Delta-Ara-Towel_Bar-77518, 18" Chrome" → "Bath_Accessory"
    #   "Basic Wall, Finish - Tile on CMU" → "Finish - Tile"
    #   "M_Toilet-Commercial-Wall Mounted, Type A" → "M_Toilet"
    # Detect Revit GUIDs: "ace8a45d-794c-4d45-b..." or plain hex "8db9691d"
    GUID_RE = /^[0-9a-f]{8}(-[0-9a-f]{4,})+$/i
    HEX_ONLY_RE = /^[0-9a-f]{6,}$/i

    def self.guid?(s)
      s = s.to_s.strip
      s.match?(GUID_RE) || s.match?(HEX_ONLY_RE)
    end

    def self.extract_keyword(display_name, definition_name)
      # Prefer display_name for keyword extraction — it contains meaningful
      # Revit type names. Definition names are usually GUIDs (handled by
      # the template definition_map for same-project matching instead).
      dname = definition_name.to_s.strip
      name = display_name.to_s.strip
      # Fall back to definition_name only if display_name is empty AND it's not a GUID
      if name.empty?
        return nil if dname.empty? || guid?(dname)
        name = dname
      end

      # Strip trailing Revit hex instance ID (last comma segment)
      parts = name.split(',').map(&:strip)
      parts.pop if parts.last && parts.last.match?(/^[0-9A-Fa-f]+$/)

      # For "Basic Wall, Foundation - Concrete - 2"" → use detail after "Basic X,"
      if name =~ /^Basic (?:Wall|Roof|Floor),?\s*(.*)/i
        detail = $1.split(',').first.to_s.strip
        detail = detail.sub(/,?\s*[0-9A-Fa-f]{6,}\s*$/, '').strip
        return detail unless detail.empty?
      end

      # "Foundation Slab, 10" Concrete" → "Foundation Slab"
      # "Wall Foundation, Wall Foundation 1'-2" Heel" → "Wall Foundation"
      cleaned = parts.first.to_s.strip
      return nil if cleaned.empty?
      return nil if guid?(cleaned)

      # Take the first segment before hyphen (the category/type prefix)
      first_seg = cleaned.split('-').first.to_s.strip

      if first_seg.length < 4 || first_seg =~ /^\d+$/ || guid?(first_seg)
        segs = cleaned.split('-').first(2).join('-').strip
        return nil if guid?(segs)
        return segs unless segs.empty?
      end

      # Strip trailing instance numbers like " (1)" or " [2]"
      first_seg = first_seg.sub(/\s*[\(\[]\d+[\)\]]\s*$/, '').strip

      result = first_seg.empty? ? cleaned : first_seg
      guid?(result) ? nil : result
    end

    def self.build_dialog_html
      <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
      <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { font-family: -apple-system, 'Segoe UI', Arial, sans-serif; font-size:12px; color:#e0e0e0; background:#1e1e1e; padding:12px; }
        h2 { font-size:15px; margin-bottom:8px; color:#fff; }
        .info { color:#888; font-size:11px; margin-bottom:12px; }
        table { width:100%; border-collapse:collapse; }
        th { background:#2a2a2a; color:#aaa; font-size:10px; text-transform:uppercase; letter-spacing:0.5px; padding:6px 8px; text-align:left; position:sticky; top:0; }
        td { padding:5px 8px; border-bottom:1px solid #333; font-size:11px; }
        tr:hover { background:#2a2a2a; }
        .kw { color:#7cc; font-weight:600; }
        .from { color:#f88; }
        .to { color:#8f8; }
        .times { color:#fc8; text-align:center; }
        .date { color:#888; }
        .del-btn { background:#c33; color:#fff; border:none; padding:2px 8px; border-radius:3px; cursor:pointer; font-size:10px; }
        .del-btn:hover { background:#e44; }
        .toolbar { display:flex; justify-content:space-between; align-items:center; margin-bottom:10px; }
        .clear-btn { background:#555; color:#fff; border:none; padding:5px 12px; border-radius:3px; cursor:pointer; font-size:11px; }
        .clear-btn:hover { background:#c33; }
        .scroll-wrap { max-height: calc(100vh - 80px); overflow-y:auto; }
      </style>
      </head>
      <body>
      <div class="toolbar">
        <div>
          <h2>Learned Rules (#{@rules.length})</h2>
          <div class="info">Rules are created when you reclassify entities. They improve future scan accuracy.</div>
        </div>
        <button class="clear-btn" onclick="sketchup.clearAll()">Clear All Rules</button>
      </div>
      <div class="scroll-wrap">
      <table>
        <thead>
          <tr><th>Keyword</th><th>Material</th><th>From</th><th>To Category</th><th>Subcategory</th><th>Uses</th><th></th></tr>
        </thead>
        <tbody id="rulesTable">
          #{build_rules_table_html}
        </tbody>
      </table>
      </div>
      </body>
      </html>
      HTML
    end

    def self.build_rules_table_html
      rows = ''
      @rules.each_with_index do |rule, idx|
        # Show keywords array or single keyword
        if rule['keywords'].is_a?(Array)
          kw = esc_html(rule['keywords'].join(' + '))
        else
          kw = esc_html(rule['keyword'] || '')
        end
        src = rule['source'] == 'custom_rule' ? '<span style="color:#c6a0f6">custom</span>' : ''
        mat = esc_html(rule['material'] || '-')
        from = esc_html(rule['from_category'] || '-')
        to_cat = esc_html(rule['to_category'] || '')
        to_sub = esc_html(rule['to_subcategory'] || '-')
        times = rule['times_applied'] || 1
        rows += "<tr>"
        rows += "<td class='kw'>#{kw} #{src}</td>"
        rows += "<td>#{mat}</td>"
        rows += "<td class='from'>#{from}</td>"
        rows += "<td class='to'>#{to_cat}</td>"
        rows += "<td>#{to_sub}</td>"
        rows += "<td class='times'>#{times}</td>"
        rows += "<td><button class='del-btn' onclick=\"sketchup.deleteRule('#{idx}')\">Delete</button></td>"
        rows += "</tr>\n"
      end
      rows
    end

    def self.esc_html(s)
      s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;').gsub("'", '&#39;')
    end

    def self.rule_builder_html(containers_json, subs_json, rules_json)
      safe_containers = containers_json.gsub('</') { '<\\/' }
      safe_subs = subs_json.gsub('</') { '<\\/' }
      safe_rules = rules_json.gsub('</') { '<\\/' }
      <<~HTMLEND
      <!DOCTYPE html>
      <html>
      <head>
      <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { font-family: -apple-system, 'Segoe UI', Arial, sans-serif; font-size:12px; color:#cdd6f4; background:#1e1e2e; padding:16px; display:flex; flex-direction:column; height:100vh; }
        h2 { font-size:15px; color:#cdd6f4; margin-bottom:4px; }
        .subtitle { color:#6c7086; font-size:11px; margin-bottom:12px; }

        /* Builder panel */
        .builder { background:#313244; border-radius:8px; padding:14px; margin-bottom:12px; }
        .builder label { display:block; color:#a6adc8; font-size:10px; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:3px; margin-top:8px; }
        .builder label:first-child { margin-top:0; }
        .builder input, .builder select { width:100%; background:#1e1e2e; border:1px solid #45475a; color:#cdd6f4; padding:6px 8px; border-radius:4px; font-size:12px; }
        .builder input:focus, .builder select:focus { outline:none; border-color:#89b4fa; }
        .builder select optgroup { color:#89b4fa; font-weight:700; font-size:11px; }
        .builder select option { color:#cdd6f4; font-weight:400; padding-left:8px; }
        .row { display:flex; gap:10px; }
        .row > div { flex:1; }
        .kw-input { font-size:14px !important; font-weight:600; letter-spacing:0.3px; }

        /* Buttons */
        .btn { border:none; padding:6px 14px; border-radius:4px; cursor:pointer; font-size:11px; font-weight:600; }
        .btn-preview { background:#45475a; color:#cdd6f4; }
        .btn-preview:hover { background:#585b70; }
        .btn-create { background:#a6e3a1; color:#1e1e2e; }
        .btn-create:hover { background:#94e2d5; }
        .btn-test { background:#89b4fa; color:#1e1e2e; }
        .btn-test:hover { background:#74c7ec; }
        .btn-del { background:#f38ba8; color:#1e1e2e; padding:2px 8px; border-radius:3px; cursor:pointer; font-size:10px; border:none; }
        .btn-del:hover { background:#eba0ac; }
        .btn-bar { display:flex; gap:8px; margin-top:10px; align-items:center; }

        /* Preview */
        .preview { background:#181825; border:1px solid #313244; border-radius:6px; padding:8px; margin-top:8px; max-height:150px; overflow-y:auto; }
        .preview-count { color:#a6adc8; font-size:11px; margin-bottom:4px; }
        .preview-item { padding:3px 6px; font-size:11px; border-bottom:1px solid #313244; display:flex; justify-content:space-between; }
        .preview-item .name { color:#cdd6f4; flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .preview-item .cat { color:#f9e2af; font-size:10px; margin-left:8px; white-space:nowrap; }

        /* Rules table */
        .rules-wrap { flex:1; overflow-y:auto; }
        table { width:100%; border-collapse:collapse; }
        th { background:#313244; color:#6c7086; font-size:10px; text-transform:uppercase; letter-spacing:0.5px; padding:6px 8px; text-align:left; position:sticky; top:0; z-index:1; }
        td { padding:4px 8px; border-bottom:1px solid #313244; font-size:11px; }
        tr:hover { background:#313244; }
        .kw { color:#89dceb; font-weight:600; }
        .custom-tag { color:#cba6f7; font-size:9px; margin-left:4px; }
        .to { color:#a6e3a1; }
        .from { color:#f38ba8; }
        .times { color:#f9e2af; text-align:center; }
        .status { color:#a6adc8; font-size:11px; margin-left:auto; }
      </style>
      </head>
      <body>
      <h2>Rule Builder</h2>
      <div class="subtitle">Create rules: name contains keyword1 + keyword2 = Category</div>

      <div class="builder">
        <label>Keywords (separate with +)</label>
        <input type="text" id="kwInput" class="kw-input" placeholder="bath + towel + delta" autofocus>

        <div class="row">
          <div>
            <label>Target Category</label>
            <select id="catSelect"><option value="">-- select --</option></select>
          </div>
          <div>
            <label>Subcategory (optional)</label>
            <select id="subSelect"><option value="">-- none --</option></select>
          </div>
          <div>
            <label>Cost Code (optional)</label>
            <input type="text" id="costInput" placeholder="">
          </div>
        </div>

        <div class="btn-bar">
          <button class="btn btn-preview" id="btnPreview">Preview Matches</button>
          <button class="btn btn-create" id="btnCreate">Create Rule</button>
          <button class="btn btn-test" id="btnTest">Test All Rules</button>
          <span class="status" id="status"></span>
        </div>

        <div class="preview" id="previewBox" style="display:none">
          <div class="preview-count" id="previewCount"></div>
          <div id="previewList"></div>
        </div>
      </div>

      <div class="rules-wrap">
        <table>
          <thead>
            <tr><th>Keywords</th><th>To Category</th><th>Subcategory</th><th>Source</th><th>Uses</th><th></th></tr>
          </thead>
          <tbody id="rulesBody"></tbody>
        </table>
      </div>

      <script>
        var containers = #{safe_containers};
        var subcategories = #{safe_subs};
        var rules = #{safe_rules};

        // Populate category dropdown grouped by container
        var catSel = document.getElementById('catSelect');
        containers.forEach(function(cont) {
          if (!cont.categories || cont.categories.length === 0) return;
          var grp = document.createElement('optgroup');
          grp.label = cont.name;
          cont.categories.forEach(function(cat) {
            if (cat.name === '_IGNORE') return;
            var opt = document.createElement('option');
            opt.value = cat.name;
            opt.textContent = cat.name + (cat.code ? ' (' + cat.code + ')' : '');
            grp.appendChild(opt);
          });
          catSel.appendChild(grp);
        });

        // Build a lookup: category name -> cost code from containers
        var catCodeMap = {};
        containers.forEach(function(cont) {
          (cont.categories || []).forEach(function(cat) {
            if (cat.code) catCodeMap[cat.name] = cat.code;
          });
        });

        // Update subcategory dropdown and auto-fill cost code when category changes
        catSel.addEventListener('change', function() {
          var subSel = document.getElementById('subSelect');
          subSel.innerHTML = '<option value="">-- none --</option>';
          var subs = subcategories[catSel.value] || [];
          subs.forEach(function(s) {
            var opt = document.createElement('option');
            opt.value = s; opt.textContent = s;
            subSel.appendChild(opt);
          });
          // Auto-fill cost code
          var code = catCodeMap[catSel.value] || '';
          document.getElementById('costInput').value = code;
        });

        // Preview button
        document.getElementById('btnPreview').addEventListener('click', function() {
          var kw = document.getElementById('kwInput').value.trim();
          if (!kw) return;
          sketchup.preview(kw);
        });

        // Auto-preview on Enter in keyword input
        document.getElementById('kwInput').addEventListener('keydown', function(e) {
          if (e.key === 'Enter') {
            e.preventDefault();
            sketchup.preview(this.value.trim());
          }
        });

        // Create button
        document.getElementById('btnCreate').addEventListener('click', function() {
          var kw = document.getElementById('kwInput').value.trim();
          var cat = document.getElementById('catSelect').value;
          if (!kw) { setStatus('Enter keywords first', '#f38ba8'); return; }
          if (!cat) { setStatus('Select a category first', '#f38ba8'); return; }
          var data = {
            keywords: kw,
            category: cat,
            subcategory: document.getElementById('subSelect').value,
            costCode: document.getElementById('costInput').value.trim(),
            matchField: 'name'
          };
          sketchup.createRule(JSON.stringify(data));
        });

        // Test button
        document.getElementById('btnTest').addEventListener('click', function() {
          setStatus('Testing...', '#89b4fa');
          sketchup.testRules();
        });

        // Delete rule via event delegation
        document.getElementById('rulesBody').addEventListener('click', function(e) {
          if (e.target.classList.contains('btn-del')) {
            var idx = e.target.getAttribute('data-idx');
            if (idx !== null) sketchup.deleteRule(idx);
          }
        });

        function receivePreview(matches) {
          var box = document.getElementById('previewBox');
          var count = document.getElementById('previewCount');
          var list = document.getElementById('previewList');
          box.style.display = 'block';
          count.textContent = matches.length + ' entities match';
          count.style.color = matches.length > 0 ? '#a6e3a1' : '#f38ba8';
          list.innerHTML = '';
          var shown = Math.min(matches.length, 50);
          for (var i = 0; i < shown; i++) {
            var m = matches[i];
            var div = document.createElement('div');
            div.className = 'preview-item';
            div.innerHTML = '<span class="name">' + escHtml(m.name) + '</span><span class="cat">' + escHtml(m.current_cat) + '</span>';
            list.appendChild(div);
          }
          if (matches.length > 50) {
            var more = document.createElement('div');
            more.className = 'preview-item';
            more.innerHTML = '<span class="name" style="color:#6c7086">... and ' + (matches.length - 50) + ' more</span>';
            list.appendChild(more);
          }
        }

        function receiveCreateResult(result) {
          if (result.ok) {
            setStatus('Rule created!', '#a6e3a1');
            document.getElementById('kwInput').value = '';
            document.getElementById('previewBox').style.display = 'none';
          } else {
            setStatus(result.error, '#f38ba8');
          }
        }

        function receiveRules(newRules) {
          rules = newRules;
          renderRules();
        }

        function receiveTestResult(hits, total) {
          setStatus(hits + ' of ' + total + ' entities matched by rules', '#89b4fa');
        }

        function renderRules() {
          var body = document.getElementById('rulesBody');
          body.innerHTML = '';
          for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            var kwText = r.keywords ? r.keywords.join(' + ') : (r.keyword || '');
            var src = r.source === 'custom_rule' ? 'custom' : (r.source === 'geometry_match' ? 'geometry' : 'learned');
            var srcColor = r.source === 'custom_rule' ? '#cba6f7' : (r.source === 'geometry_match' ? '#89b4fa' : '#6c7086');
            var tr = document.createElement('tr');
            tr.innerHTML =
              '<td class="kw">' + escHtml(kwText) + '</td>' +
              '<td class="to">' + escHtml(r.to_category || '') + '</td>' +
              '<td>' + escHtml(r.to_subcategory || '-') + '</td>' +
              '<td style="color:' + srcColor + '">' + src + '</td>' +
              '<td class="times">' + (r.times_applied || 0) + '</td>' +
              '<td><button class="btn-del" data-idx="' + i + '">Del</button></td>';
            body.appendChild(tr);
          }
          if (rules.length === 0) {
            body.innerHTML = '<tr><td colspan="6" style="text-align:center;color:#6c7086;padding:20px">No rules yet</td></tr>';
          }
        }

        function setStatus(msg, color) {
          var el = document.getElementById('status');
          el.textContent = msg;
          el.style.color = color || '#a6adc8';
          setTimeout(function() { el.textContent = ''; }, 5000);
        }

        function escHtml(s) {
          var d = document.createElement('div');
          d.textContent = s || '';
          return d.innerHTML;
        }

        // Initial render
        renderRules();
      </script>
      </body>
      </html>
      HTMLEND
    end
  end
end
