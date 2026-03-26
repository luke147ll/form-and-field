module TakeoffTool
  module AssemblyAnnotations

    ASSEMBLY_TAG_LAYER   = 'FF_Assembly_Tags' unless defined?(ASSEMBLY_TAG_LAYER)
    ASSEMBLY_TAG_COLOR   = [166, 227, 161] unless defined?(ASSEMBLY_TAG_COLOR)  # Catppuccin green
    ASSEMBLY_TAG_SCALE   = 5.0 unless defined?(ASSEMBLY_TAG_SCALE)
    ASSEMBLY_TEXT_HEIGHT = 1.5 unless defined?(ASSEMBLY_TEXT_HEIGHT)
    ASSEMBLY_MIN_RADIUS  = 2.0 unless defined?(ASSEMBLY_MIN_RADIUS)
    ASSEMBLY_BORDER_W    = 0.15 unless defined?(ASSEMBLY_BORDER_W)
    ASSEMBLY_CIRCLE_SEGS = 32 unless defined?(ASSEMBLY_CIRCLE_SEGS)
    ASSEMBLY_STANDOFF    = 0.1 unless defined?(ASSEMBLY_STANDOFF)

    # ─── Show tags for an assembly ───

    def self.show_tags(asm_id)
      model = Sketchup.active_model
      return unless model

      assemblies = TakeoffTool.load_assemblies
      asm = assemblies[asm_id.to_s]
      return unless asm

      parts = asm['parts'] || []
      return if parts.empty?

      # Clean up any existing tags for this assembly first
      cleanup_tags(asm_id)

      model.start_operation('Show Assembly Tags', true)
      begin
        tag_layer = model.layers[ASSEMBLY_TAG_LAYER] || model.layers.add(ASSEMBLY_TAG_LAYER)
        placed = 0

        parts.each do |part|
          next if part['is_virtual']
          next unless part['entity_id']
          entity = TakeoffTool.find_entity(part['entity_id'].to_i)
          next unless entity && entity.valid?

          place_part_tag(model, tag_layer, entity, part['part_number'], asm_id)
          placed += 1
        end

        model.commit_operation
        puts "[FF AssemblyTags] Placed #{placed} tags for #{asm_id}"
      rescue => e
        model.abort_operation
        puts "[FF AssemblyTags] Error showing tags: #{e.message}"
      end
    end

    # ─── Hide tags for an assembly ───

    def self.hide_tags(asm_id)
      model = Sketchup.active_model
      return unless model
      cleanup_tags(asm_id)
    end

    # ─── Toggle tags ───

    def self.toggle_tags(asm_id)
      visible = (TakeoffTool.asm_tags_visible || {})[asm_id]
      if visible
        hide_tags(asm_id)
      else
        show_tags(asm_id)
      end
      TakeoffTool.asm_tags_visible[asm_id] = !visible
    end

    # ─── Place a single part tag at entity centroid ───

    def self.place_part_tag(model, tag_layer, entity, part_number, asm_id)
      centroid = entity_centroid(entity)
      return unless centroid

      grp = model.active_entities.add_group
      grp.layer = tag_layer
      grp.name = "FF_ASM_TAG: #{asm_id}/#{part_number}"
      grp.set_attribute('FF_AssemblyTag', 'asm_id', asm_id)
      grp.set_attribute('FF_AssemblyTag', 'part_number', part_number)

      # Build circle + text geometry
      build_tag_geometry(grp.entities, model, part_number)

      # Scale for model-scale readability
      scale = Geom::Transformation.scaling(ORIGIN, ASSEMBLY_TAG_SCALE)
      grp.entities.transform_entities(scale, grp.entities.to_a)

      # Center at entity centroid
      tag_bb = Geom::BoundingBox.new
      grp.entities.each { |e| tag_bb.add(e.bounds) }
      cx = (tag_bb.min.x + tag_bb.max.x) / 2.0
      cy = (tag_bb.min.y + tag_bb.max.y) / 2.0
      cz = (tag_bb.min.z + tag_bb.max.z) / 2.0
      offset = Geom::Vector3d.new(
        centroid.x - cx,
        centroid.y - cy,
        centroid.z + ASSEMBLY_STANDOFF - cz
      )
      grp.transform!(Geom::Transformation.new(offset))
    end

    # ─── Tag geometry: green circle with white part number ───

    def self.build_tag_geometry(ents, model, label_text)
      mats = ensure_tag_materials(model)

      ents.add_3d_text(label_text, TextAlignCenter, "Arial", true, false,
                       ASSEMBLY_TEXT_HEIGHT, 0.0, 0.0, true, 0.2)

      text_bb = Geom::BoundingBox.new
      ents.each { |e| text_bb.add(e.bounds) }
      tw = text_bb.max.x - text_bb.min.x
      th = text_bb.max.y - text_bb.min.y
      tcx = (text_bb.min.x + text_bb.max.x) / 2.0
      tcy = (text_bb.min.y + text_bb.max.y) / 2.0

      half_diag = Math.sqrt((tw / 2.0)**2 + (th / 2.0)**2)
      radius = [half_diag + 0.6, ASSEMBLY_MIN_RADIUS].max

      # Border circle (behind)
      border_face = add_tag_circle(ents, tcx, tcy, -0.4, radius + ASSEMBLY_BORDER_W)
      apply_tag_mat(border_face, mats[:border])

      # Fill circle
      fill_face = add_tag_circle(ents, tcx, tcy, -0.2, radius)
      apply_tag_mat(fill_face, mats[:fill])

      # Text faces get dark color
      ents.grep(Sketchup::Face).each do |f|
        next if f == border_face || f == fill_face
        apply_tag_mat(f, mats[:text])
      end
    end

    def self.add_tag_circle(ents, cx, cy, z, radius)
      pts = (0...ASSEMBLY_CIRCLE_SEGS).map do |i|
        angle = 2.0 * Math::PI * i / ASSEMBLY_CIRCLE_SEGS
        Geom::Point3d.new(
          cx + radius * Math.cos(angle),
          cy + radius * Math.sin(angle),
          z
        )
      end
      ents.add_face(pts)
    rescue
      nil
    end

    def self.ensure_tag_materials(model)
      fill = model.materials['FF_AsmTag_Green'] || begin
        m = model.materials.add('FF_AsmTag_Green')
        m.color = Sketchup::Color.new(*ASSEMBLY_TAG_COLOR)
        m.alpha = 0.90
        m
      end

      border = model.materials['FF_AsmTag_Border'] || begin
        m = model.materials.add('FF_AsmTag_Border')
        m.color = Sketchup::Color.new(49, 50, 68)  # surface0
        m
      end

      text = model.materials['FF_AsmTag_Text'] || begin
        m = model.materials.add('FF_AsmTag_Text')
        m.color = Sketchup::Color.new(30, 30, 46)  # base
        m
      end

      { fill: fill, border: border, text: text }
    end

    def self.apply_tag_mat(face, mat)
      return unless face
      face.material = mat
      face.back_material = mat
    end

    # ─── Entity centroid: bounds center + small Z offset ───

    def self.entity_centroid(entity)
      return nil unless entity && entity.valid?
      bb = entity.bounds
      return nil if bb.empty?
      center = bb.center
      # Offset slightly above the top for visibility
      z_top = bb.max.z
      Geom::Point3d.new(center.x, center.y, z_top + 6.0)
    end

    # ─── Cleanup: remove all tag groups for an assembly ───

    def self.cleanup_tags(asm_id)
      model = Sketchup.active_model
      return unless model

      to_erase = []
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute('FF_AssemblyTag', 'asm_id') == asm_id.to_s
        to_erase << grp
      end

      return if to_erase.empty?
      model.start_operation('Remove Assembly Tags', true)
      begin
        to_erase.each { |g| g.erase! if g.valid? }
        model.commit_operation
        puts "[FF AssemblyTags] Cleaned up #{to_erase.length} tags for #{asm_id}"
      rescue => e
        model.abort_operation
        puts "[FF AssemblyTags] Cleanup error: #{e.message}"
      end
    end

    # ─── Auto Tag: rectangular callout tags ───
    # Exact same pattern as show_tags / place_part_tag (which works),
    # with self-contained rect geometry (no build_rect_label dependency)

    AUTO_TAG_LAYER   = 'FF_Auto_Tags' unless defined?(AUTO_TAG_LAYER)
    AUTO_TAG_PAD_X   = 1.0 unless defined?(AUTO_TAG_PAD_X)
    AUTO_TAG_PAD_Y   = 0.5 unless defined?(AUTO_TAG_PAD_Y)

    def self.place_auto_tags(asm_id, prefix = '', color_hex = '#f9e2af')
      model = Sketchup.active_model
      return unless model

      assemblies = TakeoffTool.load_assemblies
      asm = assemblies[asm_id.to_s]
      return unless asm

      parts = asm['parts'] || []
      return if parts.empty?

      # Clean up any existing auto tags for this assembly first
      cleanup_auto_tags(asm_id)

      # Parse color hex to RGB
      hex = color_hex.to_s.gsub('#', '')
      hex = 'f9e2af' if hex.length < 6
      rgb = [hex[0..1].to_i(16), hex[2..3].to_i(16), hex[4..5].to_i(16)]

      # Resolve entities + centroids, then sort spatially before numbering
      sr_by_eid = {}
      (TakeoffTool.scan_results || []).each { |r| sr_by_eid[r[:entity_id].to_i] = r }

      taggable = []
      parts.each do |part|
        next if part['is_virtual']
        next unless part['entity_id']
        eid = part['entity_id'].to_i
        entity = TakeoffTool.find_entity(eid)
        next unless entity && entity.valid?
        c = entity_centroid(entity)
        next unless c
        sr = sr_by_eid[eid]
        name = part['name'] || (sr ? (sr[:display_name] || sr[:definition_name]) : nil) || 'Unknown'
        cat = part['category'] || (sr ? (sr[:parsed][:auto_category] rescue nil) : nil) || ''
        taggable << { entity: entity, eid: eid, name: name, category: cat, cx: c.x, cy: c.y, cz: c.z }
      end
      return [] if taggable.empty?

      # Sort along dominant axis (greatest spread) for natural ordering
      xs = taggable.map { |t| t[:cx] }
      ys = taggable.map { |t| t[:cy] }
      spread_x = xs.max - xs.min
      spread_y = ys.max - ys.min
      if spread_x >= spread_y
        taggable.sort_by! { |t| [t[:cx], t[:cy]] }
      else
        taggable.sort_by! { |t| [t[:cy], t[:cx]] }
      end

      tag_list = []
      model.start_operation('Auto Tag Assembly', true)
      begin
        tag_layer = model.layers[AUTO_TAG_LAYER] || model.layers.add(AUTO_TAG_LAYER)
        number = 1

        taggable.each do |t|
          label_text = "#{prefix}#{number}"
          place_auto_tag(model, tag_layer, t[:entity], label_text, asm_id, rgb)
          tag_list << { 'label' => label_text, 'name' => t[:name], 'category' => t[:category], 'eid' => t[:eid] }
          number += 1
        end

        model.commit_operation
        puts "[FF AutoTag] Placed #{tag_list.length} tags for #{asm_id}"
      rescue => e
        model.abort_operation
        puts "[FF AutoTag] Error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end
      tag_list
    end

    # ─── Place a single auto tag — mirrors place_part_tag (line 74-103) exactly ───

    def self.place_auto_tag(model, tag_layer, entity, label_text, asm_id, rgb)
      centroid = entity_centroid(entity)
      return unless centroid

      grp = model.active_entities.add_group
      grp.layer = tag_layer
      grp.name = "FF_AUTO_TAG: #{asm_id}/#{label_text}"
      grp.set_attribute('FF_AutoTag', 'asm_id', asm_id)
      grp.set_attribute('FF_AutoTag', 'label', label_text)

      # Build rectangular tag geometry (self-contained, no external deps)
      build_rect_tag(grp.entities, model, label_text, rgb)

      # Scale for model-scale readability (same as place_part_tag line 88-89)
      scale = Geom::Transformation.scaling(ORIGIN, ASSEMBLY_TAG_SCALE)
      grp.entities.transform_entities(scale, grp.entities.to_a)

      # Center at entity centroid (same as place_part_tag lines 92-102)
      tag_bb = Geom::BoundingBox.new
      grp.entities.each { |e| tag_bb.add(e.bounds) }
      cx = (tag_bb.min.x + tag_bb.max.x) / 2.0
      cy = (tag_bb.min.y + tag_bb.max.y) / 2.0
      cz = (tag_bb.min.z + tag_bb.max.z) / 2.0
      offset = Geom::Vector3d.new(
        centroid.x - cx,
        centroid.y - cy,
        centroid.z + ASSEMBLY_STANDOFF - cz
      )
      grp.transform!(Geom::Transformation.new(offset))
    end

    # ─── Rectangular tag geometry (same pattern as build_tag_geometry but with rects) ───

    def self.build_rect_tag(ents, model, label_text, rgb)
      # Materials — same approach as ensure_tag_materials
      hex = '%02x%02x%02x' % rgb[0..2]
      fill_name = "FF_AutoTag_#{hex}"
      fill_mat = model.materials[fill_name] || begin
        m = model.materials.add(fill_name)
        m.color = Sketchup::Color.new(*rgb)
        m.alpha = 0.90
        m
      end
      border_mat = model.materials['FF_AsmTag_Border'] || begin
        m = model.materials.add('FF_AsmTag_Border')
        m.color = Sketchup::Color.new(49, 50, 68)
        m
      end
      text_mat = model.materials['FF_AutoTag_Text'] || begin
        m = model.materials.add('FF_AutoTag_Text')
        m.color = Sketchup::Color.new(205, 214, 244)  # light text on colored bg
        m
      end

      # Add 3D text (same as build_tag_geometry line 110-111)
      ents.add_3d_text(label_text, TextAlignCenter, "Arial", true, false,
                       ASSEMBLY_TEXT_HEIGHT, 0.0, 0.0, true, 0.2)

      # Measure text bounds (same as build_tag_geometry lines 113-118)
      text_bb = Geom::BoundingBox.new
      ents.each { |e| text_bb.add(e.bounds) }
      tw = text_bb.max.x - text_bb.min.x
      th = text_bb.max.y - text_bb.min.y
      tcx = (text_bb.min.x + text_bb.max.x) / 2.0
      tcy = (text_bb.min.y + text_bb.max.y) / 2.0

      rx = tw / 2.0 + AUTO_TAG_PAD_X
      ry = th / 2.0 + AUTO_TAG_PAD_Y
      bw = ASSEMBLY_BORDER_W

      # Border rectangle (behind, same Z layering as circles)
      border_face = ents.add_face(
        Geom::Point3d.new(tcx - rx - bw, tcy - ry - bw, -0.4),
        Geom::Point3d.new(tcx + rx + bw, tcy - ry - bw, -0.4),
        Geom::Point3d.new(tcx + rx + bw, tcy + ry + bw, -0.4),
        Geom::Point3d.new(tcx - rx - bw, tcy + ry + bw, -0.4)
      ) rescue nil
      apply_tag_mat(border_face, border_mat)

      # Fill rectangle
      fill_face = ents.add_face(
        Geom::Point3d.new(tcx - rx, tcy - ry, -0.2),
        Geom::Point3d.new(tcx + rx, tcy - ry, -0.2),
        Geom::Point3d.new(tcx + rx, tcy + ry, -0.2),
        Geom::Point3d.new(tcx - rx, tcy + ry, -0.2)
      ) rescue nil
      apply_tag_mat(fill_face, fill_mat)

      # Text faces get light color (same as build_tag_geometry lines 132-135)
      ents.grep(Sketchup::Face).each do |f|
        next if f == border_face || f == fill_face
        apply_tag_mat(f, text_mat)
      end
    end

    def self.cleanup_auto_tags(asm_id)
      model = Sketchup.active_model
      return unless model

      to_erase = []
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute('FF_AutoTag', 'asm_id') == asm_id.to_s
        to_erase << grp
      end

      return if to_erase.empty?
      model.start_operation('Remove Auto Tags', true)
      begin
        to_erase.each { |g| g.erase! if g.valid? }
        model.commit_operation
      rescue => e
        model.abort_operation
        puts "[FF AutoTag] Cleanup error: #{e.message}"
      end
    end

  end
end
