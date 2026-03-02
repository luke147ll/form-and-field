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
  load File.join(PLUGIN_DIR, 'ifc_parser.rb')
  load File.join(PLUGIN_DIR, 'recat_log.rb')
  load File.join(PLUGIN_DIR, 'hyper_parser.rb')
  load File.join(PLUGIN_DIR, 'bug_reporter.rb')

  @scan_results = []
  @category_assignments = {}
  @cost_code_assignments = {}
  @entity_registry = {}
  @custom_categories = []
  @master_categories = []
  @master_subcategories = {}

  class << self
    attr_accessor :scan_results, :category_assignments, :cost_code_assignments,
                  :entity_registry, :custom_categories, :master_categories,
                  :master_subcategories
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
    sub.add_item('Hyper Parse') { HyperParser.show_dialog }
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
      load_custom_categories
      load_master_categories
      merge_scan_categories_into_master
      load_master_subcategories
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

  # Add a user-created custom category name and persist to model attributes
  def self.add_custom_category(name)
    return if name.nil? || name.strip.empty?
    name = name.strip
    unless @custom_categories.include?(name)
      @custom_categories << name
      save_custom_categories
    end
    add_category(name)
  end

  # Push updated category list to every open dialog
  def self.refresh_all_category_dialogs
    broadcast_category_update
  end

  def self.save_custom_categories
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'custom_categories', JSON.generate(@custom_categories))
  end

  def self.load_custom_categories
    m = Sketchup.active_model
    return unless m
    json = m.get_attribute('FormAndField', 'custom_categories')
    if json && !json.empty?
      require 'json'
      @custom_categories = JSON.parse(json) rescue []
      puts "Takeoff: Loaded #{@custom_categories.length} custom categories" if @custom_categories.length > 0
    end
  end

  # ═══ MASTER CATEGORY API ═══

  # Returns the canonical sorted category list (defensive copy)
  def self.master_categories
    @master_categories.dup
  end

  # Add a category to the master list. No-op if duplicate or empty. Returns boolean.
  def self.add_category(name)
    return false if name.nil? || name.to_s.strip.empty?
    name = name.to_s.strip
    return false if @master_categories.include?(name)
    @master_categories << name
    sort_master_categories!
    save_master_categories
    broadcast_category_update
    true
  end

  # Atomic rename: updates master list, entity attrs, assignments, scan results, measurement types.
  # If new_name already exists, merges (removes old, keeps new, reassigns entities).
  def self.rename_category(old_name, new_name)
    return false if old_name.nil? || new_name.nil?
    old_name = old_name.to_s.strip
    new_name = new_name.to_s.strip
    return false if old_name.empty? || new_name.empty?
    return false if old_name == new_name
    return false if old_name == 'Uncategorized' || old_name == '_IGNORE'

    m = Sketchup.active_model
    return false unless m

    m.start_operation('Rename Category', true)
    begin
      # Update master list
      if @master_categories.include?(new_name)
        # Merge: remove old, keep new
        @master_categories.delete(old_name)
      else
        idx = @master_categories.index(old_name)
        @master_categories[idx] = new_name if idx
      end
      sort_master_categories!

      # Update every entity attribute
      @entity_registry.each do |eid, e|
        next unless e && e.valid?
        begin
          cat = e.get_attribute('TakeoffAssignments', 'category')
          if cat == old_name
            e.set_attribute('TakeoffAssignments', 'category', new_name)
          end
        rescue => err
          puts "Takeoff: rename_category entity error eid=#{eid}: #{err.message}"
        end
      end

      # Update @category_assignments
      @category_assignments.each do |eid, cat|
        @category_assignments[eid] = new_name if cat == old_name
      end

      # Update @scan_results auto_category
      @scan_results.each do |r|
        if r[:parsed] && r[:parsed][:auto_category] == old_name
          r[:parsed][:auto_category] = new_name
        end
      end

      # Update TakeoffMeasurementTypes model attr
      mt_val = m.get_attribute('TakeoffMeasurementTypes', old_name) rescue nil
      if mt_val && !mt_val.to_s.empty?
        m.set_attribute('TakeoffMeasurementTypes', new_name, mt_val)
        m.set_attribute('TakeoffMeasurementTypes', old_name, '')
      end

      # Cascade subcategories key
      if @master_subcategories.key?(old_name)
        old_subs = @master_subcategories.delete(old_name)
        if @master_subcategories.key?(new_name)
          old_subs.each { |s| @master_subcategories[new_name] << s unless @master_subcategories[new_name].include?(s) }
          @master_subcategories[new_name].sort_by!(&:downcase)
        else
          @master_subcategories[new_name] = old_subs
        end
        save_master_subcategories
      end

      save_master_categories
      m.commit_operation
      broadcast_category_update
      puts "Takeoff: Renamed category '#{old_name}' -> '#{new_name}'"
      true
    rescue => e
      m.abort_operation
      puts "Takeoff: rename_category error: #{e.message}"
      false
    end
  end

  # Remove a category: moves all items to Uncategorized, removes from list.
  def self.remove_category(name)
    return false if name.nil?
    name = name.to_s.strip
    return false if name == 'Uncategorized' || name == '_IGNORE'
    return false unless @master_categories.include?(name)

    m = Sketchup.active_model
    return false unless m

    m.start_operation('Remove Category', true)
    begin
      # Move all items in this category to Uncategorized
      @entity_registry.each do |eid, e|
        next unless e && e.valid?
        begin
          cat = e.get_attribute('TakeoffAssignments', 'category')
          if cat == name
            e.set_attribute('TakeoffAssignments', 'category', 'Uncategorized')
          end
        rescue => err
          puts "Takeoff: remove_category entity error eid=#{eid}: #{err.message}"
        end
      end

      @category_assignments.each do |eid, cat|
        @category_assignments[eid] = 'Uncategorized' if cat == name
      end

      @scan_results.each do |r|
        if r[:parsed] && r[:parsed][:auto_category] == name
          r[:parsed][:auto_category] = 'Uncategorized'
        end
      end

      @master_categories.delete(name)
      @master_subcategories.delete(name)
      save_master_categories
      save_master_subcategories
      m.commit_operation
      broadcast_category_update
      puts "Takeoff: Removed category '#{name}' — items moved to Uncategorized"
      true
    rescue => e
      m.abort_operation
      puts "Takeoff: remove_category error: #{e.message}"
      false
    end
  end

  # Persist master categories to model attribute as JSON
  def self.save_master_categories
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'master_categories', JSON.generate(@master_categories))
  end

  # Load master categories from model attribute. On first load, migrates from all sources.
  def self.load_master_categories
    m = Sketchup.active_model
    return unless m
    json = m.get_attribute('FormAndField', 'master_categories')
    if json && !json.empty?
      require 'json'
      @master_categories = JSON.parse(json) rescue []
    else
      # First load — migrate from all existing sources
      cats = BASE_CATEGORIES.dup
      (@custom_categories || []).each { |c| cats << c unless cats.include?(c) }
      @category_assignments.each_value { |c| cats << c unless cats.include?(c) }
      (@scan_results || []).each do |r|
        c = r[:parsed][:auto_category]
        cats << c if c && !cats.include?(c)
      end
      @master_categories = cats
      puts "Takeoff: Migrated #{@master_categories.length} categories to master list"
    end
    # Always ensure Uncategorized + _IGNORE exist
    @master_categories << 'Uncategorized' unless @master_categories.include?('Uncategorized')
    @master_categories << '_IGNORE' unless @master_categories.include?('_IGNORE')
    sort_master_categories!
    save_master_categories
  end

  # Sort with _IGNORE always at the end
  def self.sort_master_categories!
    @master_categories.sort_by! { |c| c == '_IGNORE' ? 'zzz' : c.downcase }
  end

  # Push updated category list to every open dialog
  def self.broadcast_category_update
    if Dashboard.visible?
      Dashboard.send_data(@scan_results, @category_assignments, @cost_code_assignments)
    end
    HyperParser.send_categories if defined?(HyperParser) && HyperParser.respond_to?(:send_categories)
    IdentifyDialog.send_categories if defined?(IdentifyDialog) && IdentifyDialog.respond_to?(:send_categories)
  end

  # Add any scan-discovered categories not already in master list
  def self.merge_scan_categories_into_master
    changed = false
    (@scan_results || []).each do |r|
      c = r[:parsed][:auto_category]
      if c && !c.empty? && !@master_categories.include?(c)
        @master_categories << c
        changed = true
      end
    end
    @category_assignments.each_value do |c|
      if c && !c.empty? && !@master_categories.include?(c)
        @master_categories << c
        changed = true
      end
    end
    if changed
      sort_master_categories!
      save_master_categories
      puts "Takeoff: Merged new categories into master list (#{@master_categories.length} total)"
    end
  end

  # ─── Master Subcategories API ───

  # Deep-copy of full hash
  def self.master_subcategories
    h = {}
    @master_subcategories.each { |k, v| h[k] = v.dup }
    h
  end

  # Array of subcategories for one category
  def self.master_subcategories_for(cat)
    (@master_subcategories[cat] || []).dup
  end

  # Add a subcategory under a category. Returns true if added.
  def self.add_subcategory(cat, name)
    return false if cat.nil? || name.nil?
    cat = cat.to_s.strip
    name = name.to_s.strip
    return false if cat.empty? || name.empty?

    @master_subcategories[cat] ||= []
    return false if @master_subcategories[cat].include?(name)

    @master_subcategories[cat] << name
    @master_subcategories[cat].sort_by!(&:downcase)
    save_master_subcategories
    broadcast_category_update
    puts "Takeoff: Added subcategory '#{name}' under '#{cat}'"
    true
  end

  # Rename a subcategory. Atomic: updates master list + entity attrs + scan_results.
  def self.rename_subcategory(cat, old_name, new_name)
    return false if cat.nil? || old_name.nil? || new_name.nil?
    cat = cat.to_s.strip
    old_name = old_name.to_s.strip
    new_name = new_name.to_s.strip
    return false if cat.empty? || old_name.empty? || new_name.empty?
    return false if old_name == new_name
    return false unless @master_subcategories[cat]&.include?(old_name)

    m = Sketchup.active_model
    return false unless m

    m.start_operation('Rename Subcategory', true)
    begin
      subs = @master_subcategories[cat]
      if subs.include?(new_name)
        # Merge: just remove old
        subs.delete(old_name)
      else
        idx = subs.index(old_name)
        subs[idx] = new_name if idx
        subs.sort_by!(&:downcase)
      end

      # Update entity attributes
      @entity_registry.each do |eid, e|
        next unless e && e.valid?
        begin
          ecat = e.get_attribute('TakeoffAssignments', 'category')
          esub = e.get_attribute('TakeoffAssignments', 'subcategory')
          if ecat == cat && esub == old_name
            e.set_attribute('TakeoffAssignments', 'subcategory', new_name)
          end
        rescue => err
          puts "Takeoff: rename_subcategory entity error eid=#{eid}: #{err.message}"
        end
      end

      # Update scan_results
      @scan_results.each do |r|
        if r[:parsed] && r[:parsed][:auto_category] == cat && r[:parsed][:auto_subcategory] == old_name
          r[:parsed][:auto_subcategory] = new_name
        end
      end

      save_master_subcategories
      m.commit_operation
      broadcast_category_update
      puts "Takeoff: Renamed subcategory '#{old_name}' -> '#{new_name}' under '#{cat}'"
      true
    rescue => e
      m.abort_operation
      puts "Takeoff: rename_subcategory error: #{e.message}"
      false
    end
  end

  # Remove a subcategory. Clears subcategory to '' on affected entities.
  def self.remove_subcategory(cat, name)
    return false if cat.nil? || name.nil?
    cat = cat.to_s.strip
    name = name.to_s.strip
    return false if cat.empty? || name.empty?
    return false unless @master_subcategories[cat]&.include?(name)

    m = Sketchup.active_model
    return false unless m

    m.start_operation('Remove Subcategory', true)
    begin
      @master_subcategories[cat].delete(name)

      # Clear subcategory on affected entities
      @entity_registry.each do |eid, e|
        next unless e && e.valid?
        begin
          ecat = e.get_attribute('TakeoffAssignments', 'category')
          esub = e.get_attribute('TakeoffAssignments', 'subcategory')
          if ecat == cat && esub == name
            e.set_attribute('TakeoffAssignments', 'subcategory', '')
          end
        rescue => err
          puts "Takeoff: remove_subcategory entity error eid=#{eid}: #{err.message}"
        end
      end

      # Clear in scan_results
      @scan_results.each do |r|
        if r[:parsed] && r[:parsed][:auto_category] == cat && r[:parsed][:auto_subcategory] == name
          r[:parsed][:auto_subcategory] = ''
        end
      end

      save_master_subcategories
      m.commit_operation
      broadcast_category_update
      puts "Takeoff: Removed subcategory '#{name}' from '#{cat}'"
      true
    rescue => e
      m.abort_operation
      puts "Takeoff: remove_subcategory error: #{e.message}"
      false
    end
  end

  # Persist master subcategories to model attribute as JSON
  def self.save_master_subcategories
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'master_subcategories', JSON.generate(@master_subcategories))
  end

  # Load master subcategories from model attribute
  def self.load_master_subcategories
    m = Sketchup.active_model
    return unless m
    json = m.get_attribute('FormAndField', 'master_subcategories')
    if json && !json.empty?
      require 'json'
      @master_subcategories = JSON.parse(json) rescue {}
    else
      @master_subcategories = {}
    end
    merge_scan_subcategories_into_master
  end

  # Discover subcategories from scan_results + entity attrs, group by category
  def self.merge_scan_subcategories_into_master
    changed = false

    # From scan_results
    (@scan_results || []).each do |r|
      cat = r[:parsed][:auto_category]
      sub = r[:parsed][:auto_subcategory]
      next unless cat && !cat.empty? && sub && !sub.empty?
      @master_subcategories[cat] ||= []
      unless @master_subcategories[cat].include?(sub)
        @master_subcategories[cat] << sub
        changed = true
      end
    end

    # From entity attributes
    @entity_registry.each do |eid, e|
      next unless e && e.valid?
      cat = e.get_attribute('TakeoffAssignments', 'category')
      sub = e.get_attribute('TakeoffAssignments', 'subcategory')
      next unless cat && !cat.empty? && sub && !sub.empty?
      @master_subcategories[cat] ||= []
      unless @master_subcategories[cat].include?(sub)
        @master_subcategories[cat] << sub
        changed = true
      end
    end

    if changed
      @master_subcategories.each_value { |arr| arr.sort_by!(&:downcase) }
      save_master_subcategories
      puts "Takeoff: Merged subcategories into master list"
    end
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
    load_custom_categories
    load_master_categories
    merge_scan_categories_into_master
    load_master_subcategories
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
