module TakeoffTool

  # ═══════════════════════════════════════════════════════════════
  # ASSEMBLY MANAGER — UUID-keyed assemblies with parts system
  #
  # Data stored in model.get_attribute('FormAndField', 'assemblies')
  # Keys are UUIDs like "asm_a3f2c1", not names.
  # Each assembly has a fixed prefix (A1, A2…) for stable part numbers.
  # ═══════════════════════════════════════════════════════════════

  # Track tag visibility state in memory (not persisted)
  @asm_tags_visible ||= {}

  class << self
    attr_accessor :asm_tags_visible
  end

  # ─── Load / Save ───

  def self.load_assemblies
    m = Sketchup.active_model
    return {} unless m
    json = m.get_attribute('FormAndField', 'assemblies')
    return {} unless json && !json.empty?
    require 'json'
    asms = JSON.parse(json) rescue {}
    # Auto-migrate old name-keyed format
    if asms.any? { |k, _| !k.start_with?('asm_') }
      asms = migrate_assemblies(asms)
      save_assemblies(asms)
    end
    asms
  end

  def self.save_assemblies(assemblies)
    m = Sketchup.active_model
    return unless m
    require 'json'
    m.set_attribute('FormAndField', 'assemblies', JSON.generate(assemblies))
  end

  # ─── Migration: name-keyed → UUID-keyed with parts ───

  def self.migrate_assemblies(old_asms)
    puts "[FF Assembly] Migrating #{old_asms.length} assemblies to UUID format"
    new_asms = {}
    ca = @category_assignments || {}
    sr = @scan_results || []
    eid_sr = {}
    sr.each { |r| eid_sr[r[:entity_id].to_i] = r }

    old_asms.each do |name, data|
      next if name.start_with?('asm_')  # already migrated
      asm_id = generate_asm_id
      prefix = next_asm_prefix
      eids = (data['entity_ids'] || []).map(&:to_i)

      parts = []
      seq = 1
      eids.each do |eid|
        r = eid_sr[eid]
        part_name = r ? (r[:display_name] || r[:definition_name] || 'Unknown') : "Entity #{eid}"
        cat = ca[eid] || (r ? (r[:parsed][:auto_category] rescue 'Uncategorized') : 'Uncategorized')
        parts << {
          'part_number'      => "#{prefix}-#{seq.to_s.rjust(3, '0')}",
          'entity_id'        => eid,
          'name'             => part_name,
          'category'         => cat,
          'quantity'          => 1,
          'unit'             => 'EA',
          'notes'            => '',
          'is_virtual'       => false
        }
        seq += 1
      end

      new_asms[asm_id] = {
        'name'     => name,
        'zone'     => '',
        'created'  => data['created'] || Time.now.strftime('%Y-%m-%d'),
        'notes'    => data['notes'] || '',
        'prefix'   => prefix,
        'next_seq' => seq,
        'parts'    => parts
      }
    end
    puts "[FF Assembly] Migration complete: #{new_asms.length} assemblies converted"
    new_asms
  end

  # ─── Assembly CRUD ───

  def self.create_assembly(name, entity_ids, notes = '', zone = '')
    assemblies = load_assemblies
    asm_id = generate_asm_id
    prefix = next_asm_prefix

    ca = @category_assignments || {}
    sr = @scan_results || []
    eid_sr = {}
    sr.each { |r| eid_sr[r[:entity_id].to_i] = r }

    parts = []
    seq = 1
    entity_ids.map(&:to_i).each do |eid|
      r = eid_sr[eid]
      part_name = r ? (r[:display_name] || r[:definition_name] || 'Unknown') : "Entity #{eid}"
      cat = ca[eid] || (r ? (r[:parsed][:auto_category] rescue 'Uncategorized') : 'Uncategorized')
      parts << {
        'part_number'      => "#{prefix}-#{seq.to_s.rjust(3, '0')}",
        'entity_id'        => eid,
        'name'             => part_name,
        'category'         => cat,
        'quantity'          => 1,
        'unit'             => 'EA',
        'notes'            => '',
        'is_virtual'       => false
      }
      seq += 1
    end

    assemblies[asm_id] = {
      'name'     => name.to_s,
      'zone'     => zone.to_s,
      'created'  => Time.now.strftime('%Y-%m-%d'),
      'notes'    => notes.to_s,
      'prefix'   => prefix,
      'next_seq' => seq,
      'parts'    => parts
    }
    save_assemblies(assemblies)
    publish(EVENT_ASSEMBLY_CREATED, asm_id: asm_id)
    asm_id
  end

  def self.delete_assembly(asm_id)
    assemblies = load_assemblies
    asm = assemblies.delete(asm_id.to_s)
    return assemblies unless asm
    save_assemblies(assemblies)
    # Clean up viewport tags
    AssemblyAnnotations.hide_tags(asm_id) if defined?(AssemblyAnnotations)
    publish(EVENT_ASSEMBLY_DELETED, asm_id: asm_id)
    assemblies
  end

  def self.rename_assembly(asm_id, new_name)
    assemblies = load_assemblies
    a = assemblies[asm_id.to_s]
    return assemblies unless a
    a['name'] = new_name.to_s
    save_assemblies(assemblies)
    publish(EVENT_ASSEMBLY_CHANGED, asm_id: asm_id)
    assemblies
  end

  def self.update_assembly(asm_id, notes: nil, zone: nil)
    assemblies = load_assemblies
    a = assemblies[asm_id.to_s]
    return assemblies unless a
    a['notes'] = notes.to_s unless notes.nil?
    a['zone'] = zone.to_s unless zone.nil?
    save_assemblies(assemblies)
    publish(EVENT_ASSEMBLY_CHANGED, asm_id: asm_id)
    assemblies
  end

  # ─── Part CRUD ───

  def self.add_part_from_entity(asm_id, entity_id)
    assemblies = load_assemblies
    a = assemblies[asm_id.to_s]
    return nil unless a

    eid = entity_id.to_i
    ca = @category_assignments || {}
    sr = @scan_results || []
    r = sr.find { |s| s[:entity_id].to_i == eid }
    part_name = r ? (r[:display_name] || r[:definition_name] || 'Unknown') : "Entity #{eid}"
    cat = ca[eid] || (r ? (r[:parsed][:auto_category] rescue 'Uncategorized') : 'Uncategorized')

    pn = next_part_number(a)
    part = {
      'part_number'      => pn,
      'entity_id'        => eid,
      'name'             => part_name,
      'category'         => cat,
      'quantity'          => 1,
      'unit'             => 'EA',
      'notes'            => '',
      'is_virtual'       => false
    }
    a['parts'] << part
    save_assemblies(assemblies)
    publish(EVENT_PARTS_CHANGED, asm_id: asm_id)
    pn
  end

  def self.add_virtual_part(asm_id, name:, category:, quantity:, unit:, notes: '')
    assemblies = load_assemblies
    a = assemblies[asm_id.to_s]
    return nil unless a

    pn = next_part_number(a)
    part = {
      'part_number'      => pn,
      'entity_id'        => nil,
      'name'             => name.to_s,
      'category'         => category.to_s,
      'quantity'          => [quantity.to_i, 1].max,
      'unit'             => unit.to_s,
      'notes'            => notes.to_s,
      'is_virtual'       => true
    }
    a['parts'] << part
    save_assemblies(assemblies)
    publish(EVENT_PARTS_CHANGED, asm_id: asm_id)
    pn
  end

  def self.remove_part(asm_id, part_number)
    assemblies = load_assemblies
    a = assemblies[asm_id.to_s]
    return false unless a
    before = a['parts'].length
    removed = a['parts'].select { |p| p['part_number'] == part_number.to_s }
    a['parts'].reject! { |p| p['part_number'] == part_number.to_s }
    return false if a['parts'].length == before
    save_assemblies(assemblies)
    publish(EVENT_PARTS_CHANGED, asm_id: asm_id)
    true
  end

  def self.update_part(asm_id, part_number, fields)
    assemblies = load_assemblies
    a = assemblies[asm_id.to_s]
    return false unless a
    part = a['parts'].find { |p| p['part_number'] == part_number.to_s }
    return false unless part
    # Only allow updating safe fields
    %w[name category quantity unit notes].each do |f|
      part[f] = fields[f] if fields.key?(f)
    end
    part['quantity'] = [part['quantity'].to_i, 1].max if fields.key?('quantity')
    save_assemblies(assemblies)
    publish(EVENT_PARTS_CHANGED, asm_id: asm_id)
    true
  end

  # ─── Bulk: add from SketchUp selection ───

  def self.add_parts_from_selection(asm_id)
    sel = Sketchup.active_model&.selection
    return 0 unless sel && !sel.empty?
    added = 0
    sel.to_a.each do |e|
      next unless e.respond_to?(:entityID)
      pn = add_part_from_entity(asm_id, e.entityID)
      added += 1 if pn
    end
    added
  end

  # ─── Formatting Helpers ───

  def self.to_construction_fraction(decimal_inches)
    # Round to nearest 1/16"
    sixteenths = (decimal_inches.to_f * 16).round
    whole = sixteenths / 16
    remainder = sixteenths % 16

    return whole.to_s if remainder == 0

    # Simplify the fraction
    num = remainder
    den = 16
    while num % 2 == 0 && den % 2 == 0
      num /= 2
      den /= 2
    end

    if whole > 0
      "#{whole} #{num}/#{den}"
    else
      "#{num}/#{den}"
    end
  end

  def self.construction_section(dim1, dim2)
    "#{to_construction_fraction(dim1)}x#{to_construction_fraction(dim2)}"
  end

  # Convert nominal lumber dimension to actual
  # "8" -> 7.5, "10" -> 9.5, "12" -> 11.5, etc.
  # Fractional dims like "2 5/8" are already actual, not nominal
  def self.nominal_to_actual(dim_str)
    # Check if it's a fraction like "2 5/8"
    if dim_str =~ /(\d+)\s+(\d+)\/(\d+)/
      whole = $1.to_f
      frac = $2.to_f / $3.to_f
      return whole + frac
    end

    n = dim_str.to_f
    return nil if n <= 0

    # Standard nominal-to-actual lumber conversion
    case n.round
    when 2 then 1.5
    when 3 then 2.5
    when 4 then 3.5
    when 6 then 5.5
    when 8 then 7.5
    when 10 then 9.5
    when 12 then 11.5
    when 14 then 13.5
    when 16 then 15.5
    else n  # Non-standard — return as-is
    end
  end

  # ─── Validation: mark stale entity references ───

  def self.validate_assembly_references
    assemblies = load_assemblies
    changed = false
    assemblies.each do |_id, asm|
      (asm['parts'] || []).each do |part|
        next if part['is_virtual'] || !part['entity_id']
        e = find_entity(part['entity_id'].to_i)
        was_stale = part['stale']
        part['stale'] = !(e && e.valid?)
        changed = true if part['stale'] != was_stale
      end
    end
    save_assemblies(assemblies) if changed
  end

  # ─── Lookup helpers ───

  def self.assemblies_for_entity(entity_id)
    eid = entity_id.to_i
    result = []
    load_assemblies.each do |asm_id, asm|
      (asm['parts'] || []).each do |part|
        if part['entity_id'].to_i == eid && !part['is_virtual']
          result << { asm_id: asm_id, part_number: part['part_number'], name: asm['name'] }
        end
      end
    end
    result
  end

  def self.assembly_display_index(asm_id)
    asms = load_assemblies
    keys = asms.keys.sort_by { |k| asms[k]['created'] || '' }
    keys.index(asm_id.to_s) || 0
  end

  # ─── Private helpers ───

  def self.generate_asm_id
    "asm_#{SecureRandom.hex(3)}"
  rescue
    "asm_#{rand(0xffffff).to_s(16).rjust(6, '0')}"
  end

  def self.next_asm_prefix
    m = Sketchup.active_model
    return 'A1' unless m
    idx = (m.get_attribute('FormAndField', 'next_asm_prefix_index') || 1).to_i
    prefix = "A#{idx}"
    m.set_attribute('FormAndField', 'next_asm_prefix_index', idx + 1)
    prefix
  end

  def self.next_part_number(asm)
    seq = (asm['next_seq'] || 1).to_i
    pn = "#{asm['prefix']}-#{seq.to_s.rjust(3, '0')}"
    asm['next_seq'] = seq + 1
    pn
  end

  # ─── Parts List Generation ───

  def self.generate_parts_list(assembly_name)
    assemblies = load_assemblies
    # Look up by name (any asm_id whose name matches)
    asm_id = assemblies.find { |_k, v| v['name'] == assembly_name.to_s }&.first
    asm = asm_id ? assemblies[asm_id] : nil
    return nil unless asm

    eids = (asm['parts'] || []).reject { |p| p['is_virtual'] }.map { |p| p['entity_id'] }.compact.map(&:to_i)
    sr = @scan_results || []
    ca = @category_assignments || {}
    cca = @cost_code_assignments || {}

    # Filter scan results to this assembly's entities
    asm_results = sr.select { |r| eids.include?(r[:entity_id].to_i) }

    # Group by category + definition_name
    groups = {}
    asm_results.each do |r|
      eid = r[:entity_id]
      cat = ca[eid] || r[:parsed][:auto_category] || 'Uncategorized'
      next if cat == '_IGNORE'
      defn = r[:definition_name] || r[:display_name] || 'Unknown'
      clean_defn = defn.sub(/,\s*[0-9A-Fa-f]{7,}$/, '').strip
      key = "#{cat}||#{clean_defn}"

      e = find_entity(eid)
      sku = e && e.valid? ? (e.get_attribute('TakeoffAssignments', 'sku') || '') : ''
      zone = e && e.valid? ? (e.get_attribute('TakeoffAssignments', 'zone') || '') : ''

      if groups[key]
        g = groups[key]
        g[:qty] += 1
        g[:total_lf] += (r[:linear_ft] || 0).to_f
        g[:total_sf] += (r[:area_sf] || 0).to_f
        g[:total_bf] += (r[:volume_bf] || 0).to_f
        g[:total_cf] += (r[:volume_ft3] || 0).to_f
        g[:eids] << eid
        g[:sku] = sku unless sku.empty? || !g[:sku].empty?
        g[:zone] = zone unless zone.empty? || !g[:zone].to_s.empty?
      else
        groups[key] = {
          category: cat,
          cost_code: cca[eid] || r[:parsed][:cost_code] || '',
          name: clean_defn,
          material: r[:parsed][:material] || r[:material] || '',
          size: r[:parsed][:size_nominal] || r[:parsed][:thickness] || '',
          element_type: r[:parsed][:element_type] || '',
          qty: 1,
          total_lf: (r[:linear_ft] || 0).to_f,
          total_sf: (r[:area_sf] || 0).to_f,
          total_bf: (r[:volume_bf] || 0).to_f,
          total_cf: (r[:volume_ft3] || 0).to_f,
          bb_dims: "#{(r[:bb_width_in] || 0).round(1)}x#{(r[:bb_height_in] || 0).round(1)}x#{(r[:bb_depth_in] || 0).round(1)}",
          sku: sku,
          zone: zone,
          eids: [eid]
        }
      end
    end

    # Also include virtual parts
    virtual_items = []
    (asm['parts'] || []).select { |p| p['is_virtual'] }.each do |vp|
      virtual_items << {
        category: vp['category'] || 'Virtual',
        cost_code: '',
        name: vp['name'] || 'Unknown',
        material: '',
        size: '',
        element_type: '',
        qty: (vp['quantity'] || 1).to_i,
        total_lf: 0.0, total_sf: 0.0, total_bf: 0.0, total_cf: 0.0,
        bb_dims: '', sku: '', eids: [], is_virtual: true
      }
    end

    items = groups.values.sort_by { |g| [g[:cost_code].to_s.empty? ? 'zzz' : g[:cost_code], g[:category], g[:name]] }
    items += virtual_items.sort_by { |v| [v[:category], v[:name]] }

    # Build category groups
    cat_groups = {}
    items.each do |item|
      key = "#{item[:category]}|#{item[:cost_code]}"
      cat_groups[key] ||= { category: item[:category], cost_code: item[:cost_code], items: [] }
      cat_groups[key][:items] << {
        sku: item[:sku] || '',
        name: item[:name],
        material: item[:material] || '',
        size: item[:size] || '',
        dims: item[:bb_dims] || '',
        zone: item[:zone] || '',
        qty: item[:qty],
        lf: item[:total_lf].round(1),
        sf: item[:total_sf].round(1),
        bf: item[:total_bf].round(1),
        cf: item[:total_cf].round(2),
        eids: item[:eids] || [],
        is_virtual: item[:is_virtual] || false
      }
    end

    total_qty = items.sum { |i| i[:qty] }
    total_lf = items.sum { |i| i[:total_lf] }.round(1)
    total_sf = items.sum { |i| i[:total_sf] }.round(1)
    total_bf = items.sum { |i| i[:total_bf] }.round(1)
    total_cf = items.sum { |i| i[:total_cf] }.round(2)

    {
      assembly: assembly_name.to_s,
      entity_count: eids.length,
      line_items: items.length,
      groups: cat_groups.values.sort_by { |g| g[:cost_code].to_s.empty? ? 'zzz' : g[:cost_code] },
      totals: { qty: total_qty, lf: total_lf, sf: total_sf, bf: total_bf, cf: total_cf }
    }
  end

  def self.set_entity_sku(entity_id, sku)
    e = find_entity(entity_id.to_i)
    return false unless e && e.valid?
    m = Sketchup.active_model
    m.start_operation('Set SKU', true)
    e.set_attribute('TakeoffAssignments', 'sku', sku.to_s)
    m.commit_operation
    puts "FF: Set SKU '#{sku}' on eid=#{entity_id}"
    true
  end

  def self.set_definition_sku(entity_id, sku)
    e = find_entity(entity_id.to_i)
    return 0 unless e && e.valid? && e.respond_to?(:definition)
    m = Sketchup.active_model
    m.start_operation('Set SKU (all instances)', true)
    count = 0
    e.definition.instances.each do |inst|
      inst.set_attribute('TakeoffAssignments', 'sku', sku.to_s)
      count += 1
    end
    m.commit_operation
    puts "FF: Set SKU '#{sku}' on #{count} instances of #{e.definition.name}"
    count
  end

  def self.export_parts_list_csv(assembly_name, path = nil)
    data = generate_parts_list(assembly_name)
    return false unless data

    unless path
      model = Sketchup.active_model
      model_name = model ? File.basename(model.path, '.*') : 'Untitled'
      model_name = 'Untitled' if model_name.empty?
      timestamp = Time.now.strftime('%Y%m%d_%H%M')
      default_name = "#{model_name}_#{assembly_name.to_s.gsub(/[^a-zA-Z0-9]/, '_')}_PartsList_#{timestamp}.csv"
      path = UI.savepanel('Export Parts List CSV', '', default_name)
      return false unless path
      path += '.csv' unless path.end_with?('.csv')
    end

    File.open(path, 'w') do |f|
      f.puts "Parts List: #{assembly_name}"
      f.puts "Generated: #{Time.now.strftime('%B %d, %Y %I:%M %p')}"
      f.puts "Entities: #{data[:entity_count]}, Line Items: #{data[:line_items]}"
      f.puts ""
      f.puts "Cost Code,Category,SKU,Item,Material,Size,Zone,Qty,LF,SF,BF,CF"
      data[:groups].each do |grp|
        grp[:items].each do |item|
          row = [
            grp[:cost_code], grp[:category], item[:sku], item[:name],
            item[:material], item[:size], item[:zone],
            item[:qty], item[:lf], item[:sf], item[:bf], item[:cf]
          ].map { |v| "\"#{v.to_s.gsub('"', '""')}\"" }
          f.puts row.join(',')
        end
      end
      f.puts ""
      f.puts ",,,TOTALS,,,#{data[:totals][:qty]},#{data[:totals][:lf]},#{data[:totals][:sf]},#{data[:totals][:bf]},#{data[:totals][:cf]}"
    end

    puts "FF: Exported parts list to #{path}"
    true
  end

  # ─── Cadworks CSV Import ───

  def self.import_cadworks_csv(path)
    require 'csv'
    require 'json'

    m = Sketchup.active_model
    return { matched: 0, unmatched: 0, error: 'No model' } unless m

    # Read CSV — clean raw text first to handle embedded newlines and null bytes
    rows = []
    raw = File.read(path, encoding: 'bom|utf-8')
    raw.gsub!("\r\n", "\n")
    raw.gsub!("\r", "\n")
    raw.gsub!("\x00", '')
    CSV.parse(raw, headers: true, liberal_parsing: true, skip_blanks: true) do |row|
      h = {}
      row.each { |k, v| h[k.to_s.strip.downcase] = (v || '').strip if k }

      name = h['name'] || h['element'] || h['description'] || ''
      mark = h['mark'] || h['sku'] || h['part number'] || h['part_number'] || h['part#'] || ''
      group = h['group'] || h['location'] || h['zone'] || h['room'] || ''
      material = h['material'] || h['species'] || ''
      color = h['color'] || h['colour'] || ''
      qty = (h['quantity'] || h['qty'] || h['count'] || '1').to_i
      steel_asm = h['steel assembly'] || h['assembly'] || ''

      next if name.empty? && mark.empty?

      rows << {
        name: name,
        mark: mark,
        group: group,
        material: material,
        color: color,
        qty: qty,
        steel_assembly: steel_asm
      }
    end

    return { matched: 0, unmatched: 0, error: "No valid rows in CSV" } if rows.empty?

    sr = @scan_results || []
    reg = @entity_registry || {}

    # Index entities by normalized name + material for matching
    entity_index = {}
    sr.each do |r|
      eid = r[:entity_id]
      ename = (r[:display_name] || r[:definition_name] || '').strip
      emat = (r[:material] || r[:parsed][:material] || '').strip

      clean_name = ename.sub(/,\s*[0-9A-Fa-f]{7,}$/, '').strip.downcase
      clean_mat = emat.downcase

      key = "#{clean_name}|#{clean_mat}"
      entity_index[key] ||= []
      entity_index[key] << eid

      key_no_mat = "#{clean_name}|"
      entity_index[key_no_mat] ||= []
      entity_index[key_no_mat] << eid
    end

    m.start_operation('Import Cadworks CSV', true)
    matched = 0
    unmatched = 0
    unmatched_names = []

    rows.each do |row|
      csv_name = row[:name].downcase
      csv_mat = row[:material].downcase

      # Try exact name+material match first
      key = "#{csv_name}|#{csv_mat}"
      eids = entity_index[key]

      # Fallback: name-only match
      if !eids || eids.empty?
        key = "#{csv_name}|"
        eids = entity_index[key]
      end

      # Fallback: partial name match
      if !eids || eids.empty?
        entity_index.each do |k, v|
          ename = k.split('|').first
          if ename.include?(csv_name) || csv_name.include?(ename)
            eids = v
            break
          end
        end
      end

      if eids && eids.any?
        eids.each do |eid|
          e = reg[eid] || find_entity(eid)
          next unless e && e.valid?

          e.set_attribute('TakeoffAssignments', 'sku', row[:mark]) unless row[:mark].empty?
          e.set_attribute('TakeoffAssignments', 'zone', row[:group]) unless row[:group].empty?
          e.set_attribute('TakeoffAssignments', 'cadworks_color', row[:color]) unless row[:color].empty?
          e.set_attribute('TakeoffAssignments', 'steel_assembly', row[:steel_assembly]) unless row[:steel_assembly].empty?
        end
        matched += 1
      else
        unmatched += 1
        unmatched_names << row[:name] unless unmatched_names.length > 20
      end
    end

    m.commit_operation

    puts "FF: Cadworks CSV import: #{matched} matched, #{unmatched} unmatched out of #{rows.length} rows"
    if unmatched_names.any?
      puts "FF: Unmatched names (first #{unmatched_names.length}):"
      unmatched_names.each { |n| puts "  - #{n}" }
    end

    { matched: matched, unmatched: unmatched, total: rows.length, unmatched_names: unmatched_names }
  end

  def self.clear_auto_assemblies
    assemblies = load_assemblies
    before = assemblies.length
    assemblies.reject! { |_id, asm| (asm['notes'] || '').include?('Auto-assembled from Cadworks CSV') }
    save_assemblies(assemblies)
    puts "FF: Cleared #{before - assemblies.length} auto-created assemblies"
    before - assemblies.length
  end

  # ─── Event Bus Subscriptions ───

  subscribe(EVENT_SCAN_COMPLETE) do |_payload|
    begin
      validate_assembly_references
      Dashboard.send_assemblies if defined?(Dashboard) && Dashboard.visible?
    rescue => e
      puts "[FF Assembly] scan_complete handler error: #{e.message}"
    end
  end

end
