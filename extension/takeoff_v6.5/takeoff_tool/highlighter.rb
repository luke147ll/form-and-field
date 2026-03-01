module TakeoffTool
  module Highlighter
    COLORS = {
      'Drywall'=>[255,240,140],'Wall Framing'=>[255,180,100],'Walls'=>[240,200,160],
      'Wall Finish'=>[240,220,160],'Wall Structure'=>[220,170,120],'Wall Sheathing'=>[230,210,160],
      'Masonry / Veneer'=>[210,180,140],'Siding'=>[140,200,140],'Exterior Finish'=>[120,190,120],
      'Metal Roofing'=>[140,180,220],'Shingle Roofing'=>[160,140,180],'Roofing'=>[150,170,210],
      'Roof Framing'=>[200,150,100],'Roof Sheathing'=>[230,200,150],
      'Concrete'=>[170,170,170],'Flooring'=>[190,180,150],
      'Structural Lumber'=>[220,160,80],'Insulation'=>[255,180,220],'Membrane'=>[200,200,255],
      'Windows'=>[100,180,255],'Doors'=>[160,120,80],
      'Casework'=>[180,200,140],'Countertops'=>[200,180,160],
      'Ceilings'=>[160,200,230],'Plumbing'=>[100,200,200],
      'Hardware'=>[200,200,200],'Trim'=>[180,140,200],'Fascia'=>[180,160,200],
      'Soffit'=>[200,180,220],'Generic Models'=>[200,200,160],'Uncategorized'=>[255,100,100],
    }
    @orig_instance = {}   # entityID => original instance material
    @orig_faces = {}      # entityID => array of [face, original_material]
    @mats = {}

    def self.highlight_all(sr, ca)
      m = Sketchup.active_model
      return puts("HL: No model") unless m
      clear_all

      puts "HL: highlight_all called with #{sr.length} scan results"
      puts "HL: entity_registry has #{TakeoffTool.entity_registry.length} entries"

      m.start_operation('Highlight All', true)
      found = 0; colored = 0; missed = 0

      sr.each do |r|
        eid = r[:entity_id]
        e = TakeoffTool.find_entity(eid)

        unless e
          missed += 1
          puts "HL: MISS eid=#{eid} name=#{r[:display_name]}" if missed <= 5
          next
        end

        unless e.valid?
          missed += 1
          puts "HL: INVALID eid=#{eid}" if missed <= 5
          next
        end

        found += 1
        cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
        next if cat == '_IGNORE'

        mat = gmat(m, cat)
        applied = apply_highlight(e, eid, mat)
        colored += 1 if applied
      end

      m.commit_operation
      puts "HL: Done. found=#{found} colored=#{colored} missed=#{missed}"
    end

    def self.highlight_category(sr, ca, tc)
      m = Sketchup.active_model; return unless m; clear_all
      m.start_operation('Highlight Cat', true); n=0
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat == tc
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        mat = gmat(m, cat)
        apply_highlight(e, r[:entity_id], mat)
        n += 1
      end
      m.commit_operation
      puts "HL: Category '#{tc}' highlighted #{n}"
    end

    def self.highlight_single(eid)
      m = Sketchup.active_model; return unless m
      eid = eid.to_i
      e = TakeoffTool.find_entity(eid)
      puts "HL: single eid=#{eid} found=#{!e.nil?} valid=#{e ? e.valid? : 'n/a'} type=#{e ? e.typename : 'n/a'}"
      return unless e && e.valid?
      m.start_operation('Highlight', true)
      apply_highlight(e, eid, selmat(m))
      m.commit_operation
    end

    def self.highlight_entities(ids)
      m = Sketchup.active_model; return unless m
      puts "HL: entities count=#{ids.length}"
      clear_all
      m.start_operation('Highlight Set', true)
      n = 0
      ids.each do |id|
        e = TakeoffTool.find_entity(id.to_i); next unless e && e.valid?
        apply_highlight(e, id.to_i, selmat(m))
        n += 1
      end
      m.commit_operation
      puts "HL: highlighted #{n} of #{ids.length}"
    end

    def self.clear_all
      m = Sketchup.active_model; return unless m
      m.start_operation('Clear HL', true)

      # Restore instance materials
      @orig_instance.each do |eid, orig_mat|
        e = TakeoffTool.find_entity(eid)
        if e && e.valid?
          begin; e.material = orig_mat; rescue; end
        end
      end

      # Restore face materials
      @orig_faces.each do |eid, face_list|
        face_list.each do |face, orig_mat|
          begin
            face.material = orig_mat if face.valid?
          rescue
          end
        end
      end

      # Clean up highlight materials
      @mats.each do |_, mt|
        begin; m.materials.remove(mt) if mt && mt.valid?; rescue; end
      end

      @orig_instance.clear
      @orig_faces.clear
      @mats.clear

      # Also clear persistent measurement highlights (SF face colors + LF ribbons)
      clear_measurement_highlights_inner(m)

      m.commit_operation
    end

    def self.clear_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Clear Measurement HL', true)
      clear_measurement_highlights_inner(m)
      m.commit_operation
    end

    def self.clear_measurement_highlights_inner(m)
      restored = 0

      # Restore SF-colored faces inside all definitions (components/groups)
      m.definitions.each do |defn|
        next if defn.image?
        defn.entities.grep(Sketchup::Face).each do |face|
          orig_name = face.get_attribute('FF_Original', 'material')
          next unless orig_name
          face.material = orig_name.empty? ? nil : m.materials[orig_name]
          face.delete_attribute('FF_Original', 'material')
          restored += 1
        end
      end

      # Restore loose faces in model entities
      m.entities.grep(Sketchup::Face).each do |face|
        orig_name = face.get_attribute('FF_Original', 'material')
        next unless orig_name
        face.material = orig_name.empty? ? nil : m.materials[orig_name]
        face.delete_attribute('FF_Original', 'material')
        restored += 1
      end

      # Hide LF ribbon groups (preserves measurement data)
      hidden = 0
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        if grp.get_attribute('TakeoffMeasurement', 'type') == 'LF' && grp.visible?
          grp.visible = false
          hidden += 1
        end
      end

      # Clean up TO_SF_ and TO_LF_ materials
      m.materials.to_a.each do |mt|
        if mt.display_name =~ /\ATO_(SF|LF)_/
          begin; m.materials.remove(mt); rescue; end
        end
      end

      puts "Takeoff: Cleared measurement highlights (#{restored} faces restored, #{hidden} ribbons hidden)" if restored > 0 || hidden > 0
    end

    # ─── Visibility ───

    def self.isolate_category(sr, ca, tc)
      m = Sketchup.active_model; return unless m
      m.start_operation('Isolate', true)
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        e.visible = (cat == tc)
      end
      m.commit_operation
    end

    def self.isolate_categories(sr, ca, cats)
      m = Sketchup.active_model; return unless m
      cat_set = {}
      cats.each { |c| cat_set[c] = true }
      m.start_operation('Isolate Multi', true)
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        e.visible = !!cat_set[cat]
      end
      m.commit_operation
      puts "HL: Isolated #{cats.length} categories: #{cats.join(', ')}"
    end

    def self.highlight_categories(sr, ca, cats)
      m = Sketchup.active_model; return unless m; clear_all
      cat_set = {}
      cats.each { |c| cat_set[c] = true }
      m.start_operation('Highlight Multi', true); n = 0
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        next unless cat_set[cat]
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        mat = gmat(m, cat)
        apply_highlight(e, r[:entity_id], mat)
        n += 1
      end
      m.commit_operation
      puts "HL: Highlighted #{n} items across #{cats.length} categories"
    end

    def self.isolate_entities(sr, ids)
      m = Sketchup.active_model; return unless m
      id_set = {}
      ids.each { |id| id_set[id] = true }
      m.start_operation('Isolate Entities', true)
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        e.visible = !!id_set[r[:entity_id]]
      end
      m.commit_operation
      puts "HL: Isolated #{ids.length} entities"
    end

    def self.hide_categories(sr, ca, cats)
      m = Sketchup.active_model; return unless m
      cat_set = {}
      cats.each { |c| cat_set[c] = true }
      m.start_operation('Hide Categories', true)
      n = 0
      sr.each do |r|
        e = TakeoffTool.find_entity(r[:entity_id]); next unless e && e.valid?
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
        if cat_set[cat]
          e.visible = false
          n += 1
        end
      end
      m.commit_operation
      puts "HL: Hid #{n} items across #{cats.length} categories"
    end

    def self.isolate_tag(tn)
      m = Sketchup.active_model; return unless m
      m.start_operation('Isolate Tag', true)
      m.layers.each { |l| l.visible = (l.name == tn || l.name == 'Layer0' || l.name == 'Untagged') }
      m.commit_operation
    end

    def self.show_all
      m = Sketchup.active_model; return unless m
      m.start_operation('Show All', true)
      TakeoffTool.entity_registry.each { |_, e| e.visible = true if e && e.valid? }
      m.layers.each { |l| l.visible = true }
      m.commit_operation
    end

    private

    # Apply highlight to an entity. Sets instance-level material.
    # Only paints faces if the definition is used by a single instance,
    # to avoid corrupting shared component definitions.
    def self.apply_highlight(entity, eid, mat)
      # Save and set instance-level material
      @orig_instance[eid] = entity.material
      entity.material = mat

      # Only paint faces inside the definition if it's NOT shared
      # (shared definitions = multiple instances using same geometry)
      defn = nil
      if entity.respond_to?(:definition)
        defn = entity.definition
      elsif entity.is_a?(Sketchup::Group)
        defn = entity.entities.parent
      end

      if defn && defn.respond_to?(:entities) && defn.respond_to?(:instances)
        # Only paint faces if this definition has 1 instance
        if defn.instances.length <= 1
          face_list = []
          defn.entities.grep(Sketchup::Face).each do |face|
            face_list << [face, face.material]
            face.material = mat
          end
          @orig_faces[eid] = face_list if face_list.length > 0
        end
      end

      true
    rescue => e
      puts "HL: apply error eid=#{eid}: #{e.message}"
      false
    end

    def self.gmat(m, cat)
      k = "TO_#{cat.gsub(/[^a-zA-Z0-9]/, '_')}"
      mt = @mats[k]
      unless mt
        c = COLORS[cat] || COLORS['Uncategorized']
        mt = m.materials.add(k)
        mt.color = Sketchup::Color.new(*c)
        mt.alpha = 0.85
        @mats[k] = mt
      end
      mt
    end

    def self.selmat(m)
      mt = @mats['TO_sel']
      unless mt
        mt = m.materials.add('TO_sel')
        mt.color = Sketchup::Color.new(255, 255, 0)
        mt.alpha = 0.9
        @mats['TO_sel'] = mt
      end
      mt
    end
  end
end
