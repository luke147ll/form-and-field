module TakeoffTool

  # ═══ ASSEMBLIES ═══

  def self.load_assemblies
    m = Sketchup.active_model
    return {} unless m
    json = m.get_attribute('FormAndField', 'assemblies')
    return {} unless json && !json.empty?
    require 'json'
    JSON.parse(json) rescue {}
  end

  def self.save_assemblies(assemblies)
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'assemblies', JSON.generate(assemblies))
  end

  def self.create_assembly(name, entity_ids, notes = '')
    assemblies = load_assemblies
    assemblies[name] = {
      'entity_ids' => entity_ids.map(&:to_i),
      'created' => Time.now.strftime('%Y-%m-%d'),
      'count' => entity_ids.length,
      'notes' => notes.to_s
    }
    save_assemblies(assemblies)
    assemblies
  end

  def self.delete_assembly(name)
    assemblies = load_assemblies
    assemblies.delete(name.to_s)
    save_assemblies(assemblies)
    assemblies
  end

  def self.rename_assembly(old_name, new_name)
    assemblies = load_assemblies
    data = assemblies.delete(old_name.to_s)
    return assemblies unless data
    assemblies[new_name.to_s] = data
    save_assemblies(assemblies)
    assemblies
  end

  def self.update_assembly(name, entity_ids: nil, notes: nil)
    assemblies = load_assemblies
    a = assemblies[name.to_s]
    return assemblies unless a
    if entity_ids
      a['entity_ids'] = entity_ids.map(&:to_i)
      a['count'] = entity_ids.length
    end
    a['notes'] = notes.to_s if notes
    save_assemblies(assemblies)
    assemblies
  end

end
