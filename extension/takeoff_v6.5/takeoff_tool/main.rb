module TakeoffTool

  load File.join(PLUGIN_DIR, 'event_bus.rb')
  load File.join(PLUGIN_DIR, 'category_manager.rb')
  load File.join(PLUGIN_DIR, 'assembly_manager.rb')
  load File.join(PLUGIN_DIR, 'parts_manager.rb')
  load File.join(PLUGIN_DIR, 'persistence.rb')
  load File.join(PLUGIN_DIR, 'scanner.rb')
  load File.join(PLUGIN_DIR, 'parser.rb')
  load File.join(PLUGIN_DIR, 'cost_code_parser.rb')
  load File.join(PLUGIN_DIR, 'learning_system.rb')
  load File.join(PLUGIN_DIR, 'interactive_scanner.rb')
  load File.join(PLUGIN_DIR, 'dashboard.rb')
  load File.join(PLUGIN_DIR, 'dash_visibility.rb')
  load File.join(PLUGIN_DIR, 'dash_color.rb')
  load File.join(PLUGIN_DIR, 'dash_measurement.rb')
  load File.join(PLUGIN_DIR, 'dash_assembly.rb')
  load File.join(PLUGIN_DIR, 'dash_overlay.rb')
  load File.join(PLUGIN_DIR, 'dash_multiverse.rb')
  load File.join(PLUGIN_DIR, 'dash_scanner.rb')
  load File.join(PLUGIN_DIR, 'startup_dialog.rb')
  load File.join(PLUGIN_DIR, 'exporter.rb')
  load File.join(PLUGIN_DIR, 'color_controller.rb')
  load File.join(PLUGIN_DIR, 'highlighter.rb')
  load File.join(PLUGIN_DIR, 'measure_lf.rb')
  load File.join(PLUGIN_DIR, 'measure_sf.rb')
  load File.join(PLUGIN_DIR, 'identify_dialog.rb')
  load File.join(PLUGIN_DIR, 'precision_nav.rb')
  load File.join(PLUGIN_DIR, 'drill_bit.rb')
  load File.join(PLUGIN_DIR, 'context_menu.rb')
  load File.join(PLUGIN_DIR, 'parse_logger.rb')
  load File.join(PLUGIN_DIR, 'ifc_parser.rb')
  load File.join(PLUGIN_DIR, 'recat_log.rb')
  load File.join(PLUGIN_DIR, 'hyper_parser.rb')
  load File.join(PLUGIN_DIR, 'bug_reporter.rb')
  load File.join(PLUGIN_DIR, 'elevation_tool.rb')
  load File.join(PLUGIN_DIR, 'note_tool.rb')
  load File.join(PLUGIN_DIR, 'measure_box.rb')
  load File.join(PLUGIN_DIR, 'scan_backup.rb')
  load File.join(PLUGIN_DIR, 'geometry_matcher.rb')
  load File.join(PLUGIN_DIR, 'multiverse.rb')
  load File.join(PLUGIN_DIR, 'smart_diff.rb')
  load File.join(PLUGIN_DIR, 'category_templates.rb')
  load File.join(PLUGIN_DIR, 'section_cuts.rb')
  load File.join(PLUGIN_DIR, 'flatten_pass.rb')
  load File.join(PLUGIN_DIR, 'annotation_tags.rb')
  load File.join(PLUGIN_DIR, 'cad_overlay.rb')

  @scan_results ||= []
  @category_assignments ||= {}
  @cost_code_assignments ||= {}
  @entity_registry ||= {}
  @custom_categories ||= []
  @master_categories ||= []
  @master_subcategories ||= {}
  @multiverse_data = nil unless defined?(@multiverse_data)
  @master_containers ||= []

  class << self
    attr_accessor :scan_results, :category_assignments, :cost_code_assignments,
                  :entity_registry, :custom_categories, :master_categories,
                  :master_subcategories, :multiverse_data, :master_containers
  end

  @entity_cache = nil

  def self.build_entity_cache
    t = Time.now
    @entity_cache = {}
    model = Sketchup.active_model
    return unless model

    # Index active entities
    model.active_entities.each do |e|
      @entity_cache[e.entityID] = e
    end

    # Index ALL definition entities (finds nested Model B entities)
    model.definitions.each do |defn|
      next if defn.image?
      defn.entities.each do |e|
        @entity_cache[e.entityID] = e
      end
    end

    elapsed = (Time.now - t).round(3)
    puts "[FF Cache] Built entity cache: #{@entity_cache.length} entities in #{elapsed}s"
  end

  def self.find_entity(eid)
    eid = eid.to_i
    # Fast path: entity_registry (already validated references)
    e = @entity_registry[eid]
    return e if e && e.valid?
    # Second path: entity_cache (O(1) hash lookup)
    build_entity_cache unless @entity_cache
    e = @entity_cache[eid]
    if e && e.valid?
      @entity_registry[eid] = e
      return e
    end
    nil
  end

  def self.invalidate_entity_cache
    @entity_cache = nil
  end

  # Find all scan-result entity IDs nested inside a parent entity's definition.
  # Used for cascade recat — changing a parent's category also changes children.
  def self.find_nested_scan_eids(parent_eid)
    parent = find_entity(parent_eid)
    return [] unless parent && parent.valid? && parent.respond_to?(:definition)
    scan_eid_set = Set.new(@scan_results.map { |r| r[:entity_id] })
    nested = []
    _collect_nested_eids(parent.definition, scan_eid_set, nested, Set.new)
    nested
  end

  def self._collect_nested_eids(defn, scan_eid_set, result, visited)
    return if visited.include?(defn.object_id)
    visited.add(defn.object_id)
    defn.entities.each do |e|
      next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
      result << e.entityID if scan_eid_set.include?(e.entityID)
      if e.respond_to?(:definition)
        _collect_nested_eids(e.definition, scan_eid_set, result, visited)
      end
    end
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
    sub.add_item('Set Elevation Benchmark') { TakeoffTool.activate_benchmark_tool }
    sub.add_item('Elevation Tag Tool') { TakeoffTool.activate_elevation_tool }
    sub.add_item('Note Tag Tool') { TakeoffTool.activate_note_tool }
    sub.add_item('Annotation Tag Tool') { TakeoffTool.activate_annotation_tag_tool }
    sub.add_item('📦 Box Measure Tool') { TakeoffTool.activate_box_tool }
    nav_cmd = UI::Command.new('Precision Navigation') { PrecisionNav.toggle }
    nav_cmd.set_validation_proc { PrecisionNav.enabled? ? MF_CHECKED : MF_UNCHECKED }
    sub.add_item(nav_cmd)
    sub.add_separator
    sub.add_item('Highlight by Category') { Highlighter.highlight_all(@scan_results, @category_assignments) }
    sub.add_item('Clear Highlights') { Highlighter.clear_all }
    sub.add_item('Show All Elements') { Highlighter.show_all }
    sub.add_item('Hyper Parse') { HyperParser.show_dialog }
    sub.add_item('Learned Rules') { LearningSystem.show_dialog }
    sub.add_item('Rule Builder') { LearningSystem.show_rule_builder }
    sub.add_item('Category Templates') { CategoryTemplates.show_dialog }
    sub.add_separator
    mv_sub = sub.add_submenu('Multiverse')
    mv_sub.add_item('Import Comparison Model') { TakeoffTool.import_comparison_model }
    mv_sub.add_item('Remove Comparison Model') { TakeoffTool.remove_comparison_model }
    cad_sub = sub.add_submenu('CAD Overlays')
    cad_sub.add_item('Import DWG Sheet') { TakeoffTool.import_cad_sheet }
    cad_sub.add_item('Manage Overlays') { TakeoffTool.show_cad_manager }
    sub.add_separator
    sub.add_item('Export CSV') { Exporter.export_csv(@scan_results, @category_assignments, @cost_code_assignments) }
    sub.add_item('Export Report (HTML)') { Exporter.export_html(@scan_results, @category_assignments, @cost_code_assignments) }
    sub.add_separator
    sub.add_item('Bug Reporter') { TakeoffTool::BugReporter.show }
    sub.add_item('About') { UI.messagebox("#{PLUGIN_NAME} v#{PLUGIN_VERSION}\n\nInteractive construction takeoff tool.\nScans Revit imports and generates quantities.") }
    @menu_loaded = true
  end

  unless @toolbar_loaded
    toolbar = UI::Toolbar.new("Form and Field")

    cmd_scan = UI::Command.new("Scan Model") { StartupDialog.show }
    cmd_scan.small_icon = File.join(PLUGIN_DIR, "icons", "scan_model_24.png")
    cmd_scan.large_icon = File.join(PLUGIN_DIR, "icons", "scan_model_32.png")
    cmd_scan.tooltip = "Scan Model"
    cmd_scan.status_bar_text = "Scan the model and categorize all components"
    cmd_scan.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_scan)

    cmd_drill = UI::Command.new("Ray Gun") { DrillBit.toggle }
    cmd_drill.small_icon = File.join(PLUGIN_DIR, "icons", "drill_bit_24.png")
    cmd_drill.large_icon = File.join(PLUGIN_DIR, "icons", "drill_bit_32.png")
    cmd_drill.tooltip = "Ray Gun - Click through nested components"
    cmd_drill.status_bar_text = "Activate Ray Gun mode to select deeply nested components"
    cmd_drill.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_drill)

    cmd_nav = UI::Command.new("Precision Nav") { PrecisionNav.toggle }
    cmd_nav.small_icon = File.join(PLUGIN_DIR, "icons", "nav_mode_24.png")
    cmd_nav.large_icon = File.join(PLUGIN_DIR, "icons", "nav_mode_32.png")
    cmd_nav.tooltip = "Precision Nav - Fly through the model"
    cmd_nav.status_bar_text = "Activate fly camera navigation mode"
    cmd_nav.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_nav)

    cmd_report = UI::Command.new("View Report") { TakeoffTool.open_dashboard }
    cmd_report.small_icon = File.join(PLUGIN_DIR, "icons", "dashboard_24.png")
    cmd_report.large_icon = File.join(PLUGIN_DIR, "icons", "dashboard_32.png")
    cmd_report.tooltip = "View Report"
    cmd_report.status_bar_text = "Open the takeoff dashboard"
    cmd_report.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_report)

    cmd_hp = UI::Command.new("Hyper Parse") { HyperParser.show_dialog }
    cmd_hp.small_icon = File.join(PLUGIN_DIR, "icons", "hyper_parse_24.png")
    cmd_hp.large_icon = File.join(PLUGIN_DIR, "icons", "hyper_parse_32.png")
    cmd_hp.tooltip = "Hyper Parse - Re-categorize visible entities"
    cmd_hp.status_bar_text = "Open Hyper Parse to group and re-categorize visible entities"
    cmd_hp.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_hp)

    cmd_bmk = UI::Command.new("Set Benchmark") { TakeoffTool.activate_benchmark_tool }
    cmd_bmk.small_icon = File.join(PLUGIN_DIR, "icons", "benchmark_24.png")
    cmd_bmk.large_icon = File.join(PLUGIN_DIR, "icons", "benchmark_32.png")
    cmd_bmk.tooltip = "Set Elevation Benchmark"
    cmd_bmk.status_bar_text = "Click a face to set the elevation reference point"
    cmd_bmk.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_bmk)

    cmd_elev = UI::Command.new("Elevation Tag") { TakeoffTool.activate_elevation_tool }
    cmd_elev.small_icon = File.join(PLUGIN_DIR, "icons", "elevation_24.png")
    cmd_elev.large_icon = File.join(PLUGIN_DIR, "icons", "elevation_32.png")
    cmd_elev.tooltip = "Elevation Tag — Click faces to mark elevations"
    cmd_elev.status_bar_text = "Click faces to place elevation reference tags"
    cmd_elev.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_elev)

    cmd_note = UI::Command.new("Note Tag") { TakeoffTool.activate_note_tool }
    cmd_note.small_icon = File.join(PLUGIN_DIR, "icons", "note_tag_24.png")
    cmd_note.large_icon = File.join(PLUGIN_DIR, "icons", "note_tag_32.png")
    cmd_note.tooltip = "Note Tag — Click to place text annotations"
    cmd_note.status_bar_text = "Click a point to place a text note annotation"
    cmd_note.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_note)

    cmd_anno = UI::Command.new("Annotation Tag") { TakeoffTool.activate_annotation_tag_tool }
    cmd_anno.small_icon = File.join(PLUGIN_DIR, "icons", "note_tag_24.png")
    cmd_anno.large_icon = File.join(PLUGIN_DIR, "icons", "note_tag_32.png")
    cmd_anno.tooltip = "Annotation Tag — Gridlines, Sections, Details"
    cmd_anno.status_bar_text = "Click to place numbered/lettered annotation tags"
    cmd_anno.set_validation_proc { MF_ENABLED }
    toolbar.add_item(cmd_anno)

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
        # Recompute SF using current algorithm (cached values may be stale)
        updated = (Scanner.recalculate_sf rescue 0)
        puts "Takeoff: Scan data restored - dashboard ready#{updated > 0 ? " (#{updated} SF values refreshed)" : ''}"
        ColorController.strip_baked_ff_materials if defined?(ColorController)
      end
      # Check for backup newer than last save (crash recovery)
      begin
        ScanBackup.check_for_recovery
      rescue => e
        puts "Takeoff: ScanBackup recovery check error: #{e.message}"
      end
    end
    @auto_load_done = true
  end

  def self.trigger_backup
    ScanBackup.save
  rescue => e
    puts "Takeoff: trigger_backup error: #{e.message}"
  end

  def self.run_scan(progress_dlg = nil)
    m = Sketchup.active_model
    return UI.messagebox("No model open.") unless m

    begin
      Dashboard.scan_log_start

      # Invalidate smart diff cache — model is changing
      SmartDiff.invalidate_cache rescue nil

      # Flatten import hierarchy (IFC/Revit nesting) before scanning
      if FlattenPass.needs_flatten?(m)
        Dashboard.scan_log_status("FLATTENING HIERARCHY") rescue nil
        Dashboard.scan_log_msg("Flattening import hierarchy...") rescue nil
        flatten_stats = FlattenPass.run(m) do |msg|
          Dashboard.scan_log_msg(msg)
          if progress_dlg
            safe = msg.to_s.gsub("\\", "\\\\").gsub("'", "\\\\'")
            progress_dlg.execute_script("if(typeof scanMsg==='function')scanMsg('#{safe}')") rescue nil
          end
        end
        # Mark model as flattened so we don't re-flatten on rescan
        m.set_attribute('FF_Flatten', 'flattened', true)
        msg = "Flatten complete: #{flatten_stats[:exploded]} containers removed, #{flatten_stats[:kept]} assemblies kept"
        Dashboard.scan_log_msg(msg) rescue nil
        puts "[FF] #{msg}"
      end

      mv_active = active_mv_view
      if mv_active
        # Multiverse active: only rescan Model A, preserve Model B results
        model_b_results = (@scan_results || []).select do |r|
          e = @entity_registry[r[:entity_id]]
          ms = (e && e.valid?) ? (e.get_attribute('FormAndField', 'model_source') || 'model_a') : 'model_a'
          ms != 'model_a'
        end
        model_b_reg = {}
        model_b_results.each { |r| model_b_reg[r[:entity_id]] = @entity_registry[r[:entity_id]] if @entity_registry[r[:entity_id]] }

        a_results, @entity_registry = Scanner.scan_model(m, model_source_filter: 'model_a') do |msg|
          Dashboard.scan_log_msg(msg)
          if progress_dlg
            safe = msg.to_s.gsub("\\", "\\\\").gsub("'", "\\\\'")
            progress_dlg.execute_script("if(typeof scanMsg==='function')scanMsg('#{safe}')") rescue nil
          end
        end
        # Merge Model B registry and results back
        model_b_reg.each { |eid, e| @entity_registry[eid] = e }
        @scan_results = a_results + model_b_results
        @scan_results.sort_by! { |r| [r[:tag] || 'zzz', r[:display_name] || ''] }
      else
        @scan_results, @entity_registry = Scanner.scan_model(m) do |msg|
          Dashboard.scan_log_msg(msg)
          if progress_dlg
            safe = msg.to_s.gsub("\\", "\\\\").gsub("'", "\\\\'")
            progress_dlg.execute_script("if(typeof scanMsg==='function')scanMsg('#{safe}')") rescue nil
          end
        end
      end

      Dashboard.scan_log_status("LOADING ASSIGNMENTS")
      load_saved_assignments
      load_custom_categories
      load_master_categories
      load_master_containers

      # Apply template definition map (exact GUID→category from template model)
      @template_new_entities = 0
      if defined?(CategoryTemplates) && CategoryTemplates.pending_definition_map?
        defn_applied = CategoryTemplates.apply_definition_map
        @template_new_entities = CategoryTemplates.new_entity_count
        Dashboard.scan_log_msg("Template: #{defn_applied} matched, #{@template_new_entities} new") if defn_applied > 0
      end

      merge_scan_categories_into_master
      prune_empty_categories
      load_master_subcategories
      load_manual_measurements

      if Sketchup.read_default("FormAndField", "debug_mode", false)
        Dashboard.scan_log_msg("Generating parse log (debug mode)...")
        begin
          count = ParseLogger.generate(@scan_results, @entity_registry, @category_assignments, @cost_code_assignments)
          if count && count > 0
            Dashboard.scan_log_msg("Parse log saved (#{count} entities)")
            if progress_dlg
              progress_dlg.execute_script("if(typeof scanMsg==='function')scanMsg('Parse log saved (debug)')") rescue nil
            end
          end
        rescue => log_err
          puts "Takeoff: ParseLogger error: #{log_err.message}"
          Dashboard.scan_log_msg("Parse log error: #{log_err.message}")
        end
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
        # Clear stale category_scan derived parts — fresh scan = fresh measurements
        begin
          require 'json'
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          if dp_json && !dp_json.empty?
            parts = JSON.parse(dp_json)
            stale = parts.keys.select { |k| (parts[k]['sourceType'] rescue nil) == 'category_scan' }
            if stale.any?
              stale.each { |k| parts.delete(k) }
              m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
              puts "Takeoff: Cleared #{stale.length} stale category_scan measurements (rescan)"
            end
          end
        rescue => cse
          puts "Takeoff: clear stale derived_parts error: #{cse.message}"
        end
        trigger_backup

        # Run interactive scanner for low-confidence items
        begin
          is_summary = InteractiveScanner.analyze(@scan_results, @category_assignments)
          if is_summary[:low_confidence_groups] > 0
            Dashboard.send_scanner_banner(is_summary)
            Dashboard.scan_log_msg("Scanner: #{is_summary[:low_confidence_groups]} groups need classification")
          end
          if is_summary[:flagged] > 0
            Dashboard.scan_log_msg("#{is_summary[:flagged]} items flagged for review")
          end
        rescue => is_err
          puts "Takeoff: InteractiveScanner error: #{is_err.message}"
        end

        # Report new entities from template comparison
        if defined?(CategoryTemplates) && (@template_new_entities || 0) > 0
          new_ents = CategoryTemplates.new_entities
          # Build summary by scanner-assigned category
          by_cat = {}
          new_ents.each do |ne|
            cat = ne[:scanner_category] || 'Uncategorized'
            by_cat[cat] ||= []
            by_cat[cat] << ne[:display_name]
          end
          lines = ["#{new_ents.length} NEW entities not in template:"]
          by_cat.sort_by { |_k, v| -v.length }.each do |cat, names|
            unique = names.uniq.length
            lines << "  #{cat}: #{names.length} (#{unique} types)"
          end
          Dashboard.scan_log_msg(lines.join("\n"))
          @pending_new_entities_banner = { count: new_ents.length, by_cat: by_cat }
        end

        open_dashboard
        # Send new entities banner after dashboard is fully loaded
        if @pending_new_entities_banner
          banner = @pending_new_entities_banner
          @pending_new_entities_banner = nil
          UI.start_timer(1.0, false) do
            Dashboard.send_new_entities_banner(banner[:count], banner[:by_cat])
          end
        end
      end
    rescue => e
      Dashboard.scan_log_end("ERROR: #{e.message}")
      puts "Takeoff run_scan error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      UI.messagebox("Scan error: #{e.message}")
    end
  end

  def self.open_dashboard
    if @scan_results.empty?
      unless load_scan_from_model
        r = UI.messagebox("No scan data. Run scan first?", MB_YESNO)
        return r == IDYES ? run_scan : nil
      end
      Scanner.recalculate_sf rescue nil
    end

    # Ensure containers are loaded (may have been reset by code reload)
    if (@master_containers || []).empty?
      load_master_containers
      puts "[FF Dashboard] Loaded #{(@master_containers || []).length} containers on dashboard open"
    end

    # Ensure multiverse data is loaded (may have been reset by code reload)
    if !@multiverse_data
      load_multiverse_data rescue nil
    end

    # Check staleness (exclude CAD overlays from count)
    m = Sketchup.active_model
    if m
      saved_defs = m.get_attribute('FormAndField', 'def_count') || 0
      current_defs = scannable_def_count(m)
      if saved_defs > 0 && (current_defs - saved_defs).abs > [saved_defs * 0.1, 5].max
        r = UI.messagebox("Model appears to have changed since last scan.\nRescan now?", MB_YESNO)
        return run_scan if r == IDYES
      end
    end

    puts "[FF Dashboard] Opening: #{@scan_results.length} results, mv=#{active_mv_view || 'none'}"
    Dashboard.show(@scan_results, @category_assignments, @cost_code_assignments)
  end
end
