module TakeoffTool

  # ═══ PARTS ═══

  def self.load_parts
    m = Sketchup.active_model
    return {} unless m
    json = m.get_attribute('FormAndField', 'parts')
    return {} unless json && !json.empty?
    require 'json'
    JSON.parse(json) rescue {}
  end

  def self.save_parts(parts)
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'parts', JSON.generate(parts))
  end

  def self.create_part(name, entity_ids, category, subcategory = '', notes = '')
    m = Sketchup.active_model
    return nil unless m

    # Collect real entities
    ents = entity_ids.map { |eid| find_entity(eid.to_i) }.compact.select(&:valid?)
    return nil if ents.empty?

    m.start_operation('Create Part', true)
    begin
      # Create a Group from the selected entities
      grp = m.active_entities.add_group(ents)
      grp.name = name.to_s
      grp.set_attribute('TakeoffAssignments', 'part_name', name.to_s)
      grp.set_attribute('TakeoffAssignments', 'category', category.to_s)
      grp.set_attribute('TakeoffAssignments', 'subcategory', subcategory.to_s)
      grp.set_attribute('FormAndField', 'is_part', true)

      child_count = ents.length
      grp_eid = grp.entityID

      # Store in model-level parts registry
      parts = load_parts
      parts[name] = {
        'group_id' => grp_eid,
        'category' => category.to_s,
        'subcategory' => subcategory.to_s,
        'created' => Time.now.strftime('%Y-%m-%d'),
        'child_count' => child_count,
        'notes' => notes.to_s
      }
      save_parts(parts)
      m.commit_operation
      puts "[FF Parts] Created group part '#{name}' (eid=#{grp_eid}, #{child_count} children)"

      # Register the group in entity registry so scanner/dashboard can find it
      @entity_registry[grp_eid] = grp if @entity_registry

      parts
    rescue => e
      m.abort_operation
      puts "[FF Parts] create_part failed: #{e.message}"
      nil
    end
  end

  def self.delete_part(name)
    m = Sketchup.active_model
    return nil unless m
    parts = load_parts
    pdata = parts.delete(name.to_s)
    save_parts(parts)
    return parts unless pdata

    grp_eid = pdata['group_id']
    grp = find_entity(grp_eid.to_i) if grp_eid
    if grp && grp.valid? && grp.is_a?(Sketchup::Group)
      m.start_operation('Delete Part', true)
      grp.explode
      m.commit_operation
      puts "[FF Parts] Exploded part '#{name}' back to individual entities"
    end
    parts
  end

  def self.rename_part(old_name, new_name)
    parts = load_parts
    data = parts.delete(old_name.to_s)
    return parts unless data
    parts[new_name.to_s] = data
    save_parts(parts)

    grp = find_entity((data['group_id'] || 0).to_i)
    if grp && grp.valid?
      grp.name = new_name.to_s
      grp.set_attribute('TakeoffAssignments', 'part_name', new_name.to_s)
    end
    parts
  end

  def self.part_for_entity(entity_id)
    ent = find_entity(entity_id.to_i)
    return nil unless ent
    # Check if entity IS a part group
    pn = ent.get_attribute('TakeoffAssignments', 'part_name') rescue nil
    return pn if pn && (ent.get_attribute('FormAndField', 'is_part') rescue nil)
    # Check if entity's parent is a part group
    if ent.parent.is_a?(Sketchup::ComponentDefinition)
      ent.parent.instances.each do |pi|
        pn2 = pi.get_attribute('FormAndField', 'is_part') rescue nil
        return pi.get_attribute('TakeoffAssignments', 'part_name') if pn2
      end
    end
    nil
  end

  def self.add_to_part(name, new_entity_ids)
    m = Sketchup.active_model
    return 0 unless m
    parts = load_parts
    pdata = parts[name.to_s]
    return 0 unless pdata

    grp = find_entity((pdata['group_id'] || 0).to_i)
    return 0 unless grp && grp.valid? && grp.is_a?(Sketchup::Group)

    ents = new_entity_ids.map { |eid| find_entity(eid.to_i) }.compact.select(&:valid?)
    return 0 if ents.empty?

    m.start_operation('Add to Part', true)
    begin
      added = 0
      # Move entities into the group by copying geometry and erasing originals
      t_inv = grp.transformation.inverse
      ents.each do |e|
        next if e == grp
        next if e.get_attribute('FormAndField', 'is_part') rescue false
        if e.is_a?(Sketchup::ComponentInstance)
          new_inst = grp.entities.add_instance(e.definition, t_inv * e.transformation)
          new_inst.material = e.material if e.material
          new_inst.layer = e.layer
          e.erase!
          added += 1
        elsif e.is_a?(Sketchup::Group)
          new_inst = grp.entities.add_instance(e.definition, t_inv * e.transformation)
          new_inst.material = e.material if e.material
          new_inst.layer = e.layer
          e.erase!
          added += 1
        end
      end
      pdata['child_count'] = (pdata['child_count'] || 0) + added
      save_parts(parts)
      m.commit_operation
      puts "[FF Parts] Added #{added} entities to part '#{name}'"
      added
    rescue => e
      m.abort_operation
      puts "[FF Parts] add_to_part failed: #{e.message}"
      0
    end
  end

  def self.find_part_group(name)
    parts = load_parts
    pdata = parts[name.to_s]
    return nil unless pdata
    grp = find_entity((pdata['group_id'] || 0).to_i)
    (grp && grp.valid? && grp.is_a?(Sketchup::Group)) ? grp : nil
  end

end
