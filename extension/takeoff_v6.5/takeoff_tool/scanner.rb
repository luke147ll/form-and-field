module TakeoffTool
  module Scanner
    def self.scan_model(model)
      results = []; reg = {}; seen = {}
      model.definitions.each do |defn|
        next if defn.image?
        defn.instances.each do |inst|
          next if seen[inst.entityID]; seen[inst.entityID] = true
          reg[inst.entityID] = inst
          process(inst, defn, results)
        end
      end
      check_warnings(results)
      [results.sort_by{|r|[r[:tag]||'zzz',r[:display_name]||'']}, reg]
    end

    private

    def self.process(inst, defn, results)
      iname = (inst.name && !inst.name.empty?) ? inst.name : nil
      dname = defn.name || ''
      display = iname || dname
      tag = inst.layer ? inst.layer.name : 'Untagged'

      parsed = Parser.parse_definition(display, tag)
      return if parsed[:auto_category] == '_IGNORE'
      return if tag == '<Revit Missing Links>'
      if tag == 'Layer0'
        return unless iname
        return if display =~ /^<not associated>|^Project.*\.rvt|^Undefined/i
      end

      is_solid = false; vol = 0.0
      begin
        if inst.respond_to?(:manifold?) && inst.manifold?
          is_solid = true; vol = inst.volume
        end
      rescue; end

      bb = inst.bounds
      w = bb.width.to_f; h = bb.height.to_f; d = bb.depth.to_f

      # Count same-name instances
      cnt = 0
      if iname
        Sketchup.active_model.definitions.each{|df| df.instances.each{|i| cnt+=1 if i.name==iname}}
      end
      cnt = [cnt, 1].max

      mat = nil
      if inst.material
        mat = inst.material.display_name
      else
        f = defn.entities.grep(Sketchup::Face).first
        mat = f.material.display_name if f && f.material
      end

      vi3 = vol.to_f; vf3 = vi3/1728.0; vbf = vi3/144.0

      area = nil
      if parsed[:thickness] && is_solid
        tin = Parser.dim_to_in(parsed[:thickness])
        area = vi3/tin/144.0 if tin && tin > 0
      end

      # Compute LF from longest bounding box dimension for linear items
      longest_in = [w, h, d].max
      linear_ft = longest_in / 12.0

      ifc = nil
      if defn.attribute_dictionaries
        a = defn.attribute_dictionaries['AppliedSchemaTypes']
        ifc = a['IFC 4'] if a
      end

      results << {
        entity_id: inst.entityID, entity_type: inst.typename, tag: tag,
        definition_name: dname, display_name: display, instance_name: iname,
        is_solid: is_solid, instance_count: cnt, ifc_type: ifc,
        volume_in3: vi3.round(2), volume_ft3: vf3.round(4), volume_bf: vbf.round(2),
        bb_width_in: w.round(2), bb_height_in: h.round(2), bb_depth_in: d.round(2),
        linear_ft: linear_ft.round(2),
        area_sf: area ? area.round(2) : nil, material: mat,
        parsed: parsed, warnings: []
      }
    end

    def self.check_warnings(results)
      walls = results.select{|r| r[:tag]=='Walls'}
      wc = walls.map{|r| r[:parsed][:auto_category]}.compact.uniq
      if wc.any?{|c| c=~/Siding|Exterior Finish/i} && !wc.any?{|c| c=~/Sheathing/i}
        walls.each{|r| r[:warnings]<<"No wall sheathing detected" if r[:parsed][:auto_category]=~/Siding|Exterior Finish/i}
      end
      if wc.any?{|c| c=~/Wall Framing/i} && !wc.any?{|c| c=~/Drywall/i}
        walls.each{|r| r[:warnings]<<"No drywall detected on framed walls" if r[:parsed][:auto_category]=~/Wall Framing/i}
      end

      roofs = results.select{|r| r[:tag]=='Roofs'}
      rc = roofs.map{|r| r[:parsed][:auto_category]}.compact.uniq
      if rc.any?{|c| c=~/Roofing|Metal Roofing|Shingle/i} && !rc.any?{|c| c=~/Sheathing/i}
        roofs.each{|r| r[:warnings]<<"No roof sheathing detected" if r[:parsed][:auto_category]=~/Roofing|Metal|Shingle/i}
      end
    end
  end
end
