module TakeoffTool

  load File.join(PLUGIN_DIR, 'scanner.rb')
  load File.join(PLUGIN_DIR, 'parser.rb')
  load File.join(PLUGIN_DIR, 'dashboard.rb')
  load File.join(PLUGIN_DIR, 'startup_dialog.rb')
  load File.join(PLUGIN_DIR, 'exporter.rb')
  load File.join(PLUGIN_DIR, 'highlighter.rb')
  load File.join(PLUGIN_DIR, 'measure_lf.rb')
  load File.join(PLUGIN_DIR, 'measure_sf.rb')
  load File.join(PLUGIN_DIR, 'identify_dialog.rb')
  load File.join(PLUGIN_DIR, 'context_menu.rb')
  load File.join(PLUGIN_DIR, 'parse_logger.rb')

  @scan_results = []
  @category_assignments = {}
  @cost_code_assignments = {}
  @entity_registry = {}

  class << self
    attr_accessor :scan_results, :category_assignments, :cost_code_assignments, :entity_registry
  end

  def self.find_entity(eid)
    eid = eid.to_i
    e = @entity_registry[eid]
    return e if e && e.valid?
    # Fallback: search active model if registry miss
    model = Sketchup.active_model
    return nil unless model
    model.definitions.each do |defn|
      defn.instances.each do |inst|
        if inst.entityID == eid
          @entity_registry[eid] = inst
          return inst
        end
      end
    end
    nil
  end

  # Selection observer removed — was calling Dashboard.scroll_to_entity on every
  # selection change via execute_script, causing performance issues in large models.

  unless @menu_loaded
    sub = UI.menu('Extensions').add_submenu(PLUGIN_NAME)
    sub.add_item('Scan Model') { StartupDialog.show }
    sub.add_item('Open Dashboard') { TakeoffTool.open_dashboard }
    sub.add_separator
    sub.add_item('📏 LF Measure Tool') { TakeoffTool.activate_lf_tool }
    sub.add_item('📐 SF Measure Tool') { TakeoffTool.activate_sf_tool }
    sub.add_separator
    sub.add_item('Highlight by Category') { Highlighter.highlight_all(@scan_results, @category_assignments) }
    sub.add_item('Clear Highlights') { Highlighter.clear_all }
    sub.add_item('Show All Elements') { Highlighter.show_all }
    sub.add_separator
    sub.add_item('Export CSV') { Exporter.export_csv(@scan_results, @category_assignments, @cost_code_assignments) }
    sub.add_item('Export Report (HTML)') { Exporter.export_html(@scan_results, @category_assignments, @cost_code_assignments) }
    sub.add_separator
    sub.add_item('About') { UI.messagebox("#{PLUGIN_NAME} v#{PLUGIN_VERSION}\n\nInteractive construction takeoff tool.\nScans Revit imports and generates quantities.") }
    @menu_loaded = true
  end

  def self.run_scan(progress_dlg = nil)
    m = Sketchup.active_model
    return UI.messagebox("No model open.") unless m

    begin
      Dashboard.scan_log_start

      @scan_results, @entity_registry = Scanner.scan_model(m) do |msg|
        Dashboard.scan_log_msg(msg)
        if progress_dlg
          safe = msg.to_s.gsub("\\", "\\\\").gsub("'", "\\\\'")
          progress_dlg.execute_script("if(typeof scanMsg==='function')scanMsg('#{safe}')") rescue nil
        end
      end

      Dashboard.scan_log_msg("Loading saved assignments...")
      load_saved_assignments
      load_manual_measurements

      Dashboard.scan_log_msg("Generating parse log...")
      begin
        count = ParseLogger.generate(@scan_results, @entity_registry, @category_assignments, @cost_code_assignments)
        Dashboard.scan_log_msg("Parse log saved to Desktop (#{count} entities)")
        if progress_dlg
          progress_dlg.execute_script("if(typeof scanMsg==='function')scanMsg('Parse log saved to Desktop')") rescue nil
        end
      rescue => log_err
        puts "Takeoff: ParseLogger error: #{log_err.message}"
        Dashboard.scan_log_msg("Parse log error: #{log_err.message}")
      end

      if @scan_results.empty?
        Dashboard.scan_log_end("No components found.")
        if progress_dlg
          progress_dlg.execute_script("if(typeof scanComplete==='function')scanComplete('No components found.')") rescue nil
        end
        UI.messagebox("No components found.")
      else
        saved = @category_assignments.length + @cost_code_assignments.length
        cats = @scan_results.map{|r| r[:parsed][:auto_category]}.compact.uniq.reject{|c| c=='_IGNORE'}.length
        summary = "#{@scan_results.length} elements, #{@scan_results.map{|r|r[:display_name]}.uniq.length} types, #{cats} categories"
        summary += ", #{saved} saved assignments" if saved > 0
        Dashboard.scan_log_end(summary)
        if progress_dlg
          safe = summary.gsub("\\", "\\\\").gsub("'", "\\\\'")
          progress_dlg.execute_script("if(typeof scanComplete==='function')scanComplete('#{safe}')") rescue nil
        end
        open_dashboard
      end
    rescue => e
      Dashboard.scan_log_end("ERROR: #{e.message}")
      puts "Takeoff run_scan error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      UI.messagebox("Scan error: #{e.message}")
    end
  end

  # Save a single assignment to the entity's attribute dictionary
  def self.save_assignment(eid, key, value)
    e = find_entity(eid)
    if e && e.valid?
      begin
        e.set_attribute('TakeoffAssignments', key, value)
      rescue => err
        puts "Takeoff: save_assignment error eid=#{eid} key=#{key}: #{err.message}"
      end
    else
      puts "Takeoff: save_assignment - entity #{eid} not found"
    end
  end

  # Load all saved assignments from entity attributes after scan
  def self.load_saved_assignments
    count_cat = 0
    count_cc = 0
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      begin
        cat = e.get_attribute('TakeoffAssignments', 'category')
        if cat && !cat.empty?
          @category_assignments[eid] = cat
          count_cat += 1
        end
        cc = e.get_attribute('TakeoffAssignments', 'cost_code')
        if cc && !cc.empty?
          @cost_code_assignments[eid] = cc
          count_cc += 1
        end
        sz = e.get_attribute('TakeoffAssignments', 'size')
        if sz && !sz.empty?
          # Update scan result with saved size
          @scan_results.each do |r|
            if r[:entity_id] == eid
              r[:parsed][:size_nominal] = sz
              break
            end
          end
        end
      rescue => err
        puts "Takeoff: load_saved error eid=#{eid}: #{err.message}"
      end
    end
    puts "Takeoff: Loaded #{count_cat} saved categories, #{count_cc} saved cost codes" if (count_cat + count_cc) > 0
  end

  def self.open_dashboard
    if @scan_results.empty?
      r = UI.messagebox("No scan data. Run scan first?", MB_YESNO)
      return r == IDYES ? run_scan : nil
    end
    Dashboard.show(@scan_results, @category_assignments, @cost_code_assignments)
  end
end
