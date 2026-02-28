module TakeoffTool
  module IdentifyDialog
    @dialog = nil
    @current_entities = []

    def self.show(selection)
      @dialog.close if @dialog && @dialog.visible? rescue nil
      @current_entities = selection.to_a.select { |e| e.respond_to?(:entityID) }
      return if @current_entities.empty?

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field - Identify",
        preferences_key: "TakeoffIdentify",
        width: 320, height: 450,
        left: 200, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.add_action_callback('applyCategory') do |_ctx, cat_str|
        cat = cat_str.to_s
        next if cat.empty?
        TakeoffTool.apply_category_to_selection(@current_entities, cat)
        @dialog.close rescue nil
      end

      html = @current_entities.length == 1 ? build_single(@current_entities.first) : build_multi(@current_entities)
      @dialog.set_html(html)
      @dialog.show
    end

    private

    def self.h(s)
      s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
    end

    # Strip trailing Revit hex ID from name (e.g. "Basic Wall, Finish - GYP, 3A2F" -> "Basic Wall, Finish - GYP")
    def self.clean_name(name)
      name.to_s.sub(/,\s*[0-9A-Fa-f]+\s*$/, '').strip
    end

    def self.fmt_dim(inches)
      inches = inches.to_f
      ft = (inches / 12).floor
      rem = inches - ft * 12
      whole = rem.floor
      frac = rem - whole
      # Format fractional part
      if frac.abs < 0.05
        rem_str = "#{whole}\""
      else
        rem_str = "#{rem.round(1)}\""
      end
      ft > 0 ? "#{ft}'-#{rem_str}" : rem_str
    end

    def self.fmt_vol(vol_in3)
      ft3 = vol_in3 / 1728.0
      "#{ft3.round(2)} ft&sup3;"
    end

    def self.entity_info(e)
      eid = e.entityID
      defn = e.respond_to?(:definition) ? e.definition : nil
      dname = defn ? defn.name : ''
      iname = (e.respond_to?(:name) && e.name && !e.name.empty?) ? e.name : nil

      # Category
      cat = TakeoffTool.category_assignments[eid]
      cat ||= (e.get_attribute('TakeoffAssignments', 'category') rescue nil)
      unless cat
        sr = TakeoffTool.scan_results.find { |r| r[:entity_id] == eid }
        cat = sr[:parsed][:auto_category] if sr
      end

      # Subcategory
      sub = (e.get_attribute('TakeoffAssignments', 'subcategory') rescue nil)
      unless sub
        sr ||= TakeoffTool.scan_results.find { |r| r[:entity_id] == eid }
        sub = sr[:parsed][:auto_subcategory] if sr
      end

      # Tag
      tag = e.respond_to?(:layer) && e.layer ? e.layer.name : 'Untagged'

      # IFC Type
      ifc = nil
      if defn && defn.attribute_dictionaries
        a = defn.attribute_dictionaries['AppliedSchemaTypes']
        ifc = a['IFC 4'] if a
      end

      # Material
      mat = nil
      if e.material
        mat = e.material.display_name
      elsif defn
        f = defn.entities.grep(Sketchup::Face).first
        mat = f.material.display_name if f && f.material
      end

      # Bounding box
      bb = e.bounds
      w = bb.width.to_f; h_val = bb.height.to_f; d = bb.depth.to_f

      # Volume / Solid
      is_solid = false; vol = nil
      begin
        if e.respond_to?(:manifold?) && e.manifold?
          is_solid = true; vol = e.volume
        end
      rescue; end

      # Instance count
      inst_count = defn ? defn.instances.length : 1

      {
        name: clean_name(iname || dname),
        definition: dname,
        category: cat, subcategory: sub || '',
        tag: tag, ifc: ifc, material: mat,
        w: w, h: h_val, d: d,
        is_solid: is_solid, volume: vol,
        instance_count: inst_count
      }
    end

    def self.category_options(selected)
      cats = TakeoffTool.build_context_categories.reject { |c| c == '_IGNORE' }
      cats.map { |c|
        sel = c == selected ? ' selected' : ''
        "<option value=\"#{h(c)}\"#{sel}>#{h(c)}</option>"
      }.join("\n")
    end

    MOCHA_CSS = <<~CSS.freeze
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: 'Segoe UI', system-ui, sans-serif;
        font-size: 12px;
        background: #1e1e2e;
        color: #cdd6f4;
        padding: 16px;
        line-height: 1.5;
        overflow-y: auto;
      }
      h1 {
        font-size: 14px;
        font-weight: 700;
        color: #cba6f7;
        text-transform: uppercase;
        letter-spacing: 1.5px;
        margin-bottom: 14px;
        padding-bottom: 8px;
        border-bottom: 2px solid #313244;
      }
      .entity-name {
        font-size: 13px;
        font-weight: 600;
        color: #89b4fa;
        word-break: break-all;
        margin-bottom: 4px;
      }
      .def-name-sub {
        font-size: 10px;
        color: #6c7086;
        margin-bottom: 12px;
      }
      .row {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        padding: 3px 0;
        border-bottom: 1px solid #181825;
      }
      .label {
        color: #a6adc8;
        font-size: 11px;
        flex-shrink: 0;
        min-width: 85px;
      }
      .value {
        text-align: right;
        font-weight: 500;
        word-break: break-all;
      }
      .cat-assigned { color: #a6e3a1; }
      .cat-unassigned { color: #f38ba8; font-style: italic; }
      .dim { color: #fab387; font-family: Consolas, monospace; font-size: 11px; }
      hr {
        border: none;
        border-top: 1px solid #313244;
        margin: 14px 0;
      }
      select {
        width: 100%;
        padding: 7px 8px;
        background: #313244;
        color: #cdd6f4;
        border: 1px solid #45475a;
        border-radius: 4px;
        font-size: 12px;
        cursor: pointer;
        margin-bottom: 8px;
      }
      select:focus { outline: none; border-color: #89b4fa; }
      .apply-btn {
        width: 100%;
        padding: 8px;
        background: #cba6f7;
        color: #1e1e2e;
        border: none;
        border-radius: 4px;
        font-size: 12px;
        font-weight: 700;
        cursor: pointer;
        text-transform: uppercase;
        letter-spacing: 0.5px;
      }
      .apply-btn:hover { background: #b4befe; }
      .badge {
        display: inline-block;
        padding: 1px 6px;
        border-radius: 3px;
        font-size: 10px;
        font-weight: 600;
      }
      .badge-yes { background: #a6e3a1; color: #1e1e2e; }
      .badge-no { background: #45475a; color: #a6adc8; }
      .multi-count {
        font-size: 16px;
        font-weight: 700;
        color: #cba6f7;
        margin-bottom: 12px;
      }
      .def-list {
        list-style: none;
        max-height: 220px;
        overflow-y: auto;
        margin-bottom: 14px;
      }
      .def-list li {
        padding: 5px 8px;
        background: #181825;
        margin-bottom: 2px;
        border-radius: 4px;
        display: flex;
        justify-content: space-between;
        font-size: 11px;
      }
      .def-list .dname {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .def-list .dcount {
        color: #89b4fa;
        font-weight: 600;
        flex-shrink: 0;
        margin-left: 8px;
      }
      .sect-label {
        font-size: 10px;
        text-transform: uppercase;
        letter-spacing: 1px;
        color: #6c7086;
        margin-bottom: 6px;
      }
    CSS

    def self.build_single(entity)
      i = entity_info(entity)
      dim = "#{fmt_dim(i[:w])} &times; #{fmt_dim(i[:h])} &times; #{fmt_dim(i[:d])}"

      cat_class = i[:category] ? 'cat-assigned' : 'cat-unassigned'
      cat_text = i[:category] || 'Unassigned'

      vol_str = (i[:is_solid] && i[:volume]) ? fmt_vol(i[:volume]) : 'N/A'
      solid = i[:is_solid] ? '<span class="badge badge-yes">Yes</span>' : '<span class="badge badge-no">No</span>'

      sub_row = (i[:subcategory] && !i[:subcategory].empty?) ?
        "<div class=\"row\"><span class=\"label\">Subcategory</span><span class=\"value\">#{h(i[:subcategory])}</span></div>" : ''
      ifc_row = i[:ifc] ?
        "<div class=\"row\"><span class=\"label\">IFC Type</span><span class=\"value\">#{h(i[:ifc])}</span></div>" : ''

      defn_line = ''
      if i[:definition] && !i[:definition].empty? && clean_name(i[:definition]) != i[:name]
        defn_line = "<div class=\"def-name-sub\">Definition: #{h(i[:definition])}</div>"
      end

      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>#{MOCHA_CSS}</style></head><body>
        <h1>Identify</h1>
        <div class="entity-name">#{h(i[:name])}</div>
        #{defn_line}
        <div class="row"><span class="label">Category</span><span class="value #{cat_class}">#{h(cat_text)}</span></div>
        #{sub_row}
        <div class="row"><span class="label">Layer/Tag</span><span class="value">#{h(i[:tag])}</span></div>
        #{ifc_row}
        <div class="row"><span class="label">Material</span><span class="value">#{h(i[:material] || '(none)')}</span></div>
        <div class="row"><span class="label">Size</span><span class="value dim">#{dim}</span></div>
        <div class="row"><span class="label">Solid</span><span class="value">#{solid}</span></div>
        <div class="row"><span class="label">Volume</span><span class="value">#{vol_str}</span></div>
        <div class="row"><span class="label">Instances</span><span class="value">#{i[:instance_count]}</span></div>
        <hr>
        <div class="sect-label">Set Category</div>
        <select id="catSel">
          <option value="">-- Select --</option>
          #{category_options(i[:category] || '')}
        </select>
        <button class="apply-btn" onclick="var v=document.getElementById('catSel').value;if(v)sketchup.applyCategory(v);">Apply</button>
        </body></html>
      HTML
    end

    def self.build_multi(entities)
      count = entities.length

      # Unique definitions with counts
      def_counts = Hash.new(0)
      entities.each do |e|
        defn = e.respond_to?(:definition) ? e.definition : nil
        name = defn ? clean_name(defn.name) : '(unknown)'
        def_counts[name] += 1
      end
      sorted = def_counts.sort_by { |_, c| -c }

      list_items = sorted.map { |name, cnt|
        "<li><span class=\"dname\" title=\"#{h(name)}\">#{h(name)}</span><span class=\"dcount\">(x#{cnt})</span></li>"
      }.join("\n")

      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>#{MOCHA_CSS}</style></head><body>
        <h1>Identify &mdash; #{count} entities selected</h1>
        <div class="sect-label">Definitions</div>
        <ul class="def-list">
          #{list_items}
        </ul>
        <hr>
        <div class="sect-label">Set Category (all #{count})</div>
        <select id="catSel">
          <option value="">-- Select --</option>
          #{category_options('')}
        </select>
        <button class="apply-btn" onclick="var v=document.getElementById('catSel').value;if(v)sketchup.applyCategory(v);">Apply</button>
        </body></html>
      HTML
    end
  end
end
