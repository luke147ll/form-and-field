module TakeoffTool
  module Exporter

    # ─── Deduplicate scan results by Revit definition ID ───
    # Rows with same definition_name get merged: qty summed, measurements aggregated
    def self.dedup_rows(sr, ca, cca)
      groups = {}
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next if cat == '_IGNORE'
        # Key = category + definition_name (strips the hex Revit ID to group same types)
        defn = r[:definition_name] || r[:display_name] || 'Unknown'
        key = "#{cat}||#{defn}"
        if groups[key]
          g = groups[key]
          g[:total_qty] += (r[:instance_count] || 1)
          g[:total_vol_ft3] += (r[:volume_ft3] || 0)
          g[:total_bf] += (r[:volume_bf] || 0) * (r[:instance_count] || 1)
          g[:total_area_sf] += (r[:area_sf] || 0)
          g[:total_linear_ft] += (r[:linear_ft] || 0) * (r[:instance_count] || 1)
          g[:row_count] += 1
        else
          groups[key] = {
            r: r, cat: cat,
            cost_code: cca[r[:entity_id]] || '',
            total_qty: (r[:instance_count] || 1),
            total_vol_ft3: (r[:volume_ft3] || 0),
            total_bf: (r[:volume_bf] || 0) * (r[:instance_count] || 1),
            total_area_sf: (r[:area_sf] || 0),
            total_linear_ft: (r[:linear_ft] || 0) * (r[:instance_count] || 1),
            row_count: 1
          }
        end
        # Carry forward cost code if set
        cc = cca[r[:entity_id]]
        if cc && !cc.empty? && groups[key][:cost_code].empty?
          groups[key][:cost_code] = cc
        end
      end
      groups.values.sort_by { |g| [g[:cost_code].empty? ? 'zzz' : g[:cost_code], g[:cat]] }
    end

    # ─── CSV EXPORT ───

    def self.export_csv(sr, ca, cca)
      return UI.messagebox("No data.") if sr.empty?
      model = Sketchup.active_model
      model_name = model ? File.basename(model.path, '.*') : 'Untitled'
      model_name = 'Untitled' if model_name.empty?
      timestamp = Time.now.strftime('%Y-%m-%d_%H%M')
      default_name = "#{model_name}_Takeoff_#{timestamp}.csv"

      path = UI.savepanel("Export Takeoff CSV", "", default_name)
      return unless path
      path += '.csv' unless path.end_with?('.csv')

      begin
        summary = build_summary(sr, ca, cca)
        deduped = dedup_rows(sr, ca, cca)

        File.open(path, 'w') do |f|
          f.puts ce("TAKEOFF REPORT")
          f.puts ce("Model: #{model_name}")
          f.puts ce("Date: #{Time.now.strftime('%B %d, %Y at %I:%M %p')}")
          f.puts ce("Elements: #{sr.length}")
          f.puts ""

          # ── SUMMARY ──
          f.puts ce("SUMMARY BY CATEGORY")
          f.puts ['Cost Code','Category','Count','Primary','Secondary'].map{|h|ce(h)}.join(',')
          summary.sort_by{|s| s[:cost_code]||'zzz'}.each do |s|
            f.puts [s[:cost_code], s[:category], s[:count],
                    s[:primary], s[:secondary]].map{|v| ce(v.to_s)}.join(',')
          end

          f.puts ""
          f.puts ""

          # ── DETAIL (deduped) ──
          f.puts ce("DETAIL BY ELEMENT")
          f.puts ['Cost Code','Category','Tag','Name','Type','Function',
                  'Material','Thickness','Size','Qty',
                  'BF','Area SF','Linear Ft','Vol ft3','Measurement','Warnings'
                 ].map{|h|ce(h)}.join(',')

          deduped.each do |g|
            r = g[:r]
            mt = Parser.measurement_for(g[:cat])
            f.puts [
              g[:cost_code], g[:cat], r[:tag],
              r[:display_name]||r[:definition_name],
              r[:parsed][:element_type], r[:parsed][:function],
              r[:parsed][:material]||r[:material], r[:parsed][:thickness],
              r[:parsed][:size_nominal], g[:total_qty],
              g[:total_bf].round(1), g[:total_area_sf].round(1),
              g[:total_linear_ft].round(1), g[:total_vol_ft3].round(2),
              mt, (r[:warnings]||[]).join('; ')
            ].map{|v| ce(v.to_s)}.join(',')
          end
        end
        UI.messagebox("CSV exported:\n#{path}")
      rescue => e
        UI.messagebox("Export failed: #{e.message}")
      end
    end

    # ─── HTML REPORT ───

    def self.export_html(sr, ca, cca)
      return UI.messagebox("No data.") if sr.empty?
      model = Sketchup.active_model
      model_name = model ? File.basename(model.path, '.*') : 'Untitled'
      model_name = 'Untitled' if model_name.empty?
      model_path = model ? model.path : ''
      timestamp = Time.now.strftime('%Y-%m-%d_%H%M')
      date_display = Time.now.strftime('%B %d, %Y')
      time_display = Time.now.strftime('%I:%M %p')
      default_name = "#{model_name}_Takeoff_#{timestamp}.html"

      path = UI.savepanel("Export Takeoff Report", "", default_name)
      return unless path
      path += '.html' unless path.end_with?('.html')

      begin
        summary = build_summary(sr, ca, cca)
        deduped = dedup_rows(sr, ca, cca)

        logo_b64 = ''
        logo_path = File.join(PLUGIN_DIR, 'config', 'logo.png')
        if File.exist?(logo_path)
          require 'base64'
          logo_b64 = Base64.strict_encode64(File.binread(logo_path))
        end

        html = build_html_report(model_name, model_path, date_display, time_display,
                                  sr, ca, cca, summary, deduped, logo_b64)

        File.open(path, 'w') { |f| f.write(html) }
        UI.messagebox("Report exported:\n#{path}")

        if Sketchup.platform == :platform_win
          UI.openURL("file:///#{path.gsub('\\','/')}")
        else
          UI.openURL("file://#{path}")
        end
      rescue => e
        UI.messagebox("Export failed: #{e.message}\n#{e.backtrace.first}")
      end
    end

    # ─── Build Summary Data ───

    def self.build_summary(sr, ca, cca)
      groups = {}
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next if cat == '_IGNORE'
        cc = cca[r[:entity_id]] || ''
        groups[cat] ||= { items: [], cost_code: cc }
        groups[cat][:items] << r
        groups[cat][:cost_code] = cc if cc && !cc.empty? && groups[cat][:cost_code].empty?
      end

      groups.map do |cat, g|
        mt = Parser.measurement_for(cat)
        items = g[:items]
        count = items.length

        # Primary measurement — use instance_count for EA, multiply for totals
        primary = case mt
        when 'ea', 'ea_bf', 'ea_sf'
          items.reduce(0){|s,r| s + (r[:instance_count]||1)}.to_s + ' EA'
        when 'lf'
          items.reduce(0.0){|s,r| s + (r[:linear_ft]||0)*(r[:instance_count]||1)}.round(1).to_s + ' LF'
        when 'sf', 'sf_cy', 'sf_sheets'
          items.reduce(0.0){|s,r| s + (r[:area_sf]||0)}.round(1).to_s + ' SF'
        when 'volume'
          items.reduce(0.0){|s,r| s + (r[:volume_ft3]||0)}.round(2).to_s + ' ft³'
        else '—'
        end

        # Secondary measurement
        secondary = case mt
        when 'sf_cy'
          (items.reduce(0.0){|s,r| s + (r[:volume_ft3]||0)} / 27.0).round(2).to_s + ' CY'
        when 'ea_bf'
          # BF × instance_count for true total
          items.reduce(0.0){|s,r| s + (r[:volume_bf]||0)*(r[:instance_count]||1)}.round(1).to_s + ' BF'
        when 'ea_sf'
          total = items.reduce(0.0){|s,r|
            w = (r[:bb_width_in]||0)/12.0
            ht = (r[:bb_height_in]||0)/12.0
            s + w*ht*(r[:instance_count]||1)
          }
          total > 0 ? total.round(1).to_s + ' SF glass' : ''
        when 'sf_sheets'
          tsf = items.reduce(0.0){|s,r| s + (r[:area_sf]||0)}
          tsf > 0 ? (tsf / 32.0).ceil.to_s + ' sheets 4×8' : ''
        else ''
        end

        {
          category: cat,
          cost_code: g[:cost_code],
          count: count,
          primary: primary,
          secondary: secondary,
          measurement_type: mt
        }
      end
    end

    # ─── Build Interactive HTML Report ───

    def self.build_html_report(model_name, model_path, date, time, sr, ca, cca, summary, deduped, logo_b64)
      total = sr.reject{|r| (ca[r[:entity_id]]||r[:parsed][:auto_category]) == '_IGNORE'}.length
      cats = summary.length
      warnings = sr.count{|r| r[:warnings] && r[:warnings].length > 0}
      unique_items = deduped.length

      logo_img = logo_b64.empty? ? '' :
        "<img src=\"data:image/png;base64,#{logo_b64}\" style=\"max-height:60px;max-width:240px;\">"

      # Build summary rows HTML
      summary_rows = summary.sort_by{|s| s[:cost_code]||'zzz'}.map do |s|
        "<tr data-cat=\"#{h(s[:category])}\" class=\"sum-row\" onclick=\"toggleCat(this)\" style=\"cursor:pointer\">
          <td>#{h(s[:cost_code])}</td>
          <td><strong>#{h(s[:category])}</strong> <span class=\"toggle-icon\">▶</span></td>
          <td class=\"r\">#{s[:count]}</td>
          <td class=\"r\">#{h(s[:primary])}</td>
          <td class=\"r\">#{h(s[:secondary])}</td>
        </tr>"
      end.join("\n")

      # Build detail rows grouped by category
      detail_rows = ""
      current_cat = nil
      cat_subtotals = {}

      deduped.each do |g|
        r = g[:r]
        cat = g[:cat]
        cc = g[:cost_code]

        # Track subtotals
        cat_subtotals[cat] ||= {sf: 0, bf: 0, lf: 0, ft3: 0, qty: 0}
        cat_subtotals[cat][:sf] += g[:total_area_sf]
        cat_subtotals[cat][:bf] += g[:total_bf]
        cat_subtotals[cat][:lf] += g[:total_linear_ft]
        cat_subtotals[cat][:ft3] += g[:total_vol_ft3]
        cat_subtotals[cat][:qty] += g[:total_qty]

        # Category group header if changed
        if cat != current_cat
          # Close previous subtotal
          if current_cat && cat_subtotals[current_cat]
            st = cat_subtotals[current_cat]
            detail_rows << "<tr class=\"cat-grp sub-row\" data-cat=\"#{h(current_cat)}\" style=\"display:none\">
              <td colspan=\"4\"></td><td colspan=\"3\" style=\"text-align:right;font-weight:600\">#{h(current_cat)} Subtotal:</td>
              <td class=\"r\" style=\"font-weight:600\">#{st[:qty]}</td>
              <td class=\"r\" style=\"font-weight:600\">#{st[:sf] > 0 ? st[:sf].round(1) : ''}</td>
              <td class=\"r\" style=\"font-weight:600\">#{st[:bf] > 0 ? st[:bf].round(1) : ''}</td>
              <td class=\"r\" style=\"font-weight:600\">#{st[:lf] > 0 ? st[:lf].round(1) : ''}</td>
              <td class=\"r\" style=\"font-weight:600\">#{st[:ft3] > 0 ? st[:ft3].round(2) : ''}</td>
            </tr>\n"
          end
          current_cat = cat
        end

        detail_rows << "<tr class=\"cat-grp\" data-cat=\"#{h(cat)}\" style=\"display:none\">
          <td>#{h(cc)}</td>
          <td>#{h(cat)}</td>
          <td>#{h(r[:tag])}</td>
          <td>#{h(r[:display_name]||r[:definition_name])}</td>
          <td>#{h(r[:parsed][:element_type])}</td>
          <td>#{h(r[:parsed][:material]||r[:material])}</td>
          <td>#{h(r[:parsed][:thickness])}</td>
          <td class=\"r\">#{g[:total_qty]}</td>
          <td class=\"r\">#{g[:total_area_sf] > 0 ? g[:total_area_sf].round(1) : ''}</td>
          <td class=\"r\">#{g[:total_bf] > 0 ? g[:total_bf].round(1) : ''}</td>
          <td class=\"r\">#{g[:total_linear_ft] > 0 ? g[:total_linear_ft].round(1) : ''}</td>
          <td class=\"r\">#{g[:total_vol_ft3] > 0 ? g[:total_vol_ft3].round(2) : ''}</td>
        </tr>\n"
      end

      # Final subtotal
      if current_cat && cat_subtotals[current_cat]
        st = cat_subtotals[current_cat]
        detail_rows << "<tr class=\"cat-grp sub-row\" data-cat=\"#{h(current_cat)}\" style=\"display:none\">
          <td colspan=\"4\"></td><td colspan=\"3\" style=\"text-align:right;font-weight:600\">#{h(current_cat)} Subtotal:</td>
          <td class=\"r\" style=\"font-weight:600\">#{st[:qty]}</td>
          <td class=\"r\" style=\"font-weight:600\">#{st[:sf] > 0 ? st[:sf].round(1) : ''}</td>
          <td class=\"r\" style=\"font-weight:600\">#{st[:bf] > 0 ? st[:bf].round(1) : ''}</td>
          <td class=\"r\" style=\"font-weight:600\">#{st[:lf] > 0 ? st[:lf].round(1) : ''}</td>
          <td class=\"r\" style=\"font-weight:600\">#{st[:ft3] > 0 ? st[:ft3].round(2) : ''}</td>
        </tr>\n"
      end

      <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
      <meta charset="utf-8">
      <title>Takeoff Report — #{h(model_name)}</title>
      <style>
        @page{size:landscape;margin:0.5in}
        @media print{.noprint{display:none !important} body{background:#fff} .cat-grp{display:table-row !important}}
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:'Segoe UI',Helvetica,Arial,sans-serif;font-size:11px;color:#1a1a1a;background:#f5f5f5;padding:20px}
        .page{max-width:1400px;margin:0 auto;background:#fff;box-shadow:0 1px 8px rgba(0,0,0,.12);border-radius:4px;overflow:hidden}

        .hdr{padding:24px 32px;display:flex;justify-content:space-between;align-items:center;border-bottom:3px solid #1a1a1a}
        .hdr-left h1{font-size:22px;font-weight:700;color:#1a1a1a;margin-bottom:2px}
        .hdr-right{text-align:right}
        .hdr-right .model{font-size:14px;font-weight:600;color:#1a1a1a}
        .hdr-right .meta{font-size:11px;color:#666;margin-top:2px}

        .stats{display:flex;gap:24px;padding:16px 32px;background:#f8f8f8;border-bottom:1px solid #e0e0e0}
        .stat{text-align:center}
        .stat .num{font-size:20px;font-weight:700;color:#2a5db0}
        .stat .lbl{font-size:10px;color:#888;text-transform:uppercase;letter-spacing:.5px}

        .toolbar{padding:12px 32px;background:#fff;border-bottom:1px solid #e0e0e0;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
        .toolbar input{padding:6px 12px;border:1px solid #ccc;border-radius:4px;font-size:12px;width:260px;font-family:inherit}
        .toolbar input:focus{outline:none;border-color:#2a5db0}
        .tb-btn{padding:5px 12px;border:1px solid #ccc;border-radius:4px;background:#fff;cursor:pointer;font-size:11px;font-family:inherit;color:#444}
        .tb-btn:hover{background:#f0f0f0;border-color:#999}
        .tb-btn.active{background:#2a5db0;color:#fff;border-color:#2a5db0}
        .tb-sep{width:1px;height:24px;background:#ddd}

        .section{padding:20px 32px}
        .section h2{font-size:14px;font-weight:700;color:#1a1a1a;border-bottom:2px solid #2a5db0;padding-bottom:4px;margin-bottom:12px;text-transform:uppercase;letter-spacing:.5px}

        table{width:100%;border-collapse:collapse;font-size:11px;margin-bottom:8px}
        th{background:#2a5db0;color:#fff;padding:6px 8px;text-align:left;font-weight:600;font-size:10px;text-transform:uppercase;letter-spacing:.3px;cursor:pointer;user-select:none;white-space:nowrap}
        th:hover{background:#1e4a8f}
        th .sort-icon{font-size:8px;margin-left:3px;opacity:.5}
        td{padding:5px 8px;border-bottom:1px solid #e8e8e8}
        tr:nth-child(even){background:#f9f9f9}
        tr:hover{background:#eef3fb}
        .r{text-align:right}

        .summary-table td{font-size:12px}
        .summary-table tr:last-child td{border-bottom:2px solid #1a1a1a;font-weight:600}
        .sum-row:hover{background:#eef3fb}
        .toggle-icon{font-size:9px;color:#888;margin-left:4px;transition:transform .15s}
        .sum-row.open .toggle-icon{transform:rotate(90deg)}

        .sub-row td{background:#f0f4fa;border-top:1px solid #ccc}

        .footer{padding:16px 32px;background:#f8f8f8;border-top:1px solid #e0e0e0;display:flex;justify-content:space-between;font-size:10px;color:#999}

        .btn-bar{position:fixed;top:10px;right:10px;display:flex;gap:8px}
        .action-btn{padding:10px 16px;border:none;border-radius:4px;font-size:12px;cursor:pointer;font-family:inherit;box-shadow:0 2px 6px rgba(0,0,0,.2)}
        .btn-print{background:#2a5db0;color:#fff}
        .btn-print:hover{background:#1e4a8f}
        .btn-csv{background:#27a844;color:#fff}
        .btn-csv:hover{background:#1e8d38}
        .btn-expand{background:#6c757d;color:#fff}
        .btn-expand:hover{background:#545b62}

        .hidden-col{display:none}
      </style>
      </head>
      <body>
      <div class="btn-bar noprint">
        <button class="action-btn btn-expand" onclick="toggleAllCats()" id="expandBtn">📂 Expand All</button>
        <button class="action-btn btn-csv" onclick="downloadCSV()">📋 CSV</button>
        <button class="action-btn btn-print" onclick="expandForPrint()">🖨 Print / Save PDF</button>
      </div>

      <div class="page">
        <div class="hdr">
          <div class="hdr-left">
            #{logo_img}
            <div style="margin-top:6px"><h1>Construction Takeoff Report</h1></div>
          </div>
          <div class="hdr-right">
            <div class="model">#{h(model_name)}</div>
            <div class="meta">#{date} — #{time}</div>
            <div class="meta" style="font-size:10px;color:#aaa">#{h(model_path)}</div>
          </div>
        </div>

        <div class="stats">
          <div class="stat"><div class="num">#{total}</div><div class="lbl">Elements</div></div>
          <div class="stat"><div class="num">#{unique_items}</div><div class="lbl">Unique Items</div></div>
          <div class="stat"><div class="num">#{cats}</div><div class="lbl">Categories</div></div>
          <div class="stat"><div class="num">#{warnings}</div><div class="lbl">Warnings</div></div>
        </div>

        <div class="toolbar noprint">
          <input type="text" id="searchBox" placeholder="🔍 Search categories, names, materials..." oninput="filterReport()">
          <div class="tb-sep"></div>
          <button class="tb-btn" onclick="toggleCol(8)" id="colSF">SF</button>
          <button class="tb-btn" onclick="toggleCol(9)" id="colBF">BF</button>
          <button class="tb-btn" onclick="toggleCol(10)" id="colLF">LF</button>
          <button class="tb-btn" onclick="toggleCol(11)" id="colFT3">ft³</button>
        </div>

        <div class="section">
          <h2>Summary by Category</h2>
          <p style="font-size:10px;color:#888;margin-bottom:8px" class="noprint">Click a category to expand its detail rows below</p>
          <table class="summary-table" id="summaryTable">
            <thead><tr>
              <th>Cost Code</th><th>Category</th><th class="r">Count</th>
              <th class="r">Primary</th><th class="r">Secondary</th>
            </tr></thead>
            <tbody>
              #{summary_rows}
              <tr>
                <td></td><td><strong>TOTAL</strong></td>
                <td class="r"><strong>#{total}</strong></td><td></td><td></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="section">
          <h2>Detail by Element <span style="font-size:11px;font-weight:400;color:#888">(#{unique_items} unique items from #{total} instances)</span></h2>
          <table id="detailTable">
            <thead><tr>
              <th onclick="sortTable(0)">Code <span class="sort-icon">⇅</span></th>
              <th onclick="sortTable(1)">Category <span class="sort-icon">⇅</span></th>
              <th onclick="sortTable(2)">Tag <span class="sort-icon">⇅</span></th>
              <th onclick="sortTable(3)">Name <span class="sort-icon">⇅</span></th>
              <th onclick="sortTable(4)">Type <span class="sort-icon">⇅</span></th>
              <th onclick="sortTable(5)">Material <span class="sort-icon">⇅</span></th>
              <th onclick="sortTable(6)">Thk <span class="sort-icon">⇅</span></th>
              <th class="r" onclick="sortTable(7,'n')">Qty <span class="sort-icon">⇅</span></th>
              <th class="r" onclick="sortTable(8,'n')">SF <span class="sort-icon">⇅</span></th>
              <th class="r" onclick="sortTable(9,'n')">BF <span class="sort-icon">⇅</span></th>
              <th class="r" onclick="sortTable(10,'n')">LF <span class="sort-icon">⇅</span></th>
              <th class="r" onclick="sortTable(11,'n')">ft³ <span class="sort-icon">⇅</span></th>
            </tr></thead>
            <tbody id="detailBody">#{detail_rows}</tbody>
          </table>
        </div>

        <div class="footer">
          <div>Generated by Takeoff Tool v#{PLUGIN_VERSION}</div>
          <div>#{date} #{time}</div>
        </div>
      </div>

      <script>
      // ─── Toggle category detail rows ───
      function toggleCat(tr){
        var cat = tr.getAttribute('data-cat');
        var open = tr.classList.toggle('open');
        var rows = document.querySelectorAll('#detailBody tr[data-cat="'+cat+'"]');
        for(var i=0;i<rows.length;i++){
          rows[i].style.display = open ? 'table-row' : 'none';
        }
      }

      var allExpanded = false;
      function toggleAllCats(){
        allExpanded = !allExpanded;
        var sumRows = document.querySelectorAll('.sum-row');
        var detRows = document.querySelectorAll('#detailBody .cat-grp');
        for(var i=0;i<sumRows.length;i++){
          if(allExpanded) sumRows[i].classList.add('open');
          else sumRows[i].classList.remove('open');
        }
        for(var i=0;i<detRows.length;i++){
          detRows[i].style.display = allExpanded ? 'table-row' : 'none';
        }
        document.getElementById('expandBtn').textContent = allExpanded ? '📁 Collapse All' : '📂 Expand All';
      }

      function expandForPrint(){
        // Expand all before printing
        var sumRows = document.querySelectorAll('.sum-row');
        var detRows = document.querySelectorAll('#detailBody .cat-grp');
        for(var i=0;i<sumRows.length;i++) sumRows[i].classList.add('open');
        for(var i=0;i<detRows.length;i++) detRows[i].style.display = 'table-row';
        allExpanded = true;
        document.getElementById('expandBtn').textContent = '📁 Collapse All';
        setTimeout(function(){ window.print(); }, 100);
      }

      // ─── Sort detail table ───
      var sortDir = {};
      function sortTable(col, type){
        var tb = document.getElementById('detailBody');
        var rows = Array.from(tb.querySelectorAll('tr:not(.sub-row)'));
        var dir = sortDir[col] = !(sortDir[col]||false);
        rows.sort(function(a,b){
          var av = a.cells[col] ? a.cells[col].textContent.trim() : '';
          var bv = b.cells[col] ? b.cells[col].textContent.trim() : '';
          if(type==='n'){
            av = parseFloat(av)||0; bv = parseFloat(bv)||0;
          } else {
            av = av.toLowerCase(); bv = bv.toLowerCase();
          }
          if(av<bv) return dir ? -1 : 1;
          if(av>bv) return dir ? 1 : -1;
          return 0;
        });
        // Re-insert sorted (skip sub-rows)
        rows.forEach(function(r){ tb.appendChild(r); });
        // Move sub-rows after their group
        var subRows = Array.from(tb.querySelectorAll('.sub-row'));
        subRows.forEach(function(sr){
          var cat = sr.getAttribute('data-cat');
          var lastOfCat = null;
          var all = tb.querySelectorAll('tr[data-cat="'+cat+'"]:not(.sub-row)');
          if(all.length) lastOfCat = all[all.length-1];
          if(lastOfCat && lastOfCat.nextSibling !== sr){
            lastOfCat.parentNode.insertBefore(sr, lastOfCat.nextSibling);
          }
        });
      }

      // ─── Search / filter ───
      function filterReport(){
        var q = document.getElementById('searchBox').value.toLowerCase();
        var rows = document.querySelectorAll('#detailBody tr:not(.sub-row)');
        for(var i=0;i<rows.length;i++){
          var txt = rows[i].textContent.toLowerCase();
          rows[i].style.display = (!q || txt.indexOf(q)>=0) ? 'table-row' : 'none';
        }
        // Also filter summary
        var srows = document.querySelectorAll('.sum-row');
        for(var i=0;i<srows.length;i++){
          var txt = srows[i].textContent.toLowerCase();
          srows[i].style.display = (!q || txt.indexOf(q)>=0) ? 'table-row' : 'none';
        }
      }

      // ─── Toggle columns ───
      var hiddenCols = {};
      function toggleCol(colIdx){
        hiddenCols[colIdx] = !hiddenCols[colIdx];
        var table = document.getElementById('detailTable');
        var rows = table.querySelectorAll('tr');
        for(var i=0;i<rows.length;i++){
          var cell = rows[i].cells[colIdx];
          if(cell) cell.style.display = hiddenCols[colIdx] ? 'none' : '';
        }
        // Update button state
        var labels = {8:'colSF',9:'colBF',10:'colLF',11:'colFT3'};
        var btn = document.getElementById(labels[colIdx]);
        if(btn) btn.classList.toggle('active', !hiddenCols[colIdx]);
      }
      // Initialize buttons as active
      document.addEventListener('DOMContentLoaded', function(){
        ['colSF','colBF','colLF','colFT3'].forEach(function(id){
          document.getElementById(id).classList.add('active');
        });
      });

      // ─── Download as CSV from browser ───
      function downloadCSV(){
        var table = document.getElementById('detailTable');
        var rows = table.querySelectorAll('tr');
        var csv = [];
        for(var i=0;i<rows.length;i++){
          if(rows[i].style.display==='none' && !rows[i].closest('thead')) continue;
          var cols = rows[i].querySelectorAll('th,td');
          var row = [];
          for(var j=0;j<cols.length;j++){
            if(cols[j].style.display==='none') continue;
            var val = cols[j].textContent.trim().replace(/[⇅▶]/g,'').trim();
            if(val.indexOf(',')>=0 || val.indexOf('"')>=0) val = '"'+val.replace(/"/g,'""')+'"';
            row.push(val);
          }
          csv.push(row.join(','));
        }
        var blob = new Blob([csv.join('\\n')], {type:'text/csv'});
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'takeoff_detail.csv';
        a.click();
      }
      </script>
      </body>
      </html>
      HTML
    end

    private

    def self.ce(s)
      s = s.to_s
      s.include?(',') || s.include?('"') || s.include?("\n") ? '"' + s.gsub('"','""') + '"' : s
    end

    def self.h(s)
      return '' unless s
      s.to_s.gsub('&','&amp;').gsub('<','&lt;').gsub('>','&gt;').gsub('"','&quot;')
    end
  end
end
