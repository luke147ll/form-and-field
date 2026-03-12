module TakeoffTool
  BASE_CATEGORIES = [
    'Drywall','Wall Framing','Walls','Wall Finish','Wall Structure','Wall Sheathing',
    'Masonry / Veneer','Siding','Exterior Finish','Soffit','Stucco','Decorative Metal',
    'Glass/Glazing','Wood Paneling',
    'Metal Roofing','Shingle Roofing','Roofing','Roof Framing','Roof Sheathing',
    'Concrete','Flooring','Ceilings','Ceiling Framing','Structural Lumber','Structural Steel','Timber Frame',
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
  ].freeze unless defined?(BASE_CATEGORIES)

  # Build a dynamic category list — delegates to master_categories (canonical source)
  def self.build_context_categories
    master_categories
  end

  def self.apply_category_to_selection(entities, category)
    count = 0
    first_old_cat = nil
    entities.each do |e|
      next unless e.respond_to?(:set_attribute) && e.respond_to?(:entityID)
      eid = e.entityID
      begin
        old_cat = e.get_attribute('TakeoffAssignments', 'category') rescue nil
        first_old_cat ||= old_cat || 'Uncategorized'
        e.set_attribute('TakeoffAssignments', 'category', category)
        e.set_attribute('TakeoffAssignments', 'subcategory', '')
        @category_assignments[eid] = category
        RecatLog.log_change(eid, category)
        @entity_registry[eid] = e unless @entity_registry.key?(eid)
        # Clear subcategory in scan results
        if @scan_results
          @scan_results.each do |r|
            if r[:entity_id] == eid
              r[:parsed][:auto_subcategory] = ''
              break
            end
          end
        end
        count += 1
      rescue => err
        puts "Takeoff: context menu error eid=#{eid}: #{err.message}"
      end
    end
    puts "Takeoff: Set #{count} entities to category '#{category}'"

    # Learning system: capture from first entity
    if entities.length > 0 && first_old_cat
      begin
        LearningSystem.capture(entities.first.entityID, first_old_cat, category)
      rescue => le
        puts "Context menu learning capture error: #{le.message}"
      end
    end

    # Refresh dashboard if open
    if Dashboard.visible?
      Dashboard.send_data(filtered_scan_results, @category_assignments, @cost_code_assignments)
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

        # Create Assembly from selection
        sub.add_item('Create Assembly') do
          entities = sel.to_a.select { |e| e.respond_to?(:entityID) }
          if entities.empty?
            UI.messagebox("No valid entities selected.")
          else
            adlg = UI::HtmlDialog.new(
              dialog_title: "Create Assembly",
              width: 340, height: 280,
              left: 200, top: 200,
              resizable: true,
              style: UI::HtmlDialog::STYLE_UTILITY
            )
            adlg.add_action_callback('ok') do |_ctx, json_str|
              adlg.close rescue nil
              begin
                require 'json'
                data = JSON.parse(json_str.to_s)
                name = data['name'].to_s.strip
                notes = data['notes'].to_s
                unless name.empty?
                  ids = entities.map(&:entityID)
                  TakeoffTool.create_assembly(name, ids, notes)
                  puts "Takeoff: Created assembly '#{name}' from #{ids.length} selected entities"
                  Dashboard.send_assemblies if Dashboard.visible?
                end
              rescue => e
                puts "Takeoff: Create assembly error: #{e.message}"
              end
            end
            adlg.add_action_callback('cancel') do |_ctx|
              adlg.close rescue nil
            end
            adlg.set_html(<<~HTML
              <!DOCTYPE html><html><head><meta charset="UTF-8">
              <style>#{PICK_DIALOG_CSS}</style></head><body>
              <h1>Create Assembly</h1>
              <p style="font-size:11px;color:#a6adc8;margin-bottom:8px">#{entities.length} entities selected</p>
              <label>Name</label>
              <input id="aname" type="text" autofocus>
              <label style="margin-top:6px">Notes (optional)</label>
              <input id="anotes" type="text">
              <div class="buttons">
                <button class="btn btn-cancel" onclick="sketchup.cancel()">Cancel</button>
                <button class="btn btn-ok" onclick="var n=document.getElementById('aname').value.trim();if(n)sketchup.ok(JSON.stringify({name:n,notes:document.getElementById('anotes').value}));">Create</button>
              </div>
              <script>
                document.addEventListener('keydown',function(e){
                  if(e.key==='Enter'){var n=document.getElementById('aname').value.trim();if(n)sketchup.ok(JSON.stringify({name:n,notes:document.getElementById('anotes').value}));}
                  if(e.key==='Escape')sketchup.cancel();
                });
              </script>
              </body></html>
            HTML
            )
            adlg.show
          end
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

        # Set Category submenu — grouped by container, sorted alphabetically
        cat_sub = sub.add_submenu('Set Category')
        containers = TakeoffTool.master_containers || []
        if containers.any?
          containers.each do |cont|
            cats = (cont['categories'] || []).reject { |c| c['name'] == '_IGNORE' }
            next if cats.empty?
            cont_sub = cat_sub.add_submenu(cont['name'])
            cats.sort_by { |c| c['name'].downcase }.each do |cat_entry|
              cont_sub.add_item(cat_entry['name']) do
                TakeoffTool.apply_category_to_selection(sel.to_a, cat_entry['name'])
              end
            end
          end
        else
          TakeoffTool.build_context_categories.sort_by(&:downcase).each do |cat|
            cat_sub.add_item(cat) do
              TakeoffTool.apply_category_to_selection(sel.to_a, cat)
            end
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
