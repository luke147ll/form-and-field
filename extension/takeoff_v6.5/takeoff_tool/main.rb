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
  load File.join(PLUGIN_DIR, 'precision_nav.rb')
  load File.join(PLUGIN_DIR, 'drill_bit.rb')
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
    nav_cmd = UI::Command.new('Precision Navigation') { PrecisionNav.toggle }
    nav_cmd.set_validation_proc { PrecisionNav.enabled? ? MF_CHECKED : MF_UNCHECKED }
    sub.add_item(nav_cmd)
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

  unless @toolbar_loaded
    toolbar = UI::Toolbar.new("Form and Field")

    cmd_scan = UI::Command.new("Scan Model") { StartupDialog.show }
    cmd_scan.small_icon = File.join(PLUGIN_DIR, "icons", "scan_ufo_24.png")
    cmd_scan.large_icon = File.join(PLUGIN_DIR, "icons", "scan_ufo_32.png")
    cmd_scan.tooltip = "Scan Model"
    cmd_scan.status_bar_text = "Scan the model and categorize all components"
    toolbar.add_item(cmd_scan)

    cmd_drill = UI::Command.new("Drill Bit") { DrillBit.toggle }
    cmd_drill.small_icon = File.join(PLUGIN_DIR, "icons", "drill_bit_24.png")
    cmd_drill.large_icon = File.join(PLUGIN_DIR, "icons", "drill_bit_32.png")
    cmd_drill.tooltip = "Drill Bit - Click through nested components"
    cmd_drill.status_bar_text = "Activate Drill Bit mode to select deeply nested components"
    toolbar.add_item(cmd_drill)

    cmd_nav = UI::Command.new("Precision Nav") { PrecisionNav.toggle }
    cmd_nav.small_icon = File.join(PLUGIN_DIR, "icons", "nav_mode_24.png")
    cmd_nav.large_icon = File.join(PLUGIN_DIR, "icons", "nav_mode_32.png")
    cmd_nav.tooltip = "Precision Nav - Fly through the model"
    cmd_nav.status_bar_text = "Activate fly camera navigation mode"
    toolbar.add_item(cmd_nav)

    cmd_identify = UI::Command.new("Identify") {
      sel = Sketchup.active_model.selection
      IdentifyDialog.show(sel) if sel && !sel.empty?
    }
    cmd_identify.small_icon = File.join(PLUGIN_DIR, "icons", "identify_24.png")
    cmd_identify.large_icon = File.join(PLUGIN_DIR, "icons", "identify_32.png")
    cmd_identify.tooltip = "Identify - Inspect selected component"
    cmd_identify.status_bar_text = "Show details about the selected component"
    toolbar.add_item(cmd_identify)

    cmd_report = UI::Command.new("View Report") { TakeoffTool.open_dashboard }
    cmd_report.small_icon = File.join(PLUGIN_DIR, "icons", "report_24.png")
    cmd_report.large_icon = File.join(PLUGIN_DIR, "icons", "report_32.png")
    cmd_report.tooltip = "View Report"
    cmd_report.status_bar_text = "Open the takeoff dashboard"
    toolbar.add_item(cmd_report)

    # Dev reload button (only in debug mode)
    if Sketchup.read_default("FormAndField", "debug_mode", false)
      cmd_reload = UI::Command.new("Reload FF") {
        load 'takeoff_tool/main.rb'
        puts "Form and Field reloaded!"
      }
      cmd_reload.small_icon = File.join(PLUGIN_DIR, "icons", "report_24.png")
      cmd_reload.large_icon = File.join(PLUGIN_DIR, "icons", "report_32.png")
      cmd_reload.tooltip = "DEV: Reload Form and Field"
      cmd_reload.status_bar_text = "Reload the Form and Field plugin (dev mode)"
      toolbar.add_item(cmd_reload)
    end

    toolbar.show
    @toolbar_loaded = true
  end

  unless @auto_load_done
    UI.start_timer(1.0, false) do
      if load_scan_from_model
        puts "Takeoff: Scan data restored - dashboard ready"
      end
    end
    @auto_load_done = true
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
        save_scan_to_model
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

  # Save model-level scan metadata
  def self.save_scan_metadata(model)
    model.set_attribute('FormAndField', 'scan_version', PLUGIN_VERSION)
    model.set_attribute('FormAndField', 'scan_time', Time.now.to_i)
    model.set_attribute('FormAndField', 'scan_count', @scan_results.length)
    model.set_attribute('FormAndField', 'def_count',
      model.definitions.count { |d| !d.image? && d.instances.length > 0 })
  end

  # Persist scan results to entity attributes so data survives between sessions
  def self.save_scan_to_model
    m = Sketchup.active_model
    return unless m
    save_scan_metadata(m)
    count = 0
    @scan_results.each do |r|
      next if r[:source] == :manual_lf || r[:source] == :manual_sf
      e = @entity_registry[r[:entity_id]]
      next unless e && e.valid?
      d = 'TakeoffScanData'
      e.set_attribute(d, 'display_name', r[:display_name].to_s)
      e.set_attribute(d, 'tag', r[:tag].to_s)
      e.set_attribute(d, 'auto_category', r[:parsed][:auto_category].to_s)
      e.set_attribute(d, 'auto_subcategory', (r[:parsed][:auto_subcategory] || '').to_s)
      e.set_attribute(d, 'measurement_type', (r[:parsed][:measurement_type] || '').to_s)
      e.set_attribute(d, 'category_source', (r[:parsed][:category_source] || '').to_s)
      e.set_attribute(d, 'is_solid', r[:is_solid] ? true : false)
      e.set_attribute(d, 'volume_ft3', r[:volume_ft3].to_f)
      e.set_attribute(d, 'area_sf', r[:area_sf] ? r[:area_sf].to_f : 0.0)
      e.set_attribute(d, 'linear_ft', r[:linear_ft].to_f)
      e.set_attribute(d, 'instance_count', r[:instance_count].to_i)
      e.set_attribute(d, 'material', (r[:material] || '').to_s)
      e.set_attribute(d, 'ifc_type', (r[:ifc_type] || '').to_s)
      e.set_attribute(d, 'element_type', (r[:parsed][:element_type] || '').to_s)
      e.set_attribute(d, 'function', (r[:parsed][:function] || '').to_s)
      e.set_attribute(d, 'parsed_material', (r[:parsed][:material] || '').to_s)
      e.set_attribute(d, 'thickness', (r[:parsed][:thickness] || '').to_s)
      e.set_attribute(d, 'size_nominal', (r[:parsed][:size_nominal] || '').to_s)
      e.set_attribute(d, 'revit_id', (r[:parsed][:revit_id] || '').to_s)
      count += 1
    end
    puts "Takeoff: Saved #{count} scan results to model"
  rescue => e
    puts "Takeoff: save_scan_to_model error: #{e.message}"
  end

  # Reconstruct scan results from saved entity attributes (no expensive recomputation)
  def self.load_scan_from_model
    m = Sketchup.active_model
    return false unless m
    return false unless m.get_attribute('FormAndField', 'scan_version')

    puts "Takeoff: Loading saved scan data..."
    @scan_results = []
    @entity_registry = {}
    @category_assignments = {}
    @cost_code_assignments = {}

    m.definitions.each do |defn|
      next if defn.image?
      defn.instances.each do |inst|
        d = 'TakeoffScanData'
        auto_cat = inst.get_attribute(d, 'auto_category')
        next unless auto_cat && !auto_cat.empty?

        dname = defn.name || ''
        bb = inst.bounds
        w = bb.width.to_f; h = bb.height.to_f; dp = bb.depth.to_f

        vol_ft3 = (inst.get_attribute(d, 'volume_ft3') || 0.0).to_f
        vi3 = vol_ft3 * 1728.0

        parsed = {
          raw: inst.get_attribute(d, 'display_name') || dname,
          element_type: inst.get_attribute(d, 'element_type'),
          function: inst.get_attribute(d, 'function'),
          material: inst.get_attribute(d, 'parsed_material'),
          thickness: inst.get_attribute(d, 'thickness'),
          size_nominal: inst.get_attribute(d, 'size_nominal'),
          revit_id: inst.get_attribute(d, 'revit_id'),
          auto_category: auto_cat,
          auto_subcategory: inst.get_attribute(d, 'auto_subcategory') || '',
          measurement_type: inst.get_attribute(d, 'measurement_type'),
          category_source: inst.get_attribute(d, 'category_source')
        }
        parsed.each { |k, v| parsed[k] = nil if v.is_a?(String) && v.empty? && k != :auto_subcategory }

        asf_raw = inst.get_attribute(d, 'area_sf')
        asf = (asf_raw && asf_raw.to_f > 0) ? asf_raw.to_f.round(2) : nil

        result = {
          entity_id: inst.entityID,
          entity_type: inst.typename,
          tag: inst.get_attribute(d, 'tag') || (inst.layer ? inst.layer.name : 'Untagged'),
          definition_name: dname,
          display_name: inst.get_attribute(d, 'display_name') || dname,
          instance_name: (inst.name && !inst.name.empty?) ? inst.name : nil,
          is_solid: inst.get_attribute(d, 'is_solid') || false,
          instance_count: (inst.get_attribute(d, 'instance_count') || 1).to_i,
          ifc_type: inst.get_attribute(d, 'ifc_type'),
          volume_in3: vi3.round(2),
          volume_ft3: vol_ft3.round(4),
          volume_bf: (vi3 / 144.0).round(2),
          bb_width_in: w.round(2), bb_height_in: h.round(2), bb_depth_in: dp.round(2),
          linear_ft: (inst.get_attribute(d, 'linear_ft') || 0.0).to_f.round(2),
          area_sf: asf,
          material: inst.get_attribute(d, 'material'),
          parsed: parsed, warnings: []
        }
        # Clean nil/empty ifc_type and material
        result[:ifc_type] = nil if result[:ifc_type].is_a?(String) && result[:ifc_type].empty?
        result[:material] = nil if result[:material].is_a?(String) && result[:material].empty?

        @scan_results << result
        @entity_registry[inst.entityID] = inst
      end
    end

    @scan_results.sort_by! { |r| [r[:tag] || 'zzz', r[:display_name] || ''] }

    load_saved_assignments
    load_manual_measurements

    # Change detection
    saved_defs = m.get_attribute('FormAndField', 'def_count') || 0
    current_defs = m.definitions.count { |dd| !dd.image? && dd.instances.length > 0 }
    if saved_defs > 0 && (current_defs - saved_defs).abs > [saved_defs * 0.1, 5].max
      puts "Takeoff: WARNING - Model changed since last scan (#{saved_defs} -> #{current_defs} active defs). Consider rescanning."
    end

    puts "Takeoff: Loaded #{@scan_results.length} elements from saved scan data"
    true
  rescue => e
    puts "Takeoff: load_scan_from_model error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    false
  end

  def self.open_dashboard
    if @scan_results.empty?
      unless load_scan_from_model
        r = UI.messagebox("No scan data. Run scan first?", MB_YESNO)
        return r == IDYES ? run_scan : nil
      end
    end
    # Check staleness
    m = Sketchup.active_model
    if m
      saved_defs = m.get_attribute('FormAndField', 'def_count') || 0
      current_defs = m.definitions.count { |d| !d.image? && d.instances.length > 0 }
      if saved_defs > 0 && (current_defs - saved_defs).abs > [saved_defs * 0.1, 5].max
        r = UI.messagebox("Model appears to have changed since last scan.\nRescan now?", MB_YESNO)
        return run_scan if r == IDYES
      end
    end
    Dashboard.show(@scan_results, @category_assignments, @cost_code_assignments)
  end
end
