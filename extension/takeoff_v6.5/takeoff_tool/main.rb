module TakeoffTool

  require File.join(PLUGIN_DIR, 'scanner')
  require File.join(PLUGIN_DIR, 'parser')
  require File.join(PLUGIN_DIR, 'dashboard')
  require File.join(PLUGIN_DIR, 'exporter')
  require File.join(PLUGIN_DIR, 'highlighter')
  require File.join(PLUGIN_DIR, 'measure_lf')
  require File.join(PLUGIN_DIR, 'measure_sf')

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

  # Selection observer: click in model → highlight in dashboard
  class SelObs < Sketchup::SelectionObserver
    def onSelectionBulkChange(sel); check(sel); end
    def onSelectionAdded(sel, e); check(sel); end
    def check(sel)
      return if sel.empty?
      eid = sel.first.entityID
      Dashboard.scroll_to_entity(eid) if TakeoffTool.entity_registry[eid]
    end
  end

  @observer = nil
  def self.attach_observer
    return if @observer
    m = Sketchup.active_model; return unless m
    @observer = SelObs.new
    m.selection.add_observer(@observer)
  end

  def self.detach_observer
    return unless @observer
    m = Sketchup.active_model
    if m
      begin; m.selection.remove_observer(@observer); rescue; end
    end
    @observer = nil
  end

  unless @menu_loaded
    sub = UI.menu('Extensions').add_submenu(PLUGIN_NAME)
    sub.add_item('Scan Model') { TakeoffTool.run_scan }
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

  def self.run_scan
    m = Sketchup.active_model
    return UI.messagebox("No model open.") unless m
    @scan_results, @entity_registry = Scanner.scan_model(m)
    # Load saved category/cost code assignments from model attributes
    load_saved_assignments
    # Also load any manual measurements saved in the model
    load_manual_measurements
    if @scan_results.empty?
      UI.messagebox("No components found.")
    else
      saved = @category_assignments.length + @cost_code_assignments.length
      cats = @scan_results.map{|r| r[:parsed][:auto_category]}.compact.uniq.reject{|c| c=='_IGNORE'}.length
      msg = "Scan complete!\n#{@scan_results.length} elements found\n#{@scan_results.map{|r|r[:display_name]}.uniq.length} unique types\n#{cats} categories detected"
      msg += "\n#{saved} saved assignments loaded" if saved > 0
      UI.messagebox(msg)
      open_dashboard
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
    attach_observer
    Dashboard.show(@scan_results, @category_assignments, @cost_code_assignments)
  end
end
