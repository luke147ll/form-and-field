module TakeoffTool
  module BugReporter
    @dialog = nil

    CATEGORIES = [
      'UI', 'Dashboard', 'Parser', 'Navigation', 'Drill Bit',
      'Measurements (LF)', 'Measurements (SF)', 'Export/CSV',
      'Report', 'Highlighting', 'Context Menu', 'Performance', 'Other'
    ].freeze

    SEVERITIES = ['Critical', 'Major', 'Minor', 'Suggestion'].freeze

    SEV_COLORS = {
      'Critical'   => '#f38ba8',
      'Major'      => '#fab387',
      'Minor'      => '#f9e2af',
      'Suggestion' => '#89b4fa'
    }.freeze

    def self.load_bugs
      m = Sketchup.active_model
      return [] unless m
      json = m.get_attribute('FF_BugReports', 'bugs')
      return [] unless json && !json.empty?
      require 'json'
      JSON.parse(json)
    rescue => e
      puts "BugReporter: load error: #{e.message}"
      []
    end

    def self.save_bugs(bugs)
      m = Sketchup.active_model
      return unless m
      require 'json'
      m.set_attribute('FF_BugReports', 'bugs', JSON.generate(bugs))
    end

    def self.send_data
      return unless @dialog
      bugs = load_bugs
      require 'json'
      payload = JSON.generate({ bugs: bugs, count: bugs.length })
      esc = payload.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveData('#{esc}')")
    end

    def self.show(view = 'list')
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        @dialog.execute_script("switchView('#{view}')")
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field — Bug Reporter",
        preferences_key: "TakeoffBugReporter",
        width: 500, height: 600,
        left: 200, top: 100,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.add_action_callback('requestData') do |_ctx|
        send_data
      end

      @dialog.add_action_callback('submitBug') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          bug = {
            'id'         => Time.now.to_i,
            'category'   => data['category'].to_s,
            'severity'   => data['severity'].to_s,
            'summary'    => data['summary'].to_s.strip,
            'steps'      => data['steps'].to_s.strip,
            'timestamp'  => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
            'su_version' => Sketchup.version,
            'model_name' => m ? m.title : 'Unknown',
            'ff_version' => PLUGIN_VERSION,
            'status'     => 'open'
          }
          bugs = load_bugs
          bugs << bug
          save_bugs(bugs)
          puts "BugReporter: Submitted bug ##{bug['id']} — #{bug['summary']}"
          send_data
        rescue => e
          puts "BugReporter: submit error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deleteBug') do |_ctx, id_str|
        begin
          id = id_str.to_s.to_i
          bugs = load_bugs
          bugs.reject! { |b| b['id'] == id }
          save_bugs(bugs)
          puts "BugReporter: Deleted bug ##{id}"
          send_data
        rescue => e
          puts "BugReporter: delete error: #{e.message}"
        end
      end

      @dialog.add_action_callback('exportReport') do |_ctx|
        export_report
      end

      @dialog.set_html(build_html)
      @dialog.show

      UI.start_timer(0.3, false) do
        @dialog.execute_script("switchView('#{view}')") if @dialog && @dialog.visible?
      end
    end

    def self.export_report
      bugs = load_bugs
      recat_entries = RecatLog.load_entries rescue []
      if bugs.empty? && recat_entries.empty?
        UI.messagebox("No bugs or recategorizations to export.")
        return
      end
      m = Sketchup.active_model
      default_name = "FF_BugReport_#{Time.now.strftime('%Y-%m-%d')}.txt"
      path = UI.savepanel("Save Bug Report", nil, default_name)
      return unless path

      sev_order = { 'Critical' => 0, 'Major' => 1, 'Minor' => 2, 'Suggestion' => 3 }
      grouped = bugs.group_by { |b| b['category'] || 'Other' }

      lines = []
      lines << "=" * 45
      lines << "FORM AND FIELD — BUG REPORT"
      lines << "Generated: #{Time.now.strftime('%Y-%m-%d %H:%M')}"
      lines << "Model: #{m ? m.title : 'Unknown'}"
      lines << "SU Version: #{Sketchup.version}"
      lines << "FF Version: #{PLUGIN_VERSION}"
      lines << "Total Bugs: #{bugs.length}"
      lines << "=" * 45
      lines << ""

      grouped.sort_by { |k, _| k }.each do |cat, cat_bugs|
        sorted = cat_bugs.sort_by { |b| sev_order[b['severity']] || 9 }
        lines << "## #{cat} (#{sorted.length} bug#{'s' if sorted.length != 1})"
        lines << ""
        sorted.each do |b|
          lines << "[#{(b['severity'] || 'Minor').upcase}] #{b['summary']}"
          lines << "Steps: #{b['steps']}" if b['steps'] && !b['steps'].strip.empty?
          lines << "Reported: #{b['timestamp']}"
          lines << ""
        end
      end

      # Append recategorization log
      recat_text = RecatLog.export_text rescue ''
      unless recat_text.strip.empty?
        lines << ""
        lines << recat_text
      end

      File.write(path, lines.join("\n"))
      UI.messagebox("Bug report exported to:\n#{path}")
    end

    def self.build_html
      cat_options = CATEGORIES.map { |c| "<option value=\"#{c}\">#{c}</option>" }.join("\n              ")
      sev_options = SEVERITIES.map { |s| "<option value=\"#{s}\">#{s}</option>" }.join("\n              ")

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              font-family: 'Segoe UI', system-ui, sans-serif;
              font-size: 13px;
              background: #1e1e2e;
              color: #cdd6f4;
              display: flex;
              flex-direction: column;
              height: 100vh;
              overflow: hidden;
            }
            .header {
              padding: 16px 16px 0 16px;
            }
            h1 {
              font-size: 14px;
              font-weight: 700;
              color: #cba6f7;
              text-transform: uppercase;
              letter-spacing: 1.5px;
              margin-bottom: 12px;
            }
            .tabs {
              display: flex;
              gap: 0;
              border-bottom: 2px solid #313244;
              margin-bottom: 0;
            }
            .tab {
              padding: 8px 20px;
              cursor: pointer;
              color: #6c7086;
              font-size: 13px;
              font-weight: 600;
              border-bottom: 2px solid transparent;
              margin-bottom: -2px;
              transition: color 0.15s, border-color 0.15s;
              user-select: none;
            }
            .tab:hover { color: #a6adc8; }
            .tab.active {
              color: #cba6f7;
              border-bottom-color: #cba6f7;
            }
            .content {
              flex: 1;
              overflow: hidden;
              display: flex;
              flex-direction: column;
            }
            /* Bug List View */
            #view-list {
              flex: 1;
              display: flex;
              flex-direction: column;
              overflow: hidden;
            }
            .bug-list {
              flex: 1;
              overflow-y: auto;
              padding: 12px 16px;
            }
            .bug-card {
              background: #313244;
              border-radius: 8px;
              padding: 10px 12px;
              margin-bottom: 8px;
              position: relative;
            }
            .bug-top {
              display: flex;
              align-items: center;
              gap: 8px;
              margin-bottom: 6px;
            }
            .badge {
              display: inline-block;
              padding: 2px 8px;
              border-radius: 3px;
              font-size: 10px;
              font-weight: 700;
              text-transform: uppercase;
              letter-spacing: 0.5px;
            }
            .badge-cat {
              background: #45475a;
              color: #cdd6f4;
            }
            .sev-dot {
              width: 8px;
              height: 8px;
              border-radius: 50%;
              flex-shrink: 0;
            }
            .bug-summary {
              font-size: 13px;
              font-weight: 500;
              color: #cdd6f4;
              margin-bottom: 4px;
              padding-right: 24px;
            }
            .bug-steps {
              font-size: 11px;
              color: #a6adc8;
              margin-bottom: 4px;
              white-space: pre-wrap;
              max-height: 60px;
              overflow: hidden;
            }
            .bug-time {
              font-size: 10px;
              color: #6c7086;
            }
            .bug-delete {
              position: absolute;
              top: 8px;
              right: 8px;
              background: none;
              border: none;
              color: #f38ba8;
              font-size: 14px;
              cursor: pointer;
              padding: 2px 6px;
              border-radius: 3px;
              opacity: 0.6;
            }
            .bug-delete:hover { opacity: 1; background: #45475a; }
            .bottom-bar {
              padding: 10px 16px;
              border-top: 1px solid #313244;
              display: flex;
              justify-content: flex-end;
            }
            .btn-export {
              padding: 8px 16px;
              background: #a6e3a1;
              color: #1e1e2e;
              border: none;
              border-radius: 4px;
              font-size: 12px;
              font-weight: 700;
              cursor: pointer;
              text-transform: uppercase;
              letter-spacing: 0.5px;
            }
            .btn-export:hover { background: #94e2d5; }
            .empty-state {
              text-align: center;
              color: #6c7086;
              padding: 40px 20px;
              font-size: 13px;
            }
            /* New Bug Form View */
            #view-new {
              display: none;
              flex: 1;
              overflow-y: auto;
              padding: 16px;
            }
            label {
              display: block;
              font-size: 11px;
              color: #a6adc8;
              text-transform: uppercase;
              letter-spacing: 0.5px;
              margin-bottom: 4px;
              margin-top: 12px;
            }
            label:first-child { margin-top: 0; }
            select, input[type="text"], textarea {
              width: 100%;
              padding: 8px 10px;
              background: #45475a;
              color: #cdd6f4;
              border: 1px solid #585b70;
              border-radius: 4px;
              font-size: 13px;
              font-family: inherit;
            }
            select:focus, input[type="text"]:focus, textarea:focus {
              outline: none;
              border-color: #89b4fa;
            }
            textarea {
              min-height: 100px;
              resize: vertical;
            }
            .btn-submit {
              width: 100%;
              padding: 10px;
              margin-top: 16px;
              background: #cba6f7;
              color: #1e1e2e;
              border: none;
              border-radius: 4px;
              font-size: 13px;
              font-weight: 700;
              cursor: pointer;
              text-transform: uppercase;
              letter-spacing: 0.5px;
            }
            .btn-submit:hover { background: #b4befe; }
            /* Scrollbar */
            ::-webkit-scrollbar { width: 6px; }
            ::-webkit-scrollbar-track { background: #1e1e2e; }
            ::-webkit-scrollbar-thumb { background: #45475a; border-radius: 3px; }
            ::-webkit-scrollbar-thumb:hover { background: #585b70; }
          </style>
        </head>
        <body>
          <div class="header">
            <h1 id="title">Bug Reports</h1>
            <div class="tabs">
              <div class="tab active" id="tab-list" onclick="switchView('list')">Bug List</div>
              <div class="tab" id="tab-new" onclick="switchView('new')">New Bug</div>
            </div>
          </div>
          <div class="content">
            <div id="view-list">
              <div class="bug-list" id="bug-list">
                <div class="empty-state">No bugs reported yet.</div>
              </div>
              <div class="bottom-bar">
                <button class="btn-export" onclick="sketchup.exportReport()">Export Report</button>
              </div>
            </div>
            <div id="view-new">
              <label>Category</label>
              <select id="f-cat">
                #{cat_options}
              </select>
              <label>Severity</label>
              <select id="f-sev">
                #{sev_options}
              </select>
              <label>Summary</label>
              <input type="text" id="f-summary" placeholder="Brief description of the issue">
              <label>Steps to Reproduce</label>
              <textarea id="f-steps" placeholder="What were you doing when this happened?"></textarea>
              <button class="btn-submit" onclick="submitBug()">Submit Bug</button>
            </div>
          </div>
          <script>
            var BUGS = [];
            var SEV_COLORS = {
              'Critical': '#f38ba8',
              'Major':    '#fab387',
              'Minor':    '#f9e2af',
              'Suggestion':'#89b4fa'
            };

            function receiveData(json) {
              try {
                var d = JSON.parse(json);
                BUGS = d.bugs || [];
                renderBugs();
              } catch(e) {
                console.log('receiveData error: ' + e);
              }
            }

            function switchView(v) {
              var vl = document.getElementById('view-list');
              var vn = document.getElementById('view-new');
              var tl = document.getElementById('tab-list');
              var tn = document.getElementById('tab-new');
              if (v === 'new') {
                vl.style.display = 'none';
                vn.style.display = 'block';
                tl.className = 'tab';
                tn.className = 'tab active';
              } else {
                vl.style.display = 'flex';
                vn.style.display = 'none';
                tl.className = 'tab active';
                tn.className = 'tab';
              }
            }

            function renderBugs() {
              var el = document.getElementById('bug-list');
              var title = document.getElementById('title');
              title.textContent = 'Bug Reports (' + BUGS.length + ')';
              if (BUGS.length === 0) {
                el.innerHTML = '<div class="empty-state">No bugs reported yet.</div>';
                return;
              }
              var html = '';
              for (var i = BUGS.length - 1; i >= 0; i--) {
                var b = BUGS[i];
                var sc = SEV_COLORS[b.severity] || '#6c7086';
                var steps = b.steps ? '<div class="bug-steps">' + esc(b.steps) + '</div>' : '';
                html += '<div class="bug-card">'
                  + '<div class="bug-top">'
                  + '<span class="sev-dot" style="background:' + sc + '" title="' + esc(b.severity) + '"></span>'
                  + '<span class="badge badge-cat">' + esc(b.category) + '</span>'
                  + '</div>'
                  + '<div class="bug-summary">' + esc(b.summary) + '</div>'
                  + steps
                  + '<div class="bug-time">' + esc(b.timestamp || '') + '</div>'
                  + '<button class="bug-delete" onclick="deleteBug(' + b.id + ')" title="Delete">&times;</button>'
                  + '</div>';
              }
              el.innerHTML = html;
            }

            function esc(s) {
              if (!s) return '';
              var d = document.createElement('div');
              d.textContent = s;
              return d.innerHTML;
            }

            function submitBug() {
              var cat = document.getElementById('f-cat').value;
              var sev = document.getElementById('f-sev').value;
              var summary = document.getElementById('f-summary').value.trim();
              var steps = document.getElementById('f-steps').value.trim();
              if (!summary) {
                document.getElementById('f-summary').style.borderColor = '#f38ba8';
                document.getElementById('f-summary').focus();
                return;
              }
              sketchup.submitBug(JSON.stringify({
                category: cat,
                severity: sev,
                summary: summary,
                steps: steps
              }));
              // Clear form
              document.getElementById('f-summary').value = '';
              document.getElementById('f-steps').value = '';
              document.getElementById('f-summary').style.borderColor = '#585b70';
              switchView('list');
            }

            function deleteBug(id) {
              sketchup.deleteBug(String(id));
            }

            // Request data on load
            document.addEventListener('DOMContentLoaded', function() {
              sketchup.requestData();
            });

            // Enter to submit from summary field
            document.addEventListener('keydown', function(e) {
              if (e.key === 'Enter' && e.target.id === 'f-summary') {
                e.preventDefault();
                submitBug();
              }
            });
          </script>
        </body>
        </html>
      HTML
    end
  end
end
