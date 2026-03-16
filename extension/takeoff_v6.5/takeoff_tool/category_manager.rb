module TakeoffTool

  # ═══ CUSTOM CATEGORIES ═══

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
  # Also auto-assigns to a container by keyword matching if possible.
  def self.add_category(name)
    return false if name.nil? || name.to_s.strip.empty?
    name = name.to_s.strip
    return false if @master_categories.include?(name)
    @master_categories << name
    sort_master_categories!
    save_master_categories
    assign_categories_to_containers([name])
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

      # Cascade container assignment — rename the category inside its container
      (@master_containers || []).each do |cont|
        (cont['categories'] || []).each do |c|
          if c['name'] == old_name
            c['name'] = new_name
            break
          end
        end
      end
      save_master_containers
      invalidate_container_lookup

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

  # Load master categories from model attribute. On first load, builds from actual scan data only.
  def self.load_master_categories
    m = Sketchup.active_model
    return unless m
    json = m.get_attribute('FormAndField', 'master_categories')
    if json && !json.empty?
      require 'json'
      @master_categories = JSON.parse(json) rescue []
    else
      # First load — only include categories with actual entities + user-created
      cats = []
      (@custom_categories || []).each { |c| cats << c unless cats.include?(c) }
      @category_assignments.each_value { |c| cats << c unless cats.include?(c) }
      (@scan_results || []).each do |r|
        c = r[:parsed][:auto_category]
        cats << c if c && !cats.include?(c)
      end
      @master_categories = cats
      puts "Takeoff: Built master list from scan data (#{@master_categories.length} categories)"
    end
    # Always ensure Uncategorized + _IGNORE exist
    @master_categories << 'Uncategorized' unless @master_categories.include?('Uncategorized')
    @master_categories << '_IGNORE' unless @master_categories.include?('_IGNORE')
    sort_master_categories!
    save_master_categories
  end

  # ── Master Containers ──

  def self.load_master_containers
    m = Sketchup.active_model
    return unless m
    json = m.get_attribute('FormAndField', 'master_containers')
    if json && !json.empty?
      require 'json'
      @master_containers = JSON.parse(json) rescue []
    else
      # First load — try default template, then fall back to JSON seed file
      require 'json'
      if defined?(CategoryTemplates) && CategoryTemplates.auto_apply_default
        # Default template was applied — containers already set
      else
        path = File.join(PLUGIN_DIR, 'data', 'master_containers.json')
        if File.exist?(path)
          data = JSON.parse(File.read(path)) rescue {}
          @master_containers = data['containers'] || []
        else
          @master_containers = []
        end
        save_master_containers
        puts "Takeoff: Loaded master containers from JSON file (#{@master_containers.length} containers)"
      end
    end
    build_container_lookup
  end

  def self.save_master_containers
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'master_containers', JSON.generate(@master_containers))
  end

  # Keyword→container map: [keyword, container_name], sorted longest first
  CONTAINER_KEYWORDS = [
    ["plumbing fixture","MEP"],["lighting fixture","MEP"],
    ["ceiling framing","Structure"],["roof framing","Structure"],["wall framing","Structure"],
    ["floor framing","Structure"],["floor truss","Structure"],["roof truss","Structure"],
    ["roof sheath","Structure"],["wall sheath","Structure"],["floor sheath","Structure"],
    ["stud pack","Structure"],["wide flange","Structure"],["w beam","Structure"],
    ["grade beam","Foundation"],["stem wall","Foundation"],
    ["exterior door","Full Enclosure"],["garage door","Full Enclosure"],
    ["glass door","Full Enclosure"],["interior door","Finish"],["int door","Finish"],
    ["exterior trim","Full Enclosure"],["interior trim","Finish"],
    ["wall finish","Full Enclosure"],["floor finish","Finish"],
    ["wood panel","Full Enclosure"],["gyp board","Finish"],
    ["shower glass","Finish"],["tile wall","Finish"],
    ["low voltage","MEP"],["retaining wall","Exterior/Site"],
    ["i-joist","Structure"],
    ["footing","Foundation"],["foundation","Foundation"],["slab","Foundation"],
    ["concrete","Foundation"],["gypcrete","Finish"],["cmu","Foundation"],
    ["pier","Foundation"],["basement","Foundation"],
    ["steel","Structure"],["lumber","Structure"],["timber","Structure"],
    ["framing","Structure"],["truss","Structure"],["sheathing","Structure"],
    ["header","Structure"],["lvl","Structure"],["tji","Structure"],["bci","Structure"],
    ["joist","Structure"],["rafter","Structure"],["beam","Structure"],
    ["column","Structure"],["post","Structure"],["blocking","Structure"],
    ["purlin","Structure"],["ridge","Structure"],["chord","Structure"],
    ["brace","Structure"],["structural","Structure"],["decking","Structure"],["deck","Structure"],
    ["roofing","Full Enclosure"],["siding","Full Enclosure"],["soffit","Full Enclosure"],
    ["fascia","Full Enclosure"],["window","Full Enclosure"],["glazing","Full Enclosure"],
    ["garage","Full Enclosure"],["railing","Full Enclosure"],["guard","Full Enclosure"],
    ["masonry","Full Enclosure"],["stone","Full Enclosure"],["brick","Full Enclosure"],
    ["insulation","Full Enclosure"],["stucco","Full Enclosure"],
    ["gutter","Full Enclosure"],["downspout","Full Enclosure"],
    ["flashing","Full Enclosure"],["paneling","Full Enclosure"],
    ["wrap","Full Enclosure"],["door","Full Enclosure"],
    ["drywall","Finish"],["trim","Finish"],["flooring","Finish"],["floor","Finish"],
    ["tile","Finish"],["cabinet","Finish"],["vanity","Finish"],["vanities","Finish"],
    ["casework","Finish"],["countertop","Finish"],["counter","Finish"],
    ["stair","Finish"],["shelf","Finish"],["shelving","Finish"],
    ["mirror","Finish"],["paint","Finish"],["hardware","Finish"],
    ["millwork","Finish"],["molding","Finish"],["baseboard","Finish"],
    ["crown","Finish"],["ceiling","Finish"],["wainscot","Finish"],
    ["electric","MEP"],["conduit","MEP"],["panel","MEP"],["switch","MEP"],
    ["outlet","MEP"],["receptacle","MEP"],["light","MEP"],["luminaire","MEP"],
    ["plumb","MEP"],["pipe","MEP"],["sink","MEP"],["toilet","MEP"],
    ["faucet","MEP"],["tub","MEP"],["shower","MEP"],["fixture","MEP"],
    ["hvac","MEP"],["mechanical","MEP"],["duct","MEP"],["diffuser","MEP"],
    ["fire","MEP"],["sprinkler","MEP"],
    ["landscape","Exterior/Site"],["paving","Exterior/Site"],["asphalt","Exterior/Site"],
    ["retaining","Exterior/Site"],["fence","Exterior/Site"],["fencing","Exterior/Site"],
    ["site","Exterior/Site"],["excavat","Exterior/Site"],["backfill","Exterior/Site"],
    ["patio","Exterior/Site"],
    ["appliance","Specialty"],["washer","Specialty"],["dryer","Specialty"],
    ["refrigerator","Specialty"],["oven","Specialty"],["range","Specialty"],
    ["dishwasher","Specialty"],["furniture","Specialty"],
    ["equipment","Specialty"],["specialty","Specialty"]
  ].freeze

  def self.get_container_for_category(cat)
    build_container_lookup unless @container_lookup
    @container_lookup[cat] || match_container_by_keyword(cat)
  end

  def self.match_container_by_keyword(cat)
    return { 'name' => 'Other', 'color' => '#6c7086', 'order' => 999 } unless cat && !cat.empty?
    return { 'name' => 'Other', 'color' => '#6c7086', 'order' => 999 } if cat == 'Uncategorized'
    low = cat.downcase
    CONTAINER_KEYWORDS.each do |kw, cont_name|
      if low.include?(kw)
        # Find container info from @master_containers
        (@master_containers || []).each do |cont|
          if cont['name'] == cont_name
            return { 'name' => cont['name'], 'color' => cont['color'], 'order' => cont['order'] }
          end
        end
        return { 'name' => cont_name, 'color' => '#6c7086', 'order' => 999 }
      end
    end
    { 'name' => 'Other', 'color' => '#6c7086', 'order' => 999 }
  end

  def self.build_container_lookup
    @container_lookup = {}
    (@master_containers || []).each do |cont|
      (cont['categories'] || []).each do |c|
        @container_lookup[c['name']] = { 'name' => cont['name'], 'color' => cont['color'], 'order' => cont['order'] }
      end
    end
  end

  def self.invalidate_container_lookup
    @container_lookup = nil
  end

  # Move a category from one container to another by updating master_containers
  def self.move_category_to_container(cat_name, target_cont_name)
    return false if cat_name.nil? || target_cont_name.nil?
    cat_name = cat_name.to_s.strip
    target_cont_name = target_cont_name.to_s.strip
    return false if cat_name.empty? || target_cont_name.empty?

    m = Sketchup.active_model
    return false unless m

    m.start_operation('Move Category to Container', true)
    begin
      # Find and remove category from its current container
      removed_cat = nil
      (@master_containers || []).each do |cont|
        (cont['categories'] || []).each_with_index do |c, idx|
          if c['name'] == cat_name
            removed_cat = cont['categories'].delete_at(idx)
            break
          end
        end
        break if removed_cat
      end

      # If category wasn't in any container, create a stub entry
      removed_cat ||= { 'name' => cat_name, 'code' => '', 'unit' => '' }

      # Find target container and add the category
      target = (@master_containers || []).find { |cont| cont['name'] == target_cont_name }
      if target
        target['categories'] ||= []
        target['categories'] << removed_cat
      end

      # Save, invalidate cache, refresh dashboard
      save_master_containers
      invalidate_container_lookup
      build_container_lookup
      broadcast_category_update
      m.commit_operation
      puts "Takeoff: moved category '#{cat_name}' to container '#{target_cont_name}'"
      true
    rescue => e
      m.abort_operation
      puts "Takeoff move_category_to_container error: #{e.message}"
      false
    end
  end

  # Add a new container to master_containers
  def self.add_container(name)
    return if name.nil? || name.strip.empty?
    name = name.strip
    # Check if container already exists
    (@master_containers || []).each do |cont|
      return if cont['name'] == name
    end
    palette = %w[#fab387 #a6e3a1 #89b4fa #f5c2e7 #cba6f7 #74c7ec #f9e2af #94e2d5 #f2cdcd #f38ba8]
    color = palette[(@master_containers || []).length % palette.length]
    new_cont = { 'name' => name, 'color' => color, 'order' => (@master_containers || []).length, 'categories' => [] }
    @master_containers ||= []
    @master_containers << new_cont
    save_master_containers
    invalidate_container_lookup
    puts "Takeoff: created container '#{name}'"
  end

  # Add a category to a specific container
  def self.add_category_to_container(cat_name, cont_name)
    return if cat_name.nil? || cont_name.nil?
    cat_name = cat_name.strip
    cont_name = cont_name.strip
    return if cat_name.empty? || cont_name.empty?

    target = (@master_containers || []).find { |c| c['name'] == cont_name }
    return unless target

    # Check for duplicate within this container
    target['categories'] ||= []
    target['categories'].each { |c| return if c['name'] == cat_name }

    target['categories'] << { 'name' => cat_name, 'code' => '', 'unit' => 'EA' }
    save_master_containers
    invalidate_container_lookup
    build_container_lookup

    # Also add to master_categories list so it appears in dropdowns
    add_category(cat_name) unless (@master_categories || []).include?(cat_name)

    puts "Takeoff: added category '#{cat_name}' to container '#{cont_name}'"
  end

  # Sort with _IGNORE always at the end
  def self.sort_master_categories!
    @master_categories.sort_by! { |c| c == '_IGNORE' ? 'zzz' : c.downcase }
  end

  # Push updated category list to every open dialog
  def self.broadcast_category_update
    publish(EVENT_CATEGORIES_CHANGED)
  end

  # Add any scan-discovered categories not already in master list
  def self.merge_scan_categories_into_master
    changed = false
    new_cats = []
    (@scan_results || []).each do |r|
      c = r[:parsed][:auto_category]
      if c && !c.empty? && !@master_categories.include?(c)
        @master_categories << c
        new_cats << c
        changed = true
      end
    end
    @category_assignments.each_value do |c|
      if c && !c.empty? && !@master_categories.include?(c)
        @master_categories << c
        new_cats << c
        changed = true
      end
    end
    if changed
      sort_master_categories!
      save_master_categories
      # Auto-assign new categories to containers by keyword matching
      assign_categories_to_containers(new_cats)
      puts "Takeoff: Merged #{new_cats.length} new categories into master list (#{@master_categories.length} total)"
    end
  end

  # Auto-assign categories to containers using keyword matching.
  # Only assigns categories not already in a container.
  def self.assign_categories_to_containers(cat_names)
    return if cat_names.empty? || (@master_containers || []).empty?
    build_container_lookup unless @container_lookup
    added = 0
    cat_names.each do |cat|
      next if cat == 'Uncategorized' || cat == '_IGNORE'
      next if @container_lookup && @container_lookup[cat]  # already in a container
      match = match_container_by_keyword(cat)
      next unless match && match['name'] != 'Other'
      # Find the container and add the category
      target = (@master_containers || []).find { |c| c['name'] == match['name'] }
      if target
        target['categories'] ||= []
        target['categories'] << { 'name' => cat, 'code' => '', 'unit' => 'EA' }
        added += 1
      end
    end
    if added > 0
      save_master_containers
      invalidate_container_lookup
      build_container_lookup
      puts "Takeoff: Auto-assigned #{added} categories to containers"
    end

    # Fallback: any categories not assigned to a container go to "Other"
    other_cont = (TakeoffTool.master_containers || []).find { |c| c['name'] == 'Other' }
    if other_cont
      in_cont = Set.new
      (TakeoffTool.master_containers || []).each do |cont|
        (cont['categories'] || []).each { |c| in_cont.add(c['name']) }
      end
      fallback_added = 0
      cat_names.each do |name|
        unless in_cont.include?(name)
          other_cont['categories'] ||= []
          unless other_cont['categories'].any? { |c| c['name'] == name }
            other_cont['categories'] << { 'name' => name }
            fallback_added += 1
          end
        end
      end
      if fallback_added > 0
        save_master_containers
        puts "Takeoff: #{fallback_added} orphan categories assigned to 'Other'"
      end
    end
  end

  # Remove categories with 0 entities unless user-created (custom) or essential
  def self.prune_empty_categories
    # Collect all categories that have at least one entity
    in_use = {}
    (@scan_results || []).each do |r|
      eid = r[:entity_id]
      cat = @category_assignments[eid] || r[:parsed][:auto_category]
      in_use[cat] = true if cat && !cat.empty?
    end

    # Keep: in-use, user-created, in-container, Uncategorized, _IGNORE
    keep = {}
    in_use.each_key { |c| keep[c] = true }
    (@custom_categories || []).each { |c| keep[c] = true }
    (@master_containers || []).each do |cont|
      (cont['categories'] || []).each { |c| keep[c['name']] = true }
    end
    keep['Uncategorized'] = true
    keep['_IGNORE'] = true

    before = @master_categories.length
    @master_categories.reject! { |c| !keep[c] }
    removed = before - @master_categories.length
    if removed > 0
      sort_master_categories!
      save_master_categories
      puts "Takeoff: Pruned #{removed} empty categories (#{@master_categories.length} remaining)"
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

  # Move a subcategory from one category to another.
  # All entities in that subcategory get their category reassigned.
  def self.move_subcategory(source_cat, sub_name, target_cat)
    return false if source_cat.nil? || sub_name.nil? || target_cat.nil?
    source_cat = source_cat.to_s.strip
    sub_name = sub_name.to_s.strip
    target_cat = target_cat.to_s.strip
    return false if source_cat.empty? || sub_name.empty? || target_cat.empty?
    return false if source_cat == target_cat

    m = Sketchup.active_model
    return false unless m

    m.start_operation('Move Subcategory', true)
    begin
      moved_count = 0

      # Iterate scan_results — the authoritative data source.
      # Must use the SAME category/subcategory resolution as send_data:
      #   category:    @category_assignments[eid] || auto_category
      #   subcategory: entity attr 'subcategory'  || auto_subcategory
      (@scan_results || []).each do |r|
        eid = r[:entity_id]
        eff_cat = @category_assignments[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless eff_cat == source_cat

        e = find_entity(eid)
        eff_sub = (e&.get_attribute('TakeoffAssignments', 'subcategory') rescue nil) || r[:parsed][:auto_subcategory] || ''
        next unless eff_sub == sub_name

        # Update in-memory category assignment
        @category_assignments[eid] = target_cat

        # Persist to entity attributes
        if e && e.valid?
          e.set_attribute('TakeoffAssignments', 'category', target_cat)
        end

        moved_count += 1
      end

      # Update master subcategories lists
      if @master_subcategories[source_cat]
        @master_subcategories[source_cat].delete(sub_name)
      end
      @master_subcategories[target_cat] ||= []
      unless @master_subcategories[target_cat].include?(sub_name)
        @master_subcategories[target_cat] << sub_name
        @master_subcategories[target_cat].sort_by!(&:downcase)
      end

      save_master_subcategories
      m.commit_operation
      broadcast_category_update
      puts "Takeoff: Moved subcategory '#{sub_name}' (#{moved_count} items) from '#{source_cat}' to '#{target_cat}'"
      true
    rescue => e
      m.abort_operation
      puts "Takeoff: move_subcategory error: #{e.message}"
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

  # ─── User Cost Codes API ───

  def self.load_user_cost_codes
    m = Sketchup.active_model
    return nil unless m
    json = m.get_attribute('FormAndField', 'user_cost_codes')
    return nil unless json && !json.empty?
    require 'json'
    JSON.parse(json) rescue nil
  end

  def self.save_user_cost_codes(codes)
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'user_cost_codes', JSON.generate(codes))
  end

  def self.effective_cost_codes
    # User codes override bundled defaults
    user = load_user_cost_codes
    return user if user && user['codes'] && user['codes'].any?
    # Fall back to bundled
    require 'json'
    path = File.join(PLUGIN_DIR, 'config', 'cost_codes.json')
    return { 'codes' => [], 'category_to_cost_code' => {} } unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue => e
    puts "FF: Error loading cost codes: #{e.message}"
    { 'codes' => [], 'category_to_cost_code' => {} }
  end

  def self.add_cost_code(code, description)
    data = load_user_cost_codes || effective_cost_codes.dup
    data['codes'] ||= []
    # Don't add duplicate codes
    return false if data['codes'].any? { |c| c['code'] == code }
    data['codes'] << { 'code' => code, 'description' => description, 'full' => "#{code} #{description}" }
    data['codes'].sort_by! { |c| c['code'] }
    save_user_cost_codes(data)
    publish(EVENT_CATEGORIES_CHANGED)
    true
  end

  def self.remove_cost_code(code)
    data = load_user_cost_codes
    return false unless data && data['codes']
    data['codes'].reject! { |c| c['code'] == code }
    # Also remove from category mappings
    (data['category_to_cost_code'] || {}).each do |_cat, codes|
      codes.delete(code) if codes.is_a?(Array)
    end
    save_user_cost_codes(data)
    publish(EVENT_CATEGORIES_CHANGED)
    true
  end

  def self.set_category_cost_code(category, code)
    data = load_user_cost_codes || effective_cost_codes.dup
    data['category_to_cost_code'] ||= {}
    data['category_to_cost_code'][category] = [code]
    save_user_cost_codes(data)
    # Also update on the container category entry
    (master_containers || []).each do |cont|
      (cont['categories'] || []).each do |c|
        if c['name'] == category
          c['code'] = code
        end
      end
    end
    save_master_containers
    publish(EVENT_CATEGORIES_CHANGED)
    true
  end

  def self.import_cost_codes_from_csv(path)
    require 'csv'
    codes = []
    CSV.foreach(path, headers: true) do |row|
      code = (row['code'] || row['Code'] || row[0]).to_s.strip
      desc = (row['description'] || row['Description'] || row[1]).to_s.strip
      next if code.empty?
      codes << { 'code' => code, 'description' => desc, 'full' => "#{code} #{desc}" }
    end
    return 0 if codes.empty?
    data = load_user_cost_codes || { 'codes' => [], 'category_to_cost_code' => {} }
    existing = Set.new(data['codes'].map { |c| c['code'] })
    added = 0
    codes.each do |c|
      unless existing.include?(c['code'])
        data['codes'] << c
        added += 1
      end
    end
    data['codes'].sort_by! { |c| c['code'] }
    save_user_cost_codes(data)
    publish(EVENT_CATEGORIES_CHANGED)
    puts "FF: Imported #{added} cost codes from CSV (#{codes.length - added} duplicates skipped)"
    added
  end

end
