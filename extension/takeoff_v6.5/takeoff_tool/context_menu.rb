module TakeoffTool
  BASE_CATEGORIES = [
    'Drywall','Wall Framing','Walls','Wall Finish','Wall Structure','Wall Sheathing',
    'Masonry / Veneer','Siding','Exterior Finish','Soffit','Stucco','Decorative Metal',
    'Glass/Glazing','Wood Paneling',
    'Metal Roofing','Shingle Roofing','Roofing','Roof Framing','Roof Sheathing',
    'Concrete','Flooring','Ceilings','Ceiling Framing','Structural Lumber','Structural Steel',
    'Insulation','Membrane',
    'Foundation Slabs','Foundation Walls','Foundation Footings',
    'Windows','Doors','Garage Doors','Shower Doors','Casework','Countertops','Plumbing',
    'Hardware','Trim','Fascia','Gutters','Flashing','Baseboard',
    'Crown Mold','Casing','Railing','Drip Edge',
    'Tile','Backsplash','Shower Walls','Sheathing',
    'Appliances','Bath Accessories','Outdoor Kitchen','Chimney',
    'HVAC','Snow Guards','Lighting Fixtures','Window Treatments','Outdoor Features',
    'Furniture','Railings','Stairs','Specialty Equipment',
    'Electrical Equipment','Electrical Fixtures','Rooms',
    'Generic Models','Uncategorized','_IGNORE'
  ].freeze

  # Build a dynamic category list: base + custom from assignments + auto-parsed from scan
  def self.build_context_categories
    cats = BASE_CATEGORIES.dup
    @category_assignments.each_value do |c|
      cats << c unless cats.include?(c)
    end
    @scan_results.each do |r|
      c = r[:parsed][:auto_category]
      cats << c if c && !cats.include?(c)
    end
    cats.sort_by { |c| c == '_IGNORE' ? 'zzz' : c.downcase }
  end

  def self.apply_category_to_selection(entities, category)
    count = 0
    entities.each do |e|
      next unless e.respond_to?(:set_attribute) && e.respond_to?(:entityID)
      eid = e.entityID
      begin
        e.set_attribute('TakeoffAssignments', 'category', category)
        @category_assignments[eid] = category
        @entity_registry[eid] = e unless @entity_registry.key?(eid)
        count += 1
      rescue => err
        puts "Takeoff: context menu error eid=#{eid}: #{err.message}"
      end
    end
    puts "Takeoff: Set #{count} entities to category '#{category}'"

    # Refresh dashboard if open
    if Dashboard.visible?
      Dashboard.send_data(@scan_results, @category_assignments, @cost_code_assignments)
    end
  end

  unless @context_menu_loaded
    UI.add_context_menu_handler do |menu|
      sel = Sketchup.active_model&.selection
      if sel && !sel.empty?
        sub = menu.add_submenu('Form and Field')

        # Identify popup
        sub.add_item('Identify') do
          TakeoffTool::IdentifyDialog.show(sel)
        end

        # Zoom to Selection
        sub.add_item('Zoom to Selection') do
          Sketchup.send_action("viewZoomToSelection")
        end

        sub.add_separator

        # Set Category submenu with dynamic categories
        cat_sub = sub.add_submenu('Set Category')
        TakeoffTool.build_context_categories.each do |cat|
          cat_sub.add_item(cat) do
            TakeoffTool.apply_category_to_selection(sel.to_a, cat)
          end
        end
        cat_sub.add_separator
        cat_sub.add_item('Custom...') do
          result = UI.inputbox(['Category Name:'], [''], 'Custom Category')
          if result && result[0] && !result[0].strip.empty?
            TakeoffTool.apply_category_to_selection(sel.to_a, result[0].strip)
          end
        end
      end
    end
    @context_menu_loaded = true
  end
end
