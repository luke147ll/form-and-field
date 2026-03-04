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

    def self.capture(entity_id, old_category, new_category, new_subcategory: nil, new_cost_code: nil)
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

      # Extract a keyword from the definition/display name
      # Use the most distinctive part of the name
      keyword = extract_keyword(display_name, definition_name)
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

    def self.apply(display, mat, ifc_type)
      load_rules unless @rules
      return nil if @rules.empty?

      text = display.to_s.downcase
      mat_str = (mat || '').to_s.downcase
      ifc_str = (ifc_type || '').to_s

      best = nil
      best_score = 0

      @rules.each do |rule|
        score = 0
        kw = rule['keyword'].to_s.downcase

        # Keyword match (required)
        next unless !kw.empty? && text.include?(kw)
        score += 10

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
        learned_keyword: best['keyword'],
        learned_times: best['times_applied']
      }
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

    # Extract the most distinctive keyword from the display/definition name
    def self.extract_keyword(display_name, definition_name)
      name = display_name.to_s.strip
      name = definition_name.to_s.strip if name.empty?
      return nil if name.empty?

      # Remove Revit hex IDs
      parts = name.split(',').map(&:strip)
      parts.pop if parts.last && parts.last.match?(/^[0-9A-Fa-f]+$/)

      cleaned = parts.join(', ').strip
      return nil if cleaned.empty?

      # For "Basic Wall, ..." or "Basic Roof, ..." — use the detail part
      if cleaned =~ /^Basic (?:Wall|Roof|Floor),?\s*(.*)/i
        detail = $1.strip
        return detail unless detail.empty?
      end

      # For door/window types, keep the full cleaned name
      # For everything else, use the cleaned name
      cleaned
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
        kw = esc_html(rule['keyword'] || '')
        mat = esc_html(rule['material'] || '-')
        from = esc_html(rule['from_category'] || '-')
        to_cat = esc_html(rule['to_category'] || '')
        to_sub = esc_html(rule['to_subcategory'] || '-')
        times = rule['times_applied'] || 1
        rows += "<tr>"
        rows += "<td class='kw'>#{kw}</td>"
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
  end
end
