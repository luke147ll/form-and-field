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

        # Clear measurement highlights on selected entities
        sub.add_item('Clear Highlight') do
          model = Sketchup.active_model
          next unless model
          entities = sel.to_a
          model.start_operation('Clear Selection HL', true)
          count = 0
          entities.each do |e|
            # Faces inside components/groups
            if e.respond_to?(:definition)
              e.definition.entities.grep(Sketchup::Face).each do |face|
                orig_name = face.get_attribute('FF_Original', 'material')
                next unless orig_name
                face.material = orig_name.empty? ? nil : model.materials[orig_name]
                face.delete_attribute('FF_Original', 'material')
                count += 1
              end
            end
            # LF ribbon groups — hide them
            if e.is_a?(Sketchup::Group) && e.get_attribute('TakeoffMeasurement', 'type') == 'LF'
              e.visible = false
              count += 1
            end
            # Directly selected faces
            if e.is_a?(Sketchup::Face)
              orig_name = e.get_attribute('FF_Original', 'material')
              if orig_name
                e.material = orig_name.empty? ? nil : model.materials[orig_name]
                e.delete_attribute('FF_Original', 'material')
                count += 1
              end
            end
          end
          model.commit_operation
          puts "Takeoff: Cleared highlights on #{count} items"
        end

        sub.add_separator

        # Tool toggles
        sub.add_item('Precision Nav') do
          TakeoffTool::PrecisionNav.toggle
        end

        sub.add_item('Drill Bit') do
          TakeoffTool::DrillBit.toggle
        end

        sub.add_item('Report Bug') do
          TakeoffTool::BugReporter.show('new')
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
          entities = sel.to_a
          cdlg = UI::HtmlDialog.new(
            dialog_title: "New Category",
            preferences_key: "TakeoffCustomCat",
            width: 300, height: 160,
            left: 200, top: 200,
            resizable: false,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          cdlg.add_action_callback('ok') do |_ctx, cat_str|
            cdlg.close rescue nil
            cat = cat_str.to_s.strip
            TakeoffTool.apply_category_to_selection(entities, cat) unless cat.empty?
          end
          cdlg.add_action_callback('cancel') do |_ctx|
            cdlg.close rescue nil
          end
          cdlg.set_html(<<~HTML
            <!DOCTYPE html><html><head><meta charset="UTF-8">
            <style>#{PICK_DIALOG_CSS}</style></head><body>
            <h1>New Category</h1>
            <label>Category Name</label>
            <input id="cat" type="text" autofocus>
            <div class="buttons">
              <button class="btn btn-cancel" onclick="sketchup.cancel()">Cancel</button>
              <button class="btn btn-ok" onclick="var v=document.getElementById('cat').value.trim();if(v)sketchup.ok(v);">OK</button>
            </div>
            <script>
              document.addEventListener('keydown',function(e){
                if(e.key==='Enter'){var v=document.getElementById('cat').value.trim();if(v)sketchup.ok(v);}
                if(e.key==='Escape')sketchup.cancel();
              });
            </script>
            </body></html>
          HTML
          )
          cdlg.show
        end
      end
    end
    @context_menu_loaded = true
  end
end
